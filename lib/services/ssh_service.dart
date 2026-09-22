import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'adsm_version.dart';
import 'local_host_bootstrap.dart';
import 'remote_setup_guide.dart';
import 'ssh_no_delay_socket.dart';

class SshConnectResult {
  const SshConnectResult({required this.ok, this.detail, this.error});

  final bool ok;
  final String? detail;
  final String? error;
}

class MissingToolException implements Exception {
  MissingToolException(this.tool, this.installHint);

  final String tool;
  final String installHint;

  @override
  String toString() => '$tool is not installed on the remote host.';
}

enum _BundledAdsmPush { ok, noAssets, failed }

/// Why a connection attempt failed, and whether retrying could ever help.
enum SshFailureKind {
  /// Bad credentials or an unusable key — retrying will never succeed and may
  /// trip fail2ban or lock the account.
  auth,

  /// No key configured on the device yet.
  missingKey,

  /// Host key rejected.
  hostKey,

  /// Transport-level problem: unreachable, refused, reset, timed out.
  network,

  /// Something the remote is missing, e.g. the Cursor CLI. Retrying the same
  /// connection cannot install it.
  tooling,

  unknown,
}

extension SshFailureKindX on SshFailureKind {
  /// Fatal failures must never be retried automatically.
  bool get isFatal =>
      this == SshFailureKind.auth ||
      this == SshFailureKind.missingKey ||
      this == SshFailureKind.hostKey ||
      this == SshFailureKind.tooling;
}

/// Classify an arbitrary error thrown from the SSH stack.
SshFailureKind classifySshFailure(Object error) {
  if (error is MissingToolException) return SshFailureKind.tooling;
  if (error is SSHAuthFailError) return SshFailureKind.auth;
  if (error is SSHKeyDecodeError) return SshFailureKind.missingKey;
  if (error is SSHHostkeyError) return SshFailureKind.hostKey;
  if (error is SSHAuthAbortError) {
    // Aborted auth is usually the socket dying mid-handshake.
    return SshFailureKind.network;
  }
  if (error is SSHSocketError ||
      error is SocketException ||
      error is TimeoutException ||
      error is SSHHandshakeError) {
    return SshFailureKind.network;
  }
  if (error is StateError) {
    final message = error.message.toLowerCase();
    if (message.contains('no ssh private key'))
      return SshFailureKind.missingKey;
    if (message.contains('passphrase') || message.contains('parse')) {
      return SshFailureKind.missingKey;
    }
  }
  final text = error.toString().toLowerCase();
  if (text.contains('adsm channel closed') ||
      text.contains('adsm closed') ||
      text.contains('adsm write failed') ||
      text.contains('acp connection closed') ||
      text.contains('acp connection error') ||
      text.contains('acp stdin closed') ||
      text.contains('connection closed') ||
      text.contains('transport is closed') ||
      text.contains('channel open') ||
      text.contains('broken pipe') ||
      text.contains('connection reset') ||
      text.contains('socketexception')) {
    return SshFailureKind.network;
  }
  return SshFailureKind.unknown;
}

/// True when the ADSM/ACP/SSH bridge dropped and auto-reconnect should handle it
/// without a sticky red banner.
bool isTransientBridgeError(Object error) {
  if (classifySshFailure(error) == SshFailureKind.network) return true;
  return isTransientBridgeErrorText(error.toString());
}

bool isTransientBridgeErrorText(String text) {
  final t = text.toLowerCase();
  return t.contains('adsm channel closed') ||
      t.contains('adsm closed') ||
      t.contains('adsm write failed') ||
      t.contains('acp connection closed') ||
      t.contains('acp connection error') ||
      t.contains('acp stdin closed') ||
      t.contains('connection closed') ||
      t.contains('transport is closed') ||
      t.contains('broken pipe') ||
      t.contains('connection reset') ||
      // Host idle-reaper closed the worker FIFO; ADSM revive / reconnect fixes it.
      t.contains('fifo not attached') ||
      t.contains('agent fifo recycled');
}

/// Claude/Cursor OAuth or API key rejected — user must re-authenticate.
bool isAgentAuthFailureText(String text) {
  final t = text.toLowerCase();
  return t.contains('authentication_failed') ||
      t.contains('errorkind\': \'authentication') ||
      t.contains('"errorkind":"authentication') ||
      t.contains('oauth access token has expired') ||
      t.contains('re-authenticate') ||
      t.contains('reauthenticate') ||
      (t.contains('401') &&
          (t.contains('oauth') ||
              t.contains('token') ||
              t.contains('unauthorized') ||
              t.contains('authenticate'))) ||
      t.contains('not logged in') ||
      t.contains('please run /login') ||
      t.contains('claude auth login') ||
      t.contains('agent login') ||
      // Codex: ACP `authentication required`, expired ChatGPT tokens, or a
      // rejected OPENAI_API_KEY (`invalid_api_key`).
      t.contains('authentication required') ||
      t.contains('invalid_api_key') ||
      t.contains('incorrect api key') ||
      t.contains('codex login');
}

/// ACP session id is gone (common after Stop/cancel on Claude).
bool isAcpSessionGoneText(String text) {
  final t = text.toLowerCase();
  return t.contains('session not found') ||
      t.contains('unknown session') ||
      (t.contains('-32603') && t.contains('session'));
}

/// Caps concurrent exec channels on one connection.
///
/// sshd's `MaxSessions` defaults to 10 channels per network connection. Now
/// that everything shares one connection per host, unbounded fan-out would hit
/// that ceiling and get channels refused.
class _ChannelGate {
  _ChannelGate(this.limit);

  final int limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<T> run<T>(Future<T> Function() body) async {
    if (_active >= limit) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      try {
        await waiter.future.timeout(
          const Duration(seconds: 45),
          onTimeout: () {
            _waiting.remove(waiter);
            throw TimeoutException(
              'SSH channel gate timed out — too many commands in flight',
            );
          },
        );
      } catch (e) {
        if (!waiter.isCompleted) {
          _waiting.remove(waiter);
        }
        rethrow;
      }
    }
    _active++;
    try {
      return await body();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

class _PooledHost {
  _PooledHost(this.connecting);

  Future<SSHClient> connecting;
  SSHClient? client;
  final _ChannelGate gate = _ChannelGate(6);
}

/// Quick host resource snapshot for the ADSM status sheet.
class HostSystemMetrics {
  const HostSystemMetrics({
    this.cpuPercent,
    this.memUsedBytes,
    this.memTotalBytes,
    this.diskFreeBytes,
    this.diskTotalBytes,
    this.error,
  });

  final double? cpuPercent;
  final int? memUsedBytes;
  final int? memTotalBytes;
  final int? diskFreeBytes;
  final int? diskTotalBytes;
  final String? error;

  bool get hasAny =>
      cpuPercent != null || memTotalBytes != null || diskFreeBytes != null;

  String get cpuLabel {
    final c = cpuPercent;
    if (c == null) return '—';
    return '${c.toStringAsFixed(c >= 10 ? 0 : 1)}%';
  }

  String get memoryLabel {
    final used = memUsedBytes;
    final total = memTotalBytes;
    if (used == null || total == null || total <= 0) return '—';
    final pct = (100.0 * used / total).clamp(0, 100);
    return '${_fmtBytes(used)} / ${_fmtBytes(total)} '
        '(${pct.toStringAsFixed(0)}%)';
  }

  String get diskFreeLabel {
    final free = diskFreeBytes;
    final total = diskTotalBytes;
    if (free == null) return '—';
    if (total == null || total <= 0) return _fmtBytes(free);
    final pct = (100.0 * free / total).clamp(0, 100);
    return '${_fmtBytes(free)} free of ${_fmtBytes(total)} '
        '(${pct.toStringAsFixed(0)}%)';
  }

  static String _fmtBytes(int bytes) {
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    final b = bytes.toDouble();
    if (b >= tb) return '${(b / tb).toStringAsFixed(1)} TB';
    if (b >= gb) return '${(b / gb).toStringAsFixed(1)} GB';
    if (b >= mb) return '${(b / mb).toStringAsFixed(0)} MB';
    if (b >= kb) return '${(b / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}

/// SSH client wrapper. Secrets come from [SecureStore] only for the duration
/// of a connection attempt — never logged.
///
/// Connections are pooled per host and shared. Callers must **not** close the
/// client returned by [connect]; the pool owns its lifetime and evicts it when
/// it dies or fails a health check.
class SshService {
  SshService(this._secureStore, this._db);

  final SecureStore _secureStore;
  final AppDatabase _db;

  final Map<String, _PooledHost> _pool = {};
  Timer? _healthTimer;
  bool _suspended = false;

  /// Hosts whose ADSM already meets [kRequiredAdsmVersion] this process.
  /// Avoids re-uploading / restarting the daemon on every chat reconnect.
  final Map<String, String> _adsmVerifiedVersion = {};

  /// Cached absolute paths for Cursor / Claude binaries per host.
  final Map<String, String> _toolPathCache = {};

  /// Parsed private keys are immutable and can be reused by every connection.
  /// PEM decoding (especially RSA) is CPU-heavy pure Dart work; parsing the
  /// same key once per host made bulk refresh visibly stop Flutter frames.
  String? _cachedIdentityPem;
  String? _cachedIdentityPassphrase;
  List<SSHKeyPair>? _cachedIdentities;

  /// Serializes [ensureAdsm] per host so parallel chats cannot double-upgrade.
  final Map<String, Future<void>> _adsmEnsureInflight = {};

  static const _healthInterval = Duration(seconds: 45);
  static const _pingTimeout = Duration(seconds: 6);

  /// True when this app already verified the host at the required ADSM version.
  bool isAdsmReady(String hostId) {
    final v = _adsmVerifiedVersion[hostId];
    return v != null && adsmVersionMeets(v, kRequiredAdsmVersion);
  }

  void _markAdsmReady(String hostId, String version) {
    _adsmVerifiedVersion[hostId] = version;
  }

  void clearAdsmReady(String hostId) {
    _adsmVerifiedVersion.remove(hostId);
  }

  /// Drop a stuck [ensureAdsm] waiter so the next connect is not blocked.
  void abandonAdsmEnsure(String hostId) {
    _adsmEnsureInflight.remove(hostId);
  }

  /// Stop the ADSM daemon on [host] (local shell or SSH). Clears ready cache.
  Future<void> stopAdsm(Host host) async {
    clearAdsmReady(host.id);
    await exec(host, r'''
set +e
export PATH="$HOME/.local/bin:$PATH"
if command -v agentdock-adsm >/dev/null 2>&1; then
  agentdock-adsm stop 2>/dev/null || true
fi
pkill -f 'python3 -m adsm serve' 2>/dev/null || true
pkill -f 'python -m adsm serve' 2>/dev/null || true
rm -f "$HOME/.agentdock/adsm.sock" 2>/dev/null || true
rm -f "$HOME/.agentdock/adsm.pid" 2>/dev/null || true
exit 0
''', timeout: const Duration(seconds: 20));
  }

  /// CPU / memory / free disk on [host]. Hard-capped at [timeout] (default 1s).
  Future<HostSystemMetrics> fetchHostSystemMetrics(
    Host host, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    try {
      final out = await exec(host, _hostMetricsScript, timeout: timeout);
      return _parseHostSystemMetrics(out);
    } on TimeoutException {
      return const HostSystemMetrics(error: 'Timed out (>1s)');
    } catch (e) {
      SafeLog.d('host system metrics failed', e);
      return HostSystemMetrics(error: '$e');
    }
  }

  static const _hostMetricsScript = r'''
set +e
python3 - <<'PY'
import os, re, shutil, subprocess, sys

def emit(k, v):
    if v is None:
        return
    print(f"{k}={v}")

# --- disk (root) ---
try:
    u = shutil.disk_usage("/")
    emit("DISK_FREE", u.free)
    emit("DISK_TOTAL", u.total)
except Exception:
    pass

# --- memory ---
try:
    if sys.platform == "darwin":
        total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip())
        vm = subprocess.check_output(["vm_stat"], text=True)
        m = re.search(r"page size of (\d+)", vm)
        page = int(m.group(1)) if m else 4096
        def pages(label):
            mm = re.search(rf"{re.escape(label)}:\s+(\d+)", vm)
            return int(mm.group(1)) if mm else 0
        # Approx used: active + wired + compressed (fallback speculative).
        used_pages = (
            pages("Pages active")
            + pages("Pages wired down")
            + pages("Pages occupied by compressor")
        )
        if used_pages <= 0:
            used_pages = total // page - pages("Pages free") - pages("Pages speculative")
        used = max(0, min(total, used_pages * page))
        emit("MEM_USED", used)
        emit("MEM_TOTAL", total)
    elif os.path.exists("/proc/meminfo"):
        info = {}
        with open("/proc/meminfo", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[0].endswith(":"):
                    info[parts[0][:-1]] = int(parts[1]) * 1024
        total = info.get("MemTotal")
        avail = info.get("MemAvailable")
        if total:
            emit("MEM_TOTAL", total)
            if avail is not None:
                emit("MEM_USED", max(0, total - avail))
except Exception:
    pass

# --- cpu (sum of process %cpu / ncpu; fast, no sleep sample) ---
try:
    ncpu = os.cpu_count() or 1
    out = subprocess.check_output(["ps", "-A", "-o", "%cpu="], text=True, stderr=subprocess.DEVNULL)
    s = 0.0
    for tok in out.split():
        try:
            s += float(tok)
        except ValueError:
            pass
    pct = max(0.0, min(100.0, s / float(ncpu)))
    emit("CPU_PCT", f"{pct:.1f}")
except Exception:
    pass
PY
exit 0
''';

  static HostSystemMetrics _parseHostSystemMetrics(String out) {
    double? cpu;
    int? memUsed;
    int? memTotal;
    int? diskFree;
    int? diskTotal;
    for (final line in out.split('\n')) {
      final t = line.trim();
      final i = t.indexOf('=');
      if (i <= 0) continue;
      final key = t.substring(0, i);
      final val = t.substring(i + 1).trim();
      switch (key) {
        case 'CPU_PCT':
          cpu = double.tryParse(val);
        case 'MEM_USED':
          memUsed = int.tryParse(val);
        case 'MEM_TOTAL':
          memTotal = int.tryParse(val);
        case 'DISK_FREE':
          diskFree = int.tryParse(val);
        case 'DISK_TOTAL':
          diskTotal = int.tryParse(val);
      }
    }
    if (cpu == null && memTotal == null && diskFree == null) {
      return const HostSystemMetrics(error: 'No metrics returned');
    }
    return HostSystemMetrics(
      cpuPercent: cpu,
      memUsedBytes: memUsed,
      memTotalBytes: memTotal,
      diskFreeBytes: diskFree,
      diskTotalBytes: diskTotal,
    );
  }

  String? cachedCursorCli(String hostId) => _toolPathCache['cursor:$hostId'];

  String? cachedClaudeAcp(String hostId) => _toolPathCache['claude:$hostId'];

  String? cachedCodexAcp(String hostId) => _toolPathCache['codex:$hostId'];

  static const _toolPathPrefsKey = 'ssh_tool_path_cache_v1';

  /// Load Cursor/Claude/Codex absolute paths saved from prior connects.
  Future<void> loadPersistedCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_toolPathPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final e in decoded.entries) {
        final v = e.value;
        if (e.key is String && v is String && v.isNotEmpty) {
          _toolPathCache[e.key as String] = v;
        }
      }
    } catch (e) {
      SafeLog.d('load tool path cache failed', e);
    }
  }

  void _cacheToolPath(String key, String path) {
    _toolPathCache[key] = path;
    unawaited(_persistToolPathCache());
  }

  Future<void> _persistToolPathCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_toolPathPrefsKey, jsonEncode(_toolPathCache));
    } catch (e) {
      SafeLog.d('persist tool path cache failed', e);
    }
  }

  Future<SshConnectResult> testConnection(Host host) async {
    try {
      final client = await connect(host);
      final out = await _run(client, 'uname -a', hostId: host.id);
      return SshConnectResult(ok: true, detail: out.trim());
    } catch (e) {
      SafeLog.d('SSH test failed for ${host.hostname}', e);
      return SshConnectResult(ok: false, error: e.toString());
    }
  }

  /// A live, pooled client for [host]. Do not close the result.
  Future<SSHClient> connect(Host host, {Set<String>? visited}) async {
    final pooled = _pool[host.id];
    if (pooled != null) {
      try {
        final client = await pooled.connecting;
        if (!client.isClosed) return client;
      } catch (_) {
        // Fall through and reconnect below.
      }
      _pool.remove(host.id);
    }

    final entry = _PooledHost(_createClient(host, visited: visited));
    _pool[host.id] = entry;

    late final SSHClient client;
    try {
      client = await entry.connecting;
    } catch (e) {
      _pool.remove(host.id);
      rethrow;
    }

    entry.client = client;
    unawaited(
      client.done.whenComplete(() {
        if (_pool[host.id] == entry) {
          _pool.remove(host.id);
          SafeLog.d('SSH pool evicted ${host.alias} (transport closed)');
        }
      }),
    );
    _startHealthTimer();
    return client;
  }

  /// A dedicated connection the caller owns and must close itself.
  Future<SSHClient> connectExclusive(Host host) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _createClient(host, exclusive: true);
      } catch (e) {
        lastError = e;
        if (!_isRetryableChannelOpenError(e) || attempt == 1) {
          throw _friendlySshOpenError(e);
        }
        SafeLog.d(
          'SSH exclusive connect retry after channel open failure '
          'for ${host.displayLabel}',
          e,
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    throw _friendlySshOpenError(lastError ?? StateError('SSH open failed'));
  }

  static bool _isRetryableChannelOpenError(Object e) {
    final t = e.toString().toLowerCase();
    return e is SSHChannelOpenError ||
        t.contains('open failed') ||
        t.contains('sshchannelopenerror') ||
        t.contains('administratively prohibited');
  }

  static Object _friendlySshOpenError(Object e) {
    if (!_isRetryableChannelOpenError(e)) return e;
    return StateError(
      'SSH open failed — too many sessions on this host (or its jump host). '
      'Close unused terminals/agents and retry. ($e)',
    );
  }

  Future<SSHClient> _createClient(
    Host host, {
    Set<String>? visited,
    bool exclusive = false,
  }) async {
    final chain = {...?visited};
    if (!chain.add(host.id)) {
      throw StateError('ProxyJump cycle detected for ${host.displayLabel}');
    }

    final password = await _secureStore.readHostPassword(host.id);
    final usePassword = password != null && password.isNotEmpty;

    List<SSHKeyPair>? pairs;
    if (!usePassword) {
      var pem = await _secureStore.readSshPrivateKey();
      // Local this-computer host: fall back to ~/.ssh/id_* so coding on the
      // same Mac/PC works without pasting a key into Settings first.
      if ((pem == null || pem.trim().isEmpty) &&
          isLocalThisComputerHost(host)) {
        pem = await readDefaultSshPrivateKeyPem();
      }
      if (pem == null || pem.trim().isEmpty) {
        throw StateError(
          isLocalThisComputerHost(host)
              ? 'No SSH key for this computer. Enable Remote Login (Mac) or '
                    'OpenSSH Server (Windows), then add your key in Settings, '
                    'or set a password on this host. Default ~/.ssh/id_ed25519 '
                    'or id_rsa is also tried automatically.'
              : 'No SSH private key in Settings, and no password on this host. '
                    'Add a key in Settings or set a password when editing the host.',
        );
      }
      final passphrase = await _secureStore.readSshPassphrase();
      try {
        final identityPem = pem;
        final normalizedPassphrase =
            (passphrase != null && passphrase.isNotEmpty) ? passphrase : null;
        if (_cachedIdentityPem == identityPem &&
            _cachedIdentityPassphrase == normalizedPassphrase &&
            _cachedIdentities != null) {
          pairs = _cachedIdentities;
        } else {
          // PEM/ASN.1 and encrypted-key decoding are synchronous CPU work.
          // Keep them off Flutter's event loop; the parsed immutable keypairs
          // are sendable and then cached for all later host connections.
          pairs = await Isolate.run(
            () => SSHKeyPair.fromPem(identityPem, normalizedPassphrase),
          );
          _cachedIdentityPem = identityPem;
          _cachedIdentityPassphrase = normalizedPassphrase;
          _cachedIdentities = pairs;
        }
      } catch (e) {
        throw StateError(
          'Could not parse SSH private key (wrong passphrase?).',
        );
      }
    }

    final SSHSocket socket;
    SSHClient? ownedJump;
    if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) {
      final jumpHost = await _db.getHost(host.jumpHostId!);
      if (jumpHost == null) {
        throw StateError(
          'ProxyJump host is missing. Edit this host and pick a jump host again.',
        );
      }
      // Long-lived exclusive sessions must not burn direct-tcpip channels on
      // the shared jump pool (that is what surfaces as "ssh open failed"
      // when a second agent connects while another is busy).
      final SSHClient jumpClient;
      if (exclusive) {
        ownedJump = await _createClient(
          jumpHost,
          visited: chain,
          exclusive: true,
        );
        jumpClient = ownedJump;
      } else {
        jumpClient = await connect(jumpHost, visited: chain);
      }
      try {
        socket = await jumpClient
            .forwardLocal(host.hostname, host.port)
            .timeout(const Duration(seconds: 20));
      } catch (e) {
        try {
          ownedJump?.close();
        } catch (_) {}
        rethrow;
      }
    } else {
      try {
        socket = await SshNoDelaySocket.connect(
          host.hostname,
          host.port,
          timeout: const Duration(seconds: 15),
        );
      } catch (e) {
        if (isLocalThisComputerHost(host)) {
          throw StateError(describeLocalHostConnectError(e, host));
        }
        rethrow;
      }
    }

    final client = SSHClient(
      socket,
      username: host.username,
      identities: pairs,
      onPasswordRequest: usePassword ? () => password : null,
    );
    try {
      await client.authenticated.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('SSH authentication timed out'),
      );
    } catch (e) {
      try {
        client.close();
      } catch (_) {}
      try {
        ownedJump?.close();
      } catch (_) {}
      rethrow;
    }
    if (ownedJump != null) {
      final jump = ownedJump;
      unawaited(
        client.done.whenComplete(() {
          try {
            jump.close();
          } catch (_) {}
        }),
      );
    }
    return client;
  }

  /// Drop a host's pooled connection (used when a health check fails).
  void invalidate(String hostId) {
    final entry = _pool.remove(hostId);
    try {
      entry?.client?.close();
    } catch (_) {}
  }

  void closeAll() {
    for (final id in _pool.keys.toList()) {
      invalidate(id);
    }
  }

  /// Actively verify pooled connections and evict the dead ones.
  ///
  /// dartssh2 pings every 10s but never times out waiting for the reply, and
  /// its in-flight guard means one lost reply silently stops all later pings.
  /// So a dead link is only noticed when TCP finally gives up, which can take
  /// minutes. This does the detection the library skips.
  Future<void> healthCheckAll() async {
    if (_pool.isEmpty) return;
    final ids = _pool.keys.toList();
    await Future.wait(
      ids.map((id) async {
        final entry = _pool[id];
        final client = entry?.client;
        if (entry == null || client == null) return;
        if (client.isClosed) {
          invalidate(id);
          return;
        }
        try {
          await client.ping().timeout(_pingTimeout);
        } catch (e) {
          SafeLog.d('SSH health check failed for $id; evicting', e);
          invalidate(id);
        }
      }),
    );
  }

  void _startHealthTimer() {
    if (_suspended || _healthTimer != null) return;
    _healthTimer = Timer.periodic(_healthInterval, (_) {
      unawaited(healthCheckAll());
    });
  }

  /// The OS is about to freeze us: stop timers and let sockets go.
  void onAppPaused() {
    _suspended = true;
    _healthTimer?.cancel();
    _healthTimer = null;
    // Sockets do not survive suspension; drop them so the next use reconnects
    // immediately instead of waiting for a dead connection to time out.
    closeAll();
  }

  /// Back in the foreground: re-verify everything before the user touches it.
  void onAppResumed() {
    _suspended = false;
    unawaited(healthCheckAll());
    _startHealthTimer();
  }

  /// Run [command] on [host]; [input], when given, is streamed to its stdin.
  ///
  /// Bulk payloads must go through [input]: a single `sh -c` argument is
  /// capped at 128 KiB on Linux, so inlining data in [command] fails with
  /// "Argument list too long" once a transcript grows past that.
  Future<String> exec(
    Host host,
    String command, {
    Duration timeout = const Duration(seconds: 12),
    List<int>? input,
  }) async {
    if (_preferLocalFs(host)) {
      return _execLocal(command, timeout: timeout, input: input);
    }
    final client = await connect(host);
    return _run(
      client,
      command,
      hostId: host.id,
      timeout: timeout,
      input: input,
    );
  }

  /// Run a shell command on This Mac/PC without SSH (same machine as the app).
  Future<String> _execLocal(
    String command, {
    Duration timeout = const Duration(seconds: 12),
    List<int>? input,
  }) async {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final pathPrefix = [
      if (home != null && home.isNotEmpty) '$home/.local/bin',
      if (Platform.isMacOS) '/opt/homebrew/bin',
      '/usr/local/bin',
      Platform.environment['PATH'] ?? '',
    ].where((s) => s.isNotEmpty).join(':');
    final env = <String, String>{...Platform.environment, 'PATH': pathPrefix};
    late final ProcessResult result;
    try {
      if (input == null) {
        result = await Process.run(
          Platform.isWindows ? 'bash' : '/bin/bash',
          ['-lc', command],
          workingDirectory: home != null && home.isNotEmpty ? home : null,
          environment: env,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(timeout);
      } else {
        result = await () async {
          final proc = await Process.start(
            Platform.isWindows ? 'bash' : '/bin/bash',
            ['-lc', command],
            workingDirectory: home != null && home.isNotEmpty ? home : null,
            environment: env,
          );
          final out = utf8.decodeStream(proc.stdout);
          final err = utf8.decodeStream(proc.stderr);
          proc.stdin.add(input);
          await proc.stdin.close();
          return ProcessResult(proc.pid, await proc.exitCode, await out, await err);
        }().timeout(timeout);
      }
    } on TimeoutException {
      throw TimeoutException('Local command timed out after $timeout');
    } on ProcessException catch (e) {
      throw StateError(
        Platform.isWindows
            ? 'Could not run bash on This PC ($e). Install Git Bash '
                  'or enable OpenSSH Server for agents.'
            : 'Could not run local shell: $e',
      );
    }
    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw Exception(
        err.isEmpty ? 'Command failed (exit ${result.exitCode})' : err,
      );
    }
    return result.stdout as String;
  }

  Future<String> _run(
    SSHClient client,
    String command, {
    required String hostId,
    Duration timeout = const Duration(seconds: 12),
    List<int>? input,
  }) async {
    final gate = _pool[hostId]?.gate;
    Future<String> body() async {
      // Cap execute() too — a hung open-channel left connects stuck on
      // "Starting ADSM…" with no progress forever.
      final session = await client
          .execute(command)
          .timeout(
            timeout,
            onTimeout: () => throw TimeoutException(
              'Remote command timed out after $timeout (open)',
            ),
          );
      try {
        if (input != null) {
          session.stdin.add(
            input is Uint8List ? input : Uint8List.fromList(input),
          );
          unawaited(session.stdin.close());
        }
        // Read stdout + stderr in parallel — sequential reads can deadlock SSH channels.
        final chunks = await Future.wait<Uint8List>([
          _readAll(session.stdout),
          _readAll(session.stderr),
        ]).timeout(timeout);
        await session.done.timeout(const Duration(seconds: 5));
        final stdout = chunks[0];
        final stderr = chunks[1];
        final code = session.exitCode ?? 0;
        if (code != 0) {
          final err = utf8.decode(stderr).trim();
          throw Exception(err.isEmpty ? 'Command failed (exit $code)' : err);
        }
        return utf8.decode(stdout);
      } on TimeoutException {
        try {
          session.close();
        } catch (_) {}
        throw TimeoutException('Remote command timed out after $timeout');
      }
    }

    return gate == null ? body() : gate.run(body);
  }

  Future<Uint8List> _readAll(Stream<Uint8List> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Probe remote tools; throws [MissingToolException] with install hints.
  Future<void> ensureRemoteTools(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    await ensureTmux(host, onProgress: onProgress);
    await ensureCursorCli(host, onProgress: onProgress);
  }

  Future<void> ensureTmux(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Checking tmux…');
    var tmux = await _resolveTmuxPathOnHost(host);
    if (tmux != null) return;

    onProgress?.call(
      _preferLocalFs(host)
          ? 'Installing tmux…'
          : 'Installing tmux on the remote…',
    );
    try {
      await exec(host, r'''
set -e
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
if command -v tmux >/dev/null 2>&1; then command -v tmux; exit 0; fi

# Environment modules (common on HPC — no sudo).
if [ -f /etc/profile.d/modules.sh ]; then . /etc/profile.d/modules.sh; fi
if [ -f /usr/share/lmod/lmod/init/bash ]; then . /usr/share/lmod/lmod/init/bash; fi
if command -v module >/dev/null 2>&1; then
  module load tmux 2>/dev/null || true
  module load tools/tmux 2>/dev/null || true
  module load app/tmux 2>/dev/null || true
  if command -v tmux >/dev/null 2>&1; then command -v tmux; exit 0; fi
fi

# User-local conda/mamba (also no sudo).
if command -v conda >/dev/null 2>&1; then
  conda install -y -c conda-forge tmux </dev/null && command -v tmux && exit 0
fi
if command -v mamba >/dev/null 2>&1; then
  mamba install -y -c conda-forge tmux </dev/null && command -v tmux && exit 0
fi

# System package managers (need sudo / brew).
if command -v apt-get >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y tmux
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y tmux
elif command -v brew >/dev/null 2>&1; then
  brew install tmux
elif command -v zypper >/dev/null 2>&1; then
  sudo zypper install -y tmux
else
  echo "no package manager for tmux" >&2
  exit 1
fi
command -v tmux
''', timeout: const Duration(minutes: 5));
    } catch (e) {
      SafeLog.d('tmux auto-install failed', e);
    }

    tmux = await _resolveTmuxPathOnHost(host);
    if (tmux == null) {
      throw MissingToolException('tmux', kRemoteTmuxSetupGuide.trim());
    }
  }

  /// Locate tmux via PATH, known paths, and HPC environment modules.
  Future<String?> _resolveTmuxPathOnHost(Host host) async {
    const script = r'''
set +e
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
if command -v tmux >/dev/null 2>&1; then command -v tmux; exit 0; fi
for p in /usr/bin/tmux /usr/local/bin/tmux /opt/homebrew/bin/tmux \
         "$HOME/.local/bin/tmux"; do
  if [ -x "$p" ]; then printf %s "$p"; exit 0; fi
done
if [ -f /etc/profile.d/modules.sh ]; then . /etc/profile.d/modules.sh; fi
if [ -f /usr/share/lmod/lmod/init/bash ]; then . /usr/share/lmod/lmod/init/bash; fi
if [ -f /usr/share/Modules/init/bash ]; then . /usr/share/Modules/init/bash; fi
if command -v module >/dev/null 2>&1; then
  module load tmux 2>/dev/null || true
  module load tools/tmux 2>/dev/null || true
  module load app/tmux 2>/dev/null || true
  if command -v tmux >/dev/null 2>&1; then command -v tmux; exit 0; fi
fi
exit 1
''';
    try {
      final out = await exec(
        host,
        'bash -lc ${shellQuote(script)}',
        timeout: const Duration(seconds: 25),
      );
      final path = out.trim().split('\n').last.trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  /// True when tmux exists, without throwing.
  Future<bool> hasTmux(Host host) async {
    try {
      return await _resolveTmuxPathOnHost(host) != null;
    } catch (_) {
      return false;
    }
  }

  /// Resolves Cursor CLI to an absolute path, installing on the host if needed.
  Future<String> ensureCursorCli(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    final cached = cachedCursorCli(host.id);
    if (cached != null) {
      onProgress?.call('Cursor CLI ready');
      return cached;
    }

    onProgress?.call('Looking for Cursor CLI…');
    var path = await _resolveCursorCliPathOnHost(host);
    if (path != null) {
      _cacheToolPath('cursor:${host.id}', path);
      onProgress?.call('Cursor CLI ready');
      return path;
    }

    onProgress?.call(
      _preferLocalFs(host)
          ? 'Installing Cursor CLI (this can take a few minutes)…'
          : 'Installing Cursor CLI on the remote (this can take a few minutes)…',
    );
    final installed = await _runAgentDockInstallScriptOnHost(
      host,
      scriptName: 'cursor-acp.sh',
      onProgress: onProgress,
    );
    if (!installed) {
      onProgress?.call('Trying Cursor official installer…');
      try {
        await exec(host, r'''
set -e
export PATH="$HOME/.local/bin:$HOME/.cursor/bin:$PATH"
curl -fsSL https://cursor.com/install | bash
mkdir -p "$HOME/.local/bin"
if command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then
  ln -sfn "$(command -v agent)" "$HOME/.local/bin/cursor-agent"
fi
command -v cursor-agent >/dev/null || command -v agent >/dev/null
''', timeout: const Duration(minutes: 5));
      } catch (e) {
        SafeLog.d('Cursor official installer failed', e);
      }
    }

    path = await _resolveCursorCliPathOnHost(host);
    if (path == null) {
      throw MissingToolException(
        'Cursor Agent CLI / SDK',
        kRemoteCursorSetupGuide.trim(),
      );
    }
    _cacheToolPath('cursor:${host.id}', path);
    onProgress?.call('Cursor CLI ready');
    return path;
  }

  Future<String> _runWithInstallProgress(
    SSHClient client,
    String command, {
    required String hostId,
    Duration timeout = const Duration(minutes: 10),
    void Function(String status)? onProgress,
  }) async {
    final gate = _pool[hostId]?.gate;
    Future<String> body() async {
      final session = await client.execute(command);
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      void pushLine(String source, String line) {
        if (source == 'out') {
          stdout.writeln(line);
        } else {
          stderr.writeln(line);
        }
        final t = line.trim();
        if (t.startsWith('==> ')) {
          onProgress?.call(t.substring(4));
        } else if (t.startsWith('✓ ')) {
          onProgress?.call(t.substring(2));
        }
      }

      Future<void> drain(Stream<Uint8List> stream, String source) async {
        final carry = StringBuffer();
        await for (final chunk in stream) {
          carry.write(utf8.decode(chunk, allowMalformed: true));
          var text = carry.toString();
          var idx = text.indexOf('\n');
          while (idx >= 0) {
            pushLine(source, text.substring(0, idx));
            text = text.substring(idx + 1);
            idx = text.indexOf('\n');
          }
          carry
            ..clear()
            ..write(text);
        }
        final tail = carry.toString();
        if (tail.isNotEmpty) pushLine(source, tail);
      }

      try {
        await Future.wait<void>([
          drain(session.stdout, 'out'),
          drain(session.stderr, 'err'),
        ]).timeout(timeout);
        await session.done.timeout(const Duration(seconds: 5));
        final code = session.exitCode ?? 0;
        if (code != 0) {
          final err = stderr.toString().trim();
          throw Exception(err.isEmpty ? 'Command failed (exit $code)' : err);
        }
        return stdout.toString();
      } on TimeoutException {
        try {
          session.close();
        } catch (_) {}
        throw TimeoutException('Remote command timed out after $timeout');
      }
    }

    return gate == null ? body() : gate.run(body);
  }

  static const _claudeInlineInstall = r'''
set -e
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
mkdir -p "$HOME/.local/bin"

if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi
  . "$HOME/.nvm/nvm.sh"
  nvm install --lts
fi
. "$HOME/.nvm/nvm.sh" 2>/dev/null || true

npm install -g @agentclientprotocol/claude-agent-acp \
  || npm install -g @zed-industries/claude-code-acp

NODE_BIN="$(dirname "$(command -v node)")"
PREFIX_BIN="$(npm prefix -g 2>/dev/null)/bin"
REAL=
for dir in "$NODE_BIN" "$PREFIX_BIN"; do
  [ -d "$dir" ] || continue
  [ "$(cd "$dir" && pwd -P)" = "$(cd "$HOME/.local/bin" && pwd -P)" ] && continue
  for name in claude-agent-acp claude-code-acp; do
    if [ -x "$dir/$name" ]; then REAL="$dir/$name"; break 2; fi
  done
done
[ -n "$REAL" ]

cat > "$HOME/.local/bin/claude-code-acp" <<'EOF'
#!/usr/bin/env bash
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
for d in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH="$HOME/.local/bin:$PATH"
EOF
printf 'exec %q "$@"\n' "$REAL" >> "$HOME/.local/bin/claude-code-acp"
chmod +x "$HOME/.local/bin/claude-code-acp"
ln -sfn "$HOME/.local/bin/claude-code-acp" "$HOME/.local/bin/claude-agent-acp"
test -x "$HOME/.local/bin/claude-code-acp"
''';

  Future<void> _tryClaudeInlineInstall(
    SSHClient client, {
    required String hostId,
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Installing Claude ACP adapter (npm)…');
    await _runWithInstallProgress(
      client,
      _claudeInlineInstall,
      hostId: hostId,
      timeout: const Duration(minutes: 12),
      onProgress: onProgress,
    );
  }

  Future<void> _tryClaudeInlineInstallOnHost(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    if (_preferLocalFs(host)) {
      onProgress?.call('Installing Claude ACP adapter (npm)…');
      await exec(
        host,
        _claudeInlineInstall,
        timeout: const Duration(minutes: 12),
      );
      return;
    }
    final client = await connect(host).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'SSH connect timed out while installing Claude ACP',
      ),
    );
    await _tryClaudeInlineInstall(
      client,
      hostId: host.id,
      onProgress: onProgress,
    );
  }

  /// Resolves the Claude ACP adapter, installing Claude Code + adapter if needed.
  Future<String> ensureClaudeAcpBinary(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    final cached = cachedClaudeAcp(host.id);
    if (cached != null) {
      onProgress?.call('Claude ACP ready');
      return cached;
    }

    onProgress?.call('Looking for Claude ACP…');
    var path = await _resolveClaudeAcpPathOnHost(host);
    if (path != null) {
      _cacheToolPath('claude:${host.id}', path);
      onProgress?.call('Claude ACP ready');
      return path;
    }

    onProgress?.call('First Claude setup on this host — usually 3–8 minutes…');

    // Fast path: npm/nvm only (tmux + ADSM are handled separately).
    try {
      await _tryClaudeInlineInstallOnHost(host, onProgress: onProgress);
      path = await _resolveClaudeAcpPathOnHost(host);
      if (path != null) {
        _cacheToolPath('claude:${host.id}', path);
        onProgress?.call('Claude ACP ready');
        return path;
      }
    } catch (e) {
      SafeLog.d('claude ACP inline install failed', e);
      onProgress?.call('Inline install failed — trying full setup script…');
    }

    final installed = await _runAgentDockInstallScriptOnHost(
      host,
      scriptName: 'claude-acp.sh',
      onProgress: onProgress,
      timeout: const Duration(minutes: 15),
    );
    if (!installed) {
      onProgress?.call('Retrying npm install…');
      try {
        await _tryClaudeInlineInstallOnHost(host, onProgress: onProgress);
      } catch (e) {
        SafeLog.d('claude ACP inline install retry failed', e);
      }
    }

    path = await _resolveClaudeAcpPathOnHost(host);
    if (path == null) {
      throw MissingToolException(
        'Claude Code ACP adapter',
        kRemoteClaudeSetupGuide.trim(),
      );
    }
    _cacheToolPath('claude:${host.id}', path);
    onProgress?.call('Claude ACP ready');
    return path;
  }

  /// The maintained adapter is TypeScript (`@agentclientprotocol/codex-acp`)
  /// and bundles the Codex CLI's native binary, so only Node 20+ is needed.
  static const _codexInlineInstall = r'''
set -e
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
mkdir -p "$HOME/.local/bin"

node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "${major:-0}" -ge 20 ]
}
if ! node_ok || ! command -v npm >/dev/null 2>&1; then
  if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi
  . "$HOME/.nvm/nvm.sh"
  nvm install --lts
fi
. "$HOME/.nvm/nvm.sh" 2>/dev/null || true
node_ok

npm install -g @agentclientprotocol/codex-acp@latest

NODE_BIN="$(dirname "$(command -v node)")"
PREFIX_BIN="$(npm prefix -g 2>/dev/null)/bin"
REAL=
for dir in "$NODE_BIN" "$PREFIX_BIN"; do
  [ -d "$dir" ] || continue
  [ "$(cd "$dir" && pwd -P)" = "$(cd "$HOME/.local/bin" && pwd -P)" ] && continue
  if [ -x "$dir/codex-acp" ]; then REAL="$dir/codex-acp"; break; fi
done
[ -n "$REAL" ]

{
  printf '#!/usr/bin/env bash\n'
  printf 'export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"\n'
  printf '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n'
  printf 'for d in "$HOME"/.nvm/versions/node/*/bin; do\n'
  printf '  [ -d "$d" ] && PATH="$d:$PATH"\n'
  printf 'done\n'
  printf 'export PATH="$HOME/.local/bin:$PATH"\n'
  printf 'export NO_BROWSER=1\n'
  printf 'exec %q "$@"\n' "$REAL"
} > "$HOME/.local/bin/codex-acp"
chmod +x "$HOME/.local/bin/codex-acp"

# `codex` CLI for `codex login` — the adapter bundles it.
CODEX_JS="$(npm root -g 2>/dev/null)/@agentclientprotocol/codex-acp/node_modules/@openai/codex/bin/codex.js"
if ! command -v codex >/dev/null 2>&1 && [ -f "$CODEX_JS" ]; then
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"\n'
    printf '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n'
    printf 'for d in "$HOME"/.nvm/versions/node/*/bin; do\n'
    printf '  [ -d "$d" ] && PATH="$d:$PATH"\n'
    printf 'done\n'
    printf 'exec node %q "$@"\n' "$CODEX_JS"
  } > "$HOME/.local/bin/codex"
  chmod +x "$HOME/.local/bin/codex"
fi
test -x "$HOME/.local/bin/codex-acp"
''';

  Future<void> _tryCodexInlineInstallOnHost(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Installing Codex ACP adapter (npm)…');
    if (_preferLocalFs(host)) {
      await exec(
        host,
        _codexInlineInstall,
        timeout: const Duration(minutes: 12),
      );
      return;
    }
    final client = await connect(host).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'SSH connect timed out while installing Codex ACP',
      ),
    );
    await _runWithInstallProgress(
      client,
      _codexInlineInstall,
      hostId: host.id,
      timeout: const Duration(minutes: 12),
      onProgress: onProgress,
    );
  }

  /// Resolves the Codex ACP adapter, installing it (with the bundled Codex
  /// CLI) if needed.
  Future<String> ensureCodexAcpBinary(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    final cached = cachedCodexAcp(host.id);
    if (cached != null) {
      onProgress?.call('Codex ACP ready');
      return cached;
    }

    onProgress?.call('Looking for Codex ACP…');
    var path = await _resolveCodexAcpPathOnHost(host);
    if (path != null) {
      _cacheToolPath('codex:${host.id}', path);
      onProgress?.call('Codex ACP ready');
      return path;
    }

    onProgress?.call('First Codex setup on this host — usually 2–5 minutes…');

    try {
      await _tryCodexInlineInstallOnHost(host, onProgress: onProgress);
      path = await _resolveCodexAcpPathOnHost(host);
      if (path != null) {
        _cacheToolPath('codex:${host.id}', path);
        onProgress?.call('Codex ACP ready');
        return path;
      }
    } catch (e) {
      SafeLog.d('codex ACP inline install failed', e);
      onProgress?.call('Inline install failed — trying full setup script…');
    }

    final installed = await _runAgentDockInstallScriptOnHost(
      host,
      scriptName: 'codex-acp.sh',
      onProgress: onProgress,
      timeout: const Duration(minutes: 15),
    );
    if (!installed) {
      onProgress?.call('Retrying npm install…');
      try {
        await _tryCodexInlineInstallOnHost(host, onProgress: onProgress);
      } catch (e) {
        SafeLog.d('codex ACP inline install retry failed', e);
      }
    }

    path = await _resolveCodexAcpPathOnHost(host);
    if (path == null) {
      throw MissingToolException(
        'Codex ACP adapter',
        kRemoteCodexSetupGuide.trim(),
      );
    }
    _cacheToolPath('codex:${host.id}', path);
    onProgress?.call('Codex ACP ready');
    return path;
  }

  /// Installs/starts ADSM on the host and verifies it responds at
  /// [kRequiredAdsmVersion] or newer.
  ///
  /// Prefers uploading the ADSM package bundled with this app. GitHub is only
  /// used when this build has no ADSM assets (should not happen in release).
  ///
  /// Set [allowUpgrade] to false on reconnects so we never restart the daemon
  /// mid-chat — that was killing the shared bridge and causing reconnect loops.
  Future<void> ensureAdsm(
    Host host, {
    void Function(String status)? onProgress,
    bool allowUpgrade = true,
  }) async {
    final prev = _adsmEnsureInflight[host.id];
    final run = () async {
      if (prev != null) {
        onProgress?.call('Waiting for ADSM setup on this host…');
        try {
          await prev.timeout(const Duration(seconds: 30));
          if (isAdsmReady(host.id) && !allowUpgrade) {
            onProgress?.call('ADSM ready');
            return;
          }
        } on TimeoutException {
          SafeLog.d(
            'prior ensureAdsm still running for ${host.id}; abandoning wait',
          );
          if (identical(_adsmEnsureInflight[host.id], prev)) {
            _adsmEnsureInflight.remove(host.id);
          }
          onProgress?.call('Retrying ADSM…');
          invalidate(host.id);
        } catch (_) {}
      }
      await _ensureAdsmBody(
        host,
        onProgress: onProgress,
        allowUpgrade: allowUpgrade,
      );
    }();
    _adsmEnsureInflight[host.id] = run;
    try {
      await run;
    } finally {
      if (identical(_adsmEnsureInflight[host.id], run)) {
        _adsmEnsureInflight.remove(host.id);
      }
    }
  }

  Future<void> _ensureAdsmBody(
    Host host, {
    void Function(String status)? onProgress,
    required bool allowUpgrade,
  }) async {
    final local = _preferLocalFs(host);
    SSHClient? client;
    if (!local) {
      onProgress?.call('Opening SSH for ADSM…');
      try {
        client = await connect(host).timeout(
          const Duration(seconds: 45),
          onTimeout: () => throw TimeoutException(
            'Timed out opening SSH to ${host.displayLabel}',
          ),
        );
      } on TimeoutException {
        rethrow;
      }
    }
    var lastProbe = '';

    Future<SSHClient> refreshClient() async {
      if (local) {
        throw StateError('Local This Mac/PC has no SSH client to refresh');
      }
      onProgress?.call('Reconnecting SSH for ADSM…');
      invalidate(host.id);
      client = await connect(host).timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException(
          'Timed out reconnecting SSH to ${host.displayLabel}',
        ),
      );
      return client!;
    }

    Future<String> runCmd(
      String command, {
      Duration timeout = const Duration(seconds: 35),
    }) async {
      if (local) {
        return _execLocal(command, timeout: timeout);
      }
      if (client!.isClosed) await refreshClient();
      return _run(client!, command, hostId: host.id, timeout: timeout);
    }

    bool transportDead(Object e) {
      final t = e.toString().toLowerCase();
      return t.contains('transport is closed') ||
          t.contains('connection reset') ||
          t.contains('broken pipe') ||
          t.contains('socket has been shut down');
    }

    Future<({bool ok, bool hasBin, String? version, String raw})>
    quickPing() async {
      try {
        final out = await runCmd(r'''
set +e
python3 - <<'PY' 2>/dev/null
import json, os, socket, sys
p = os.path.expanduser("~/.agentdock/adsm.sock")
if not os.path.exists(p):
    print("ADSM_PROBE=missing_sock")
    sys.exit(0)
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
try:
    s.connect(p)
    s.sendall(b'{"id":1,"method":"ping","params":{}}\n')
    data = s.recv(8192).decode("utf-8", "replace")
    print(data.strip())
    ver = ""
    try:
        msg = json.loads(data.strip().splitlines()[0])
        ver = str((msg.get("result") or {}).get("version") or "")
    except Exception:
        pass
    if ver:
        print(f"ADSM_VERSION={ver}")
    if '"ok"' in data or "version" in data:
        print("ADSM_PROBE=ok")
        sys.exit(0)
except Exception as e:
    print(f"ADSM_SOCK_ERR={e}")
finally:
    try:
        s.close()
    except Exception:
        pass
sys.exit(0)
PY
''', timeout: const Duration(seconds: 15));
        lastProbe = out.trim();
        String? version;
        for (final line in out.split('\n')) {
          final t = line.trim();
          if (t.startsWith('ADSM_VERSION=')) {
            version = t.substring('ADSM_VERSION='.length).trim();
            if (version.isEmpty) version = null;
          }
        }
        return (
          ok: out.contains('ADSM_PROBE=ok'),
          hasBin: true,
          version: version,
          raw: lastProbe,
        );
      } catch (e) {
        SafeLog.d('ADSM quick ping failed', e);
        return (ok: false, hasBin: true, version: null, raw: '$e');
      }
    }

    Future<({bool ok, bool hasBin, String? version, String raw})>
    probe() async {
      try {
        final out = await runCmd(r'''
set +e
export PATH="$HOME/.local/bin:$PATH"
BIN="$(command -v agentdock-adsm 2>/dev/null)"
[ -n "$BIN" ] || BIN="$HOME/.local/bin/agentdock-adsm"

# Direct socket ping — works even when the wrapper is not on PATH.
python3 - <<'PY' 2>/dev/null
import json, os, socket, sys
p = os.path.expanduser("~/.agentdock/adsm.sock")
if not os.path.exists(p):
    sys.exit(2)
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
try:
    s.connect(p)
    s.sendall(b'{"id":1,"method":"ping","params":{}}\n')
    data = s.recv(8192).decode("utf-8", "replace")
    print(data.strip())
    ver = ""
    try:
        msg = json.loads(data.strip().splitlines()[0])
        ver = str((msg.get("result") or {}).get("version") or "")
    except Exception:
        pass
    if ver:
        print(f"ADSM_VERSION={ver}")
    if '"ok"' in data or "version" in data:
        print("ADSM_PROBE=ok")
        sys.exit(0)
except Exception as e:
    print(f"ADSM_SOCK_ERR={e}")
    sys.exit(1)
finally:
    try:
        s.close()
    except Exception:
        pass
sys.exit(1)
PY
SOCK_EC=$?
if [ "$SOCK_EC" -eq 0 ]; then
  exit 0
fi

if [ ! -x "$BIN" ]; then
  echo "ADSM_PROBE=missing_bin"
  exit 0
fi
echo "ADSM_BIN=$BIN"
OUT="$("$BIN" ensure-running 2>&1)"
EC=$?
printf '%s\n' "$OUT"
# Re-ping after ensure-running for version.
python3 - <<'PY' 2>/dev/null
import json, os, socket, sys
p = os.path.expanduser("~/.agentdock/adsm.sock")
if not os.path.exists(p):
    sys.exit(0)
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
try:
    s.connect(p)
    s.sendall(b'{"id":1,"method":"ping","params":{}}\n')
    data = s.recv(8192).decode("utf-8", "replace")
    print(data.strip())
    msg = json.loads(data.strip().splitlines()[0])
    ver = str((msg.get("result") or {}).get("version") or "")
    if ver:
        print(f"ADSM_VERSION={ver}")
except Exception:
    pass
finally:
    try:
        s.close()
    except Exception:
        pass
PY
if [ "$EC" -eq 0 ]; then
  echo "ADSM_PROBE=ok"
else
  echo "ADSM_PROBE=ensure_failed ec=$EC"
fi
"$BIN" status 2>/dev/null | head -1 || true
exit 0
''', timeout: const Duration(seconds: 20));
        lastProbe = out.trim();
        SafeLog.d('ADSM probe: $lastProbe');
        String? version;
        for (final line in out.split('\n')) {
          final t = line.trim();
          if (t.startsWith('ADSM_VERSION=')) {
            version = t.substring('ADSM_VERSION='.length).trim();
            if (version.isEmpty) version = null;
          }
        }
        // Fallback: parse version from status / ping JSON line.
        if (version == null) {
          final m = RegExp(r'"version"\s*:\s*"([^"]+)"').firstMatch(out);
          if (m != null) version = m.group(1);
        }
        return (
          ok: out.contains('ADSM_PROBE=ok'),
          hasBin: !out.contains('ADSM_PROBE=missing_bin'),
          version: version,
          raw: out,
        );
      } catch (e) {
        lastProbe = e.toString();
        SafeLog.d('ADSM probe exception', e);
        if (transportDead(e)) {
          try {
            await refreshClient();
          } catch (_) {}
        }
        return (ok: false, hasBin: false, version: null, raw: lastProbe);
      }
    }

    Future<void> installOrUpgrade({required String reason}) async {
      onProgress?.call(reason);
      if (!local && (client!.isClosed || transportDead(lastProbe))) {
        await refreshClient();
      }
      // Ship this app's ADSM first — GitHub main can lag a local version bump.
      final push = local
          ? await _pushBundledAdsmLocal(onProgress: onProgress)
          : await _pushBundledAdsm(
              client!,
              hostId: host.id,
              onProgress: onProgress,
            );
      if (push == _BundledAdsmPush.ok) return;

      if (push == _BundledAdsmPush.failed) {
        throw MissingToolException(
          'ADSM',
          'Could not upload the ADSM package bundled with this app '
              '(v$kRequiredAdsmVersion). GitHub install was skipped because '
              'main can lag this build and would restart the daemon on every '
              'retry.\n\nCheck SSH/SFTP to the host and reconnect.\n\n'
              '# Probe:\n$lastProbe',
        );
      }

      // Assets missing from this build — last resort.
      final installed = await _runAgentDockInstallScriptOnHost(
        host,
        scriptName: 'install-adsm.sh',
        onProgress: onProgress,
      );
      if (!installed) {
        onProgress?.call('Starting ADSM…');
        try {
          await runCmd(r'''
set +e
export PATH="$HOME/.local/bin:$PATH"
command -v agentdock-adsm >/dev/null || exit 1
agentdock-adsm ensure-running
exit 0
''', timeout: const Duration(seconds: 45));
        } catch (e) {
          SafeLog.d('ADSM ensure-running after failed install failed', e);
        }
      }
    }

    Future<bool> waitForRequired({int attempts = 10}) async {
      for (var i = 0; i < attempts; i++) {
        await Future<void>.delayed(Duration(milliseconds: 400 + i * 200));
        final state = await probe();
        if (state.ok && adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
          _markAdsmReady(host.id, state.version!);
          onProgress?.call('ADSM ready (v${state.version})');
          return true;
        }
        onProgress?.call(
          'Waiting for ADSM v$kRequiredAdsmVersion… '
          '(host reports ${state.version ?? "unknown"})',
        );
      }
      return false;
    }

    onProgress?.call('Checking ADSM…');
    // Soft reconnect / already-ready: prefer a cheap unix-socket ping so a
    // hung `ensure-running` (common behind ProxyJump) does not burn the
    // whole connect budget. Full probe is the fallback.
    if (!allowUpgrade || isAdsmReady(host.id)) {
      final quick = await quickPing();
      if (quick.ok) {
        if (adsmVersionMeets(quick.version, kRequiredAdsmVersion)) {
          _markAdsmReady(host.id, quick.version!);
        }
        onProgress?.call(
          quick.version != null
              ? 'ADSM ready (v${quick.version})'
              : 'ADSM ready',
        );
        return;
      }
    }
    var state = await probe();

    // Healthy + new enough → done.
    if (state.ok && adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
      _markAdsmReady(host.id, state.version!);
      onProgress?.call('ADSM ready (v${state.version})');
      return;
    }

    // Reconnect / soft path: keep a working daemon alive; never pkill.
    if (!allowUpgrade || isAdsmReady(host.id)) {
      if (state.ok) {
        onProgress?.call(
          'ADSM v${state.version ?? "unknown"} running '
          '(app prefers v$kRequiredAdsmVersion) — continuing',
        );
        return;
      }
      if (state.hasBin) {
        onProgress?.call('Starting ADSM…');
        state = await probe(); // ensure-running is inside probe path
        if (state.ok) {
          if (adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
            _markAdsmReady(host.id, state.version!);
          }
          onProgress?.call('ADSM ready (v${state.version ?? "unknown"})');
          return;
        }
      }
      throw MissingToolException(
        'ADSM',
        'ADSM is not running on the host and upgrade was skipped '
            '(reconnect path).\n\n# Probe:\n$lastProbe',
      );
    }

    // Running but too old (or version unknown on an old build).
    if (state.ok && !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
      final have = state.version ?? 'unknown';
      await installOrUpgrade(
        reason:
            'ADSM mismatch — host has v$have, this app needs '
            'v$kRequiredAdsmVersion. Updating…',
      );
      if (await waitForRequired()) return;
      throw MissingToolException(
        'ADSM',
        'ADSM mismatch — cannot run until the host is on '
            'v$kRequiredAdsmVersion (host still reports '
            '${state.version ?? "unknown"}).\n'
            'Open this agent again to retry the automatic update.\n\n'
            '# Probe:\n$lastProbe',
      );
    }

    // Binary present but daemon not healthy — start/repair only first.
    if (state.hasBin) {
      onProgress?.call('Starting ADSM…');
      for (var i = 0; i < 3; i++) {
        onProgress?.call('Starting ADSM… (${i + 1}/3)');
        // Yield so Flutter can paint / handle input between SSH probes.
        await Future<void>.delayed(Duration(milliseconds: 50 + i * 100));
        state = await probe();
        if (state.ok && adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
          _markAdsmReady(host.id, state.version!);
          onProgress?.call('ADSM ready (v${state.version})');
          return;
        }
        if (state.ok &&
            !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
          break; // fall through to upgrade
        }
      }
      if (state.ok && !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
        final have = state.version ?? 'unknown';
        await installOrUpgrade(
          reason:
              'ADSM mismatch — host has v$have, this app needs '
              'v$kRequiredAdsmVersion. Updating…',
        );
        if (await waitForRequired()) return;
      } else if (!state.ok) {
        throw MissingToolException(
          'ADSM',
          '${kRemoteAdsmSetupGuide.trim()}\n\n'
              '# Probe (daemon binary found but not healthy):\n$lastProbe',
        );
      }
    }

    // Missing binary, dead probe, or upgrade path above failed — push/install.
    if (!state.hasBin ||
        !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
      await installOrUpgrade(
        reason: state.hasBin
            ? 'ADSM mismatch — updating host to v$kRequiredAdsmVersion…'
            : 'Installing ADSM on the remote…',
      );
    }

    if (await waitForRequired()) return;

    state = await probe();
    if (state.ok && !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
      throw MissingToolException(
        'ADSM',
        'ADSM mismatch — cannot run. Host is still '
            'v${state.version ?? "unknown"}; this app needs v$kRequiredAdsmVersion.\n'
            'Reconnect to retry the automatic update.\n\n# Probe:\n$lastProbe',
      );
    }

    throw MissingToolException(
      'ADSM',
      '${kRemoteAdsmSetupGuide.trim()}\n\n# Probe:\n$lastProbe',
    );
  }

  static const _bundledAdsmFiles = <String>[
    '__init__.py',
    '__main__.py',
    'paths.py',
    'protocol.py',
    'worker.py',
    'daemon.py',
    'cli.py',
    'scheduler.py',
    'transcript.py',
    'process_hygiene.py',
  ];

  Future<Map<String, Uint8List>> _loadBundledAdsmPayloads() async {
    final payloads = <String, Uint8List>{};
    for (final name in _bundledAdsmFiles) {
      final data = await rootBundle.load('host/adsm/$name');
      payloads[name] = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    }
    return payloads;
  }

  static const _adsmWrapper = '''
#!/usr/bin/env bash
export PYTHONPATH="\$HOME/.local/share/agentdock/host\${PYTHONPATH:+:\$PYTHONPATH}"
exec python3 -m adsm "\$@"
''';

  static const _adsmRestartScript = r'''
set -e
chmod +x "$HOME/.local/bin/agentdock-adsm"
export PATH="$HOME/.local/bin:$PATH"
pkill -f 'python3 -m adsm serve' 2>/dev/null || true
pkill -f 'python -m adsm serve' 2>/dev/null || true
sleep 0.3
rm -f "$HOME/.agentdock/adsm.sock" 2>/dev/null || true
agentdock-adsm ensure-running
''';

  /// Install bundled ADSM onto This Mac/PC via local filesystem (no SSH).
  Future<_BundledAdsmPush> _pushBundledAdsmLocal({
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Installing ADSM v$kRequiredAdsmVersion…');
    late final Map<String, Uint8List> payloads;
    try {
      payloads = await _loadBundledAdsmPayloads();
    } catch (e) {
      SafeLog.d('Bundled ADSM assets missing from this build', e);
      onProgress?.call('App ADSM assets missing — trying GitHub…');
      return _BundledAdsmPush.noAssets;
    }

    try {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        throw StateError('HOME is not set');
      }
      final share = Directory('$home/.local/share/agentdock/host/adsm');
      final binDir = Directory('$home/.local/bin');
      await share.create(recursive: true);
      await binDir.create(recursive: true);
      for (final entry in payloads.entries) {
        await File('${share.path}/${entry.key}').writeAsBytes(entry.value);
      }
      final wrapper = File('${binDir.path}/agentdock-adsm');
      await wrapper.writeAsString(_adsmWrapper);
      await Process.run('chmod', ['+x', wrapper.path]);
      await _execLocal(
        _adsmRestartScript,
        timeout: const Duration(seconds: 45),
      );
      onProgress?.call('ADSM v$kRequiredAdsmVersion installed');
      return _BundledAdsmPush.ok;
    } catch (e) {
      SafeLog.d('Bundled ADSM local install failed', e);
      onProgress?.call('Bundled ADSM install failed');
      return _BundledAdsmPush.failed;
    }
  }

  /// Upload bundled ADSM. Prefer stdin/base64 (reliable over ProxyJump);
  /// SFTP is a fallback. GitHub is only used when assets are missing.
  Future<_BundledAdsmPush> _pushBundledAdsm(
    SSHClient client, {
    required String hostId,
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Uploading ADSM v$kRequiredAdsmVersion from this app…');
    late final Map<String, Uint8List> payloads;
    try {
      payloads = await _loadBundledAdsmPayloads();
    } catch (e) {
      SafeLog.d('Bundled ADSM assets missing from this build', e);
      onProgress?.call('App ADSM assets missing — trying GitHub…');
      return _BundledAdsmPush.noAssets;
    }

    try {
      await _pushBundledAdsmViaStdin(
        client,
        hostId: hostId,
        payloads: payloads,
      );
      onProgress?.call('ADSM v$kRequiredAdsmVersion uploaded');
      return _BundledAdsmPush.ok;
    } catch (e) {
      SafeLog.d('ADSM stdin upload failed, trying SFTP', e);
      onProgress?.call('Retrying ADSM upload over SFTP…');
    }

    try {
      await _pushBundledAdsmViaSftp(client, hostId: hostId, payloads: payloads);
      onProgress?.call('ADSM v$kRequiredAdsmVersion uploaded');
      return _BundledAdsmPush.ok;
    } catch (e) {
      SafeLog.d('Bundled ADSM upload failed', e);
      onProgress?.call('Bundled ADSM upload failed');
      return _BundledAdsmPush.failed;
    }
  }

  Future<void> _runScriptViaStdin(
    SSHClient client, {
    required String hostId,
    required String script,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final gate = _pool[hostId]?.gate;
    Future<void> body() async {
      final session = await client.execute('bash -s');
      try {
        session.stdin.add(utf8.encode(script));
        await session.stdin.close();
        final chunks = await Future.wait<Uint8List>([
          _readAll(session.stdout),
          _readAll(session.stderr),
        ]).timeout(timeout);
        await session.done.timeout(const Duration(seconds: 10));
        final code = session.exitCode ?? 0;
        if (code != 0) {
          final err = utf8.decode(chunks[1]).trim();
          final out = utf8.decode(chunks[0]).trim();
          final detail = err.isNotEmpty ? err : out;
          throw Exception(
            detail.isEmpty ? 'Remote script failed (exit $code)' : detail,
          );
        }
      } on TimeoutException {
        try {
          session.close();
        } catch (_) {}
        throw TimeoutException('Remote script timed out after $timeout');
      }
    }

    return gate == null ? body() : gate.run(body);
  }

  Future<void> _pushBundledAdsmViaStdin(
    SSHClient client, {
    required String hostId,
    required Map<String, Uint8List> payloads,
  }) async {
    final buf = StringBuffer()
      ..writeln('set -euo pipefail')
      ..writeln('SHARE="\$HOME/.local/share/agentdock/host/adsm"')
      ..writeln('BIN="\$HOME/.local/bin"')
      ..writeln('mkdir -p "\$SHARE" "\$BIN"');
    for (final entry in payloads.entries) {
      buf
        ..writeln('base64 -d > "\$SHARE/${entry.key}" <<\'ADSM_B64\'')
        ..writeln(base64Encode(entry.value))
        ..writeln('ADSM_B64');
    }
    buf
      ..writeln('cat > "\$BIN/agentdock-adsm" <<\'ADSM_WRAP\'')
      ..writeln(_adsmWrapper.trimRight())
      ..writeln('ADSM_WRAP')
      ..writeln(_adsmRestartScript);
    await _runScriptViaStdin(
      client,
      hostId: hostId,
      script: buf.toString(),
      timeout: const Duration(minutes: 3),
    );
  }

  Future<void> _pushBundledAdsmViaSftp(
    SSHClient client, {
    required String hostId,
    required Map<String, Uint8List> payloads,
  }) async {
    final homeOut = await _run(
      client,
      r'printf %s "$HOME"',
      hostId: hostId,
      timeout: const Duration(seconds: 8),
    );
    final home = homeOut.trim();
    if (home.isEmpty) {
      throw Exception('Could not resolve remote HOME');
    }

    final share = '$home/.local/share/agentdock/host/adsm';
    final binDir = '$home/.local/bin';
    await _run(
      client,
      'mkdir -p ${shellQuote(share)} ${shellQuote(binDir)}',
      hostId: hostId,
      timeout: const Duration(seconds: 10),
    );

    final sftp = await client.sftp();
    try {
      for (final entry in payloads.entries) {
        final remote = '$share/${entry.key}';
        final remoteFile = await sftp.open(
          remote,
          mode:
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        try {
          await remoteFile.writeBytes(entry.value);
        } finally {
          await remoteFile.close();
        }
      }

      final wrapperPath = '$binDir/agentdock-adsm';
      final wrapperFile = await sftp.open(
        wrapperPath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        await wrapperFile.writeBytes(
          Uint8List.fromList(utf8.encode(_adsmWrapper)),
        );
      } finally {
        await wrapperFile.close();
      }
    } finally {
      sftp.close();
    }

    await _run(
      client,
      _adsmRestartScript,
      hostId: hostId,
      timeout: const Duration(seconds: 45),
    );
  }

  /// Downloads and runs an Agent Dock `scripts/*.sh` installer on the host.
  ///
  /// Returns false when the download/run failed so callers can try a fallback.
  Future<bool> _runAgentDockInstallScriptOnHost(
    Host host, {
    required String scriptName,
    void Function(String status)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (_preferLocalFs(host)) {
      final url = '$kAgentDockScriptsBase/$scriptName';
      onProgress?.call('Running $scriptName…');
      try {
        await exec(host, '''
set -e
export AGENTDOCK_SKIP_TMUX=1
export AGENTDOCK_SKIP_ADSM=1
export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH"
[ -s "\$HOME/.nvm/nvm.sh" ] && . "\$HOME/.nvm/nvm.sh"
curl -fsSL ${shellQuote(url)} | bash
''', timeout: timeout);
        return true;
      } catch (e) {
        SafeLog.d('Agent Dock install script $scriptName failed (local)', e);
        onProgress?.call('Install script failed — trying fallback…');
        return false;
      }
    }
    final client = await connect(host).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'SSH connect timed out while running $scriptName',
      ),
    );
    return _runAgentDockInstallScript(
      client,
      hostId: host.id,
      scriptName: scriptName,
      onProgress: onProgress,
      timeout: timeout,
    );
  }

  /// Downloads and runs an Agent Dock `scripts/*.sh` installer on the host.
  ///
  /// Returns false when the download/run failed so callers can try a fallback.
  Future<bool> _runAgentDockInstallScript(
    SSHClient client, {
    required String hostId,
    required String scriptName,
    void Function(String status)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final url = '$kAgentDockScriptsBase/$scriptName';
    onProgress?.call('Running $scriptName on the remote…');
    try {
      await _runWithInstallProgress(
        client,
        '''
set -e
export AGENTDOCK_SKIP_TMUX=1
export AGENTDOCK_SKIP_ADSM=1
export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH"
[ -s "\$HOME/.nvm/nvm.sh" ] && . "\$HOME/.nvm/nvm.sh"
curl -fsSL ${shellQuote(url)} | bash
''',
        hostId: hostId,
        timeout: timeout,
        onProgress: onProgress,
      );
      return true;
    } catch (e) {
      SafeLog.d('Agent Dock install script $scriptName failed', e);
      onProgress?.call('Install script failed — trying fallback…');
      return false;
    }
  }

  Future<String?> _resolveClaudeAcpPathOnHost(Host host) async {
    // Fast path: known install locations only — never source nvm (that hangs
    // on some hosts and left the UI stuck on "Checking Claude…").
    const script = r'''
set +e
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
for p in \
  "$HOME/.local/bin/claude-code-acp" \
  "$HOME/.local/bin/claude-agent-acp" \
  "$HOME/.npm-global/bin/claude-code-acp" \
  "$HOME/.npm-global/bin/claude-agent-acp" \
  /usr/local/bin/claude-code-acp \
  /usr/local/bin/claude-agent-acp; do
  if [ -x "$p" ]; then printf %s "$p"; exit 0; fi
done
for p in "$HOME"/.nvm/versions/node/*/bin/claude-code-acp \
         "$HOME"/.nvm/versions/node/*/bin/claude-agent-acp; do
  if [ -x "$p" ]; then printf %s "$p"; exit 0; fi
done
command -v claude-code-acp 2>/dev/null && exit 0
command -v claude-agent-acp 2>/dev/null && exit 0
exit 1
''';
    try {
      final out = await exec(
        host,
        'sh -c ${shellQuote(script)}',
        timeout: const Duration(seconds: 12),
      );
      final path = out.trim().split('\n').last.trim();
      return path.isEmpty ? null : path;
    } catch (e) {
      SafeLog.d('resolve Claude ACP path failed', e);
      final t = e.toString().toLowerCase();
      if (t.contains('timed out') ||
          t.contains('transport') ||
          t.contains('channel') ||
          t.contains('connection') ||
          t.contains('broken pipe') ||
          t.contains('socket') ||
          t.contains('gate timed out')) {
        rethrow;
      }
      return null;
    }
  }

  Future<String?> _resolveCodexAcpPathOnHost(Host host) async {
    // Known install locations only — never source nvm here (it can hang).
    const script = r'''
set +e
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
for p in \
  "$HOME/.local/bin/codex-acp" \
  "$HOME/.npm-global/bin/codex-acp" \
  /usr/local/bin/codex-acp \
  /opt/homebrew/bin/codex-acp; do
  if [ -x "$p" ]; then printf %s "$p"; exit 0; fi
done
for p in "$HOME"/.nvm/versions/node/*/bin/codex-acp; do
  if [ -x "$p" ]; then printf %s "$p"; exit 0; fi
done
command -v codex-acp 2>/dev/null && exit 0
exit 1
''';
    try {
      final out = await exec(
        host,
        'sh -c ${shellQuote(script)}',
        timeout: const Duration(seconds: 12),
      );
      final path = out.trim().split('\n').last.trim();
      return path.isEmpty ? null : path;
    } catch (e) {
      SafeLog.d('resolve Codex ACP path failed', e);
      final t = e.toString().toLowerCase();
      if (t.contains('timed out') ||
          t.contains('transport') ||
          t.contains('channel') ||
          t.contains('connection') ||
          t.contains('broken pipe') ||
          t.contains('socket') ||
          t.contains('gate timed out')) {
        rethrow;
      }
      return null;
    }
  }

  Future<String?> _resolveCursorCliPathOnHost(Host host) async {
    // Shell only — SFTP probes through ProxyJump often hang with no timeout
    // and left the UI stuck on "Checking Cursor CLI…".
    const script =
        r'export PATH="$HOME/.local/bin:$HOME/.cursor/bin:/usr/local/bin:$PATH"; '
        r'for p in "$HOME/.local/bin/cursor-agent" "$HOME/.local/bin/agent" '
        r'"$HOME/.cursor/bin/cursor-agent" "$HOME/.cursor/bin/agent" '
        r'/usr/local/bin/cursor-agent /usr/local/bin/agent; '
        r'do [ -x "$p" ] && printf %s "$p" && exit 0; done; '
        r'command -v cursor-agent 2>/dev/null && exit 0; '
        r'command -v agent 2>/dev/null && exit 0; '
        r'exit 1';
    try {
      final out = await exec(
        host,
        'sh -c ${shellQuote(script)}',
        timeout: const Duration(seconds: 15),
      );
      final path = out.trim().split('\n').last.trim();
      return path.isEmpty ? null : path;
    } catch (e) {
      SafeLog.d('resolve Cursor CLI path failed', e);
      final t = e.toString().toLowerCase();
      if (t.contains('timed out') ||
          t.contains('transport') ||
          t.contains('channel') ||
          t.contains('connection') ||
          t.contains('broken pipe') ||
          t.contains('socket') ||
          t.contains('gate timed out')) {
        rethrow;
      }
      // Clean "not found" (exit 1) — try install path.
      return null;
    }
  }

  Future<bool> remotePathExists(Host host, String path) async {
    final normalized = normalizeRemotePath(path.replaceAll(r'\', '/'));
    if (_preferLocalFs(host)) {
      try {
        return await Directory(normalized).exists();
      } catch (e) {
        SafeLog.d('localPathExists failed', e);
        return false;
      }
    }
    try {
      final out = await exec(
        host,
        'test -d ${shellQuote(normalized)} && echo OK || true',
      );
      return out.trim() == 'OK';
    } catch (e) {
      SafeLog.d('remotePathExists failed', e);
      return false;
    }
  }

  /// Absolute home directory for the SSH user (no trailing slash, except `/`).
  ///
  /// For This Mac / This PC on desktop, uses local `$HOME` — no SSH
  /// (same idea as the local PTY terminal).
  Future<String> remoteHomeDirectory(Host host) async {
    if (_preferLocalFs(host)) {
      final home =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '/';
      return normalizeRemotePath(home.replaceAll(r'\', '/'));
    }
    final out = await exec(host, 'printf %s "\$HOME"');
    final home = out.trim();
    if (home.isEmpty) return '/';
    return home.endsWith('/') && home != '/'
        ? home.substring(0, home.length - 1)
        : home;
  }

  /// List directories (and symlink-to-dir) under [path] via SFTP.
  Future<RemoteListing> listRemoteDirectories(Host host, String path) async {
    final full = await listRemoteEntries(host, path);
    return RemoteListing(
      path: full.path,
      directories: full.entries
          .where((e) => e.isDirectory)
          .map((e) => RemoteDirEntry(name: e.name, isSymlink: e.isSymlink))
          .toList(),
    );
  }

  /// List files and directories under [path] via SFTP (or local FS on This Mac/PC).
  Future<RemoteFileListing> listRemoteEntries(Host host, String path) async {
    if (_preferLocalFs(host)) {
      return _listLocalEntries(path);
    }
    final normalized = normalizeRemotePath(path);
    final client = await connect(host);
    final sftp = await client.sftp();
    final items = await sftp.listdir(normalized);
    final entries = <RemoteFileEntry>[];
    for (final item in items) {
      final name = item.filename;
      if (name == '.' || name == '..') continue;
      final attrs = item.attr;
      entries.add(
        RemoteFileEntry(
          name: name,
          isDirectory: attrs.isDirectory,
          isSymlink: attrs.isSymbolicLink,
          size: attrs.size,
          modifiedAt: attrs.modifyTime != null
              ? DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000)
              : null,
        ),
      );
    }
    _sortRemoteEntries(entries);
    return RemoteFileListing(path: normalized, entries: entries);
  }

  bool _preferLocalFs(Host host) =>
      isDesktopLocalHostPlatform && isLocalThisComputerHost(host);

  Future<RemoteFileListing> _listLocalEntries(String path) async {
    final normalized = normalizeRemotePath(path.replaceAll(r'\', '/'));
    final dir = Directory(normalized);
    if (!await dir.exists()) {
      throw FileSystemException('Directory not found', normalized);
    }
    final entries = <RemoteFileEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      // Directory.uri ends with `/`, so pathSegments.last is often "".
      final name = _localBasename(entity.path);
      if (name.isEmpty || name == '.' || name == '..') continue;
      final isLink = entity is Link;
      var isDirectory = entity is Directory;
      int? size;
      if (entity is File) {
        try {
          size = await entity.length();
        } catch (_) {}
      }
      DateTime? modifiedAt;
      try {
        modifiedAt = (await entity.stat()).modified;
        if (isLink) {
          try {
            final targetType = await FileSystemEntity.type(entity.path);
            isDirectory = targetType == FileSystemEntityType.directory;
          } catch (_) {}
        }
      } catch (_) {}
      entries.add(
        RemoteFileEntry(
          name: name,
          isDirectory: isDirectory,
          isSymlink: isLink,
          size: size,
          modifiedAt: modifiedAt,
        ),
      );
    }
    _sortRemoteEntries(entries);
    return RemoteFileListing(path: normalized, entries: entries);
  }

  void _sortRemoteEntries(List<RemoteFileEntry> entries) {
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  static String _localBasename(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final trimmed = normalized.endsWith('/') && normalized.length > 1
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final i = trimmed.lastIndexOf('/');
    return i < 0 ? trimmed : trimmed.substring(i + 1);
  }

  /// Download a remote file to [localPath]. Returns bytes written.
  ///
  /// Uses a **dedicated** SSH connection (not the pooled ADSM/agent link) so
  /// agent traffic cannot starve SFTP. Multipart pipelining is used for large
  /// files; if progress stalls, the transfer is aborted and retried once with
  /// a single in-flight read (more reliable on some HPC SSHDs).
  ///
  /// Always re-stats the remote file for length — directory listing sizes can
  /// be wrong and previously caused truncated/corrupt archives.
  Future<int> downloadRemoteFile(
    Host host,
    String remotePath,
    String localPath, {
    void Function(int bytes, int? total)? onProgress,
    int? totalBytes,
    bool multipart = true,
    bool Function()? isCancelled,
  }) async {
    final remote = normalizeRemotePath(remotePath);
    if (_preferLocalFs(host)) {
      final src = File(remote);
      final len = await src.length();
      onProgress?.call(0, len);
      await src.copy(localPath);
      onProgress?.call(len, len);
      return len;
    }
    try {
      return await _downloadRemoteFileOnce(
        host,
        remote,
        localPath,
        onProgress: onProgress,
        totalBytes: totalBytes,
        multipart: multipart,
        isCancelled: isCancelled,
        maxPending: multipart ? 8 : 1,
      );
    } on _DownloadStalled catch (e) {
      SafeLog.d(
        'download stalled at ${e.bytesRead}B — retrying sequential '
        '$remote',
        e,
      );
      if (isCancelled?.call() == true) throw const _DownloadCancelled();
      onProgress?.call(0, e.total);
      return _downloadRemoteFileOnce(
        host,
        remote,
        localPath,
        onProgress: onProgress,
        totalBytes: e.total ?? totalBytes,
        multipart: false,
        isCancelled: isCancelled,
        maxPending: 1,
        chunkSize: 128 * 1024,
      );
    }
  }

  Future<int> _downloadRemoteFileOnce(
    Host host,
    String remote,
    String localPath, {
    void Function(int bytes, int? total)? onProgress,
    int? totalBytes,
    bool multipart = true,
    bool Function()? isCancelled,
    int maxPending = 8,
    int chunkSize = 64 * 1024,
  }) async {
    // Exclusive session: file transfer must not share the ADSM event channel.
    final client = await connectExclusive(host);
    final local = File(localPath);
    await local.parent.create(recursive: true);

    var lastProgressAt = DateTime.now();
    var lastBytes = 0;
    var progressTotal = totalBytes;
    Timer? stallWatch;
    var stalled = false;

    void armStallWatch() {
      stallWatch?.cancel();
      stallWatch = Timer.periodic(const Duration(seconds: 5), (_) {
        if (isCancelled?.call() == true) {
          try {
            client.close();
          } catch (_) {}
          return;
        }
        final idle = DateTime.now().difference(lastProgressAt);
        // HPC links can pause between chunks; 45s with zero movement is stuck.
        if (idle >= const Duration(seconds: 45) && lastBytes > 0) {
          stalled = true;
          SafeLog.d(
            'SFTP download stall ${idle.inSeconds}s at $lastBytes '
            'of ${progressTotal ?? '?'} — closing exclusive SSH',
          );
          try {
            client.close();
          } catch (_) {}
        }
      });
    }

    try {
      final sftp = await client.sftp();
      final remoteFile = await sftp.open(remote, mode: SftpFileOpenMode.read);
      try {
        final attrs = await remoteFile.stat();
        final actualTotal = attrs.size ?? totalBytes;
        if (actualTotal == null || actualTotal < 0) {
          throw StateError('Cannot determine remote file size for $remote');
        }
        progressTotal = actualTotal;
        if (actualTotal == 0) {
          await local.writeAsBytes(const []);
          onProgress?.call(0, 0);
          return 0;
        }

        onProgress?.call(0, actualTotal);
        armStallWatch();

        final large = actualTotal >= (1 << 20); // 1 MiB
        final useMultipart = multipart && large;
        final pending = useMultipart ? maxPending : 1;

        final raf = await local.open(mode: FileMode.write);
        try {
          await raf.truncate(0);
          final written = await remoteFile.downloadToRandomAccess(
            raf,
            length: actualTotal,
            onProgress: (bytes) {
              if (isCancelled?.call() == true) {
                throw const _DownloadCancelled();
              }
              if (bytes > lastBytes) {
                lastBytes = bytes;
                lastProgressAt = DateTime.now();
              }
              onProgress?.call(bytes, actualTotal);
            },
            chunkSize: chunkSize,
            maxPendingRequests: pending,
          );
          await raf.flush();
          await raf.close();

          if (written != actualTotal) {
            try {
              await local.delete();
            } catch (_) {}
            throw StateError(
              'Download incomplete: got $written of $actualTotal bytes',
            );
          }

          final onDisk = await local.length();
          if (onDisk != actualTotal) {
            try {
              await local.delete();
            } catch (_) {}
            throw StateError(
              'Download size mismatch: file is $onDisk, expected $actualTotal',
            );
          }

          return written;
        } on _DownloadCancelled {
          try {
            await raf.close();
          } catch (_) {}
          try {
            if (await local.exists()) await local.delete();
          } catch (_) {}
          rethrow;
        } catch (e) {
          try {
            await raf.close();
          } catch (_) {}
          try {
            if (await local.exists()) await local.delete();
          } catch (_) {}
          if (stalled || _looksLikeSshDrop(e)) {
            throw _DownloadStalled(bytesRead: lastBytes, total: actualTotal);
          }
          rethrow;
        }
      } finally {
        try {
          await remoteFile.close();
        } catch (_) {}
      }
    } finally {
      stallWatch?.cancel();
      try {
        client.close();
      } catch (_) {}
    }
  }

  static bool _looksLikeSshDrop(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('closed') ||
        s.contains('socket') ||
        s.contains('connection') ||
        s.contains('broken pipe') ||
        (s.contains('sftp') && s.contains('error'));
  }

  /// Upload local bytes/file to [remotePath] (overwrites).
  Future<void> uploadRemoteFile(
    Host host,
    String localPath,
    String remotePath, {
    void Function(int bytes)? onProgress,
  }) async {
    final remote = normalizeRemotePath(remotePath);
    if (_preferLocalFs(host)) {
      await File(localPath).copy(remote);
      onProgress?.call(await File(remote).length());
      return;
    }
    final bytes = await File(localPath).readAsBytes();
    final client = await connect(host);
    final sftp = await client.sftp();
    final remoteFile = await sftp.open(
      remote,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );
    try {
      await remoteFile.writeBytes(bytes);
      onProgress?.call(bytes.length);
    } finally {
      await remoteFile.close();
    }
  }

  Future<void> mkdirRemote(Host host, String remotePath) async {
    final remote = normalizeRemotePath(remotePath);
    if (_preferLocalFs(host)) {
      await Directory(remote).create(recursive: true);
      return;
    }
    final client = await connect(host);
    final sftp = await client.sftp();
    await sftp.mkdir(remote);
  }

  Future<void> removeRemoteFile(Host host, String remotePath) async {
    final remote = normalizeRemotePath(remotePath);
    if (_preferLocalFs(host)) {
      final type = await FileSystemEntity.type(remote);
      if (type == FileSystemEntityType.directory) {
        await Directory(remote).delete(recursive: false);
      } else {
        await File(remote).delete();
      }
      return;
    }
    final client = await connect(host);
    final sftp = await client.sftp();
    await sftp.remove(remote);
  }

  /// True if [path] is [root] or a child of [root].
  static bool isUnderRoot(String root, String path) {
    final r = normalizeRemotePath(root);
    final p = normalizeRemotePath(path);
    if (r == '/') return true;
    return p == r || p.startsWith('$r/');
  }

  static String normalizeRemotePath(String path) {
    var p = path.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String joinRemotePath(String parent, String child) {
    final base = normalizeRemotePath(parent);
    if (base == '/') return '/$child';
    return '$base/$child';
  }

  static String? parentRemotePath(String path) {
    final normalized = normalizeRemotePath(path);
    if (normalized == '/') return null;
    final index = normalized.lastIndexOf('/');
    if (index <= 0) return '/';
    return normalized.substring(0, index);
  }

  /// `command -v` with an extended PATH (non-login; avoids hanging .bashrc).
  // ignore: unused_element
  Future<String?> _whichLogin(
    SSHClient client,
    String binary,
    String hostId,
  ) async {
    final name = binary.replaceAll("'", '');
    try {
      final out = await _run(
        client,
        "bash -c ${shellQuote('export PATH="\$HOME/.local/bin:\$PATH"; command -v $name')}",
        hostId: hostId,
        timeout: const Duration(seconds: 10),
      );
      final path = out.trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  static String shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  void dispose() {
    _healthTimer?.cancel();
    _healthTimer = null;
    closeAll();
  }
}

class RemoteDirEntry {
  const RemoteDirEntry({required this.name, this.isSymlink = false});

  final String name;
  final bool isSymlink;
}

class RemoteListing {
  const RemoteListing({required this.path, required this.directories});

  final String path;
  final List<RemoteDirEntry> directories;
}

class RemoteFileEntry {
  const RemoteFileEntry({
    required this.name,
    required this.isDirectory,
    this.isSymlink = false,
    this.size,
    this.modifiedAt,
  });

  final String name;
  final bool isDirectory;
  final bool isSymlink;
  final int? size;
  final DateTime? modifiedAt;

  String get sizeLabel {
    if (isDirectory || size == null) return '';
    final s = size!;
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    if (s < 1024 * 1024 * 1024) {
      return '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(s / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class RemoteFileListing {
  const RemoteFileListing({required this.path, required this.entries});

  final String path;
  final List<RemoteFileEntry> entries;
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();

  @override
  String toString() => 'Download cancelled';
}

class _DownloadStalled implements Exception {
  const _DownloadStalled({required this.bytesRead, this.total});

  final int bytesRead;
  final int? total;

  @override
  String toString() =>
      'Download stalled after $bytesRead bytes'
      '${total != null ? ' of $total' : ''}';
}
