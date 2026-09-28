import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/secure/safe_log.dart';

/// Stable id for the auto-added "this computer" host on desktop.
const kLocalThisComputerHostId = 'local-this-computer';

bool get isDesktopLocalHostPlatform {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

/// "This Mac" / "This PC" for the machine Agent Dock runs on.
String get localComputerLabel => Platform.isMacOS ? 'This Mac' : 'This PC';

// Windows: agents on This PC run inside WSL — ADSM needs tmux, FIFOs and Unix
// sockets. Paths on this host are then WSL paths (`/home/me/x`,
// `/mnt/c/Users/me/x`); dart:io reaches them through [localFsPath].
String? _wslHome;
String? _wslUncRoot;

/// Process + arguments that run [script] in a login bash on this computer.
(String, List<String>) localShellInvocation(String script) =>
    Platform.isWindows
        ? ('wsl.exe', ['-e', 'bash', '-lc', script])
        : ('/bin/bash', ['-lc', script]);

/// User-facing reason the local shell failed to start.
String localShellMissingHint(Object error) => Platform.isWindows
    ? 'Agents on This PC run in WSL, which is not available ($error).\n'
          'Install it from an admin PowerShell with `wsl --install`, restart, '
          'then open Agent Dock again.'
    : 'Could not run local shell: $error';

/// Learn the WSL home and its `\\wsl.localhost\<distro>` root (Windows only).
Future<void> initLocalShellPaths() async {
  if (!Platform.isWindows || _wslHome != null) return;
  try {
    final r = await Process.run('wsl.exe', [
      '-e',
      'sh',
      '-c',
      r'printf "%s\n" "$HOME"; wslpath -w /',
    ]).timeout(const Duration(seconds: 20));
    if (r.exitCode != 0) return;
    final lines = (r.stdout as String)
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return;
    _wslHome = lines[0];
    var root = lines[1];
    while (root.endsWith(r'\')) {
      root = root.substring(0, root.length - 1);
    }
    _wslUncRoot = root;
  } catch (e) {
    SafeLog.d('WSL path lookup failed', e);
  }
}

/// Home directory of This Mac/PC, as the agent's shell sees it.
String localHostHome() {
  if (Platform.isWindows) return _wslHome ?? '/';
  return Platform.environment['HOME'] ?? '/';
}

/// A path on This Mac/PC → a path dart:io can open. Identity except on
/// Windows, where WSL paths map to drive letters or the WSL network share.
String localFsPath(String hostPath) {
  if (!Platform.isWindows) return hostPath;
  final drive = RegExp(r'^/mnt/([a-zA-Z])(/.*)?$').firstMatch(hostPath);
  if (drive != null) {
    return '${drive.group(1)!.toUpperCase()}:${drive.group(2) ?? '/'}';
  }
  final root = _wslUncRoot;
  if (root == null || !hostPath.startsWith('/')) return hostPath;
  return '$root${hostPath.replaceAll('/', r'\')}';
}

bool isLocalThisComputerHost(Host host) {
  if (host.id == kLocalThisComputerHostId) return true;
  // ProxyJump / SSH tunnels (e.g. VDI via bastion on localhost:2255) are not
  // the machine Agent Dock is running on.
  if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) return false;
  final h = host.hostname.trim().toLowerCase();
  final loopback = h == 'localhost' || h == '127.0.0.1' || h == '::1';
  // Port 22 only — non-22 localhost ports are almost always port-forwards.
  return loopback && host.port == 22;
}

String localOsUsername() {
  if (Platform.isWindows) {
    return Platform.environment['USERNAME'] ??
        Platform.environment['USER'] ??
        'user';
  }
  return Platform.environment['USER'] ?? 'user';
}

Future<String> localComputerDisplayName() async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('scutil', ['--get', 'ComputerName']);
      if (r.exitCode == 0) {
        final name = (r.stdout as String).trim();
        if (name.isNotEmpty) return name;
      }
    } else if (Platform.isWindows) {
      final r = await Process.run('hostname', []);
      if (r.exitCode == 0) {
        final name = (r.stdout as String).trim();
        if (name.isNotEmpty) return name;
      }
    }
  } catch (e) {
    SafeLog.d('local computer name lookup failed', e);
  }
  final host = Platform.localHostname.trim();
  if (host.isNotEmpty) return host;
  return localComputerLabel;
}

/// Ensure a Host entry for the machine Agent Dock is running on (Mac / Windows).
///
/// Uses `127.0.0.1` so agents/ADSM talk to the local SSH daemon (Remote Login
/// on macOS, OpenSSH Server on Windows). The in-app terminal for this host uses
/// a local PTY instead (like VS Code) and does not need SSH.
/// Idempotent — does not overwrite an existing row the user may have edited.
Future<Host?> ensureLocalThisComputerHost(AppDatabase db) async {
  if (!isDesktopLocalHostPlatform) return null;
  await initLocalShellPaths();

  final existing = await db.getHost(kLocalThisComputerHostId);
  if (existing != null) return existing;

  final username = localOsUsername();
  final computer = await localComputerDisplayName();
  final alias = '$localComputerLabel · $computer';

  // Put this machine at the top of the list.
  final hosts = await db.listHosts();
  for (var i = 0; i < hosts.length; i++) {
    final h = hosts[i];
    if (h.sortOrder < 1) {
      await db.upsertHost(h.copyWith(sortOrder: h.sortOrder + 1));
    }
  }

  final host = Host(
    id: kLocalThisComputerHostId,
    alias: alias,
    hostname: '127.0.0.1',
    username: username,
    port: 22,
    sortOrder: 0,
    createdAt: DateTime.now(),
  );
  await db.upsertHost(host);
  SafeLog.d('Auto-added local host $alias ($username@127.0.0.1)');
  return host;
}

/// Default identity files under `~/.ssh` (no passphrase prompt).
Future<String?> readDefaultSshPrivateKeyPem() async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return null;
  for (final name in const ['id_ed25519', 'id_rsa', 'id_ecdsa']) {
    final file = File(p.join(home, '.ssh', name));
    try {
      if (!await file.exists()) continue;
      final pem = await file.readAsString();
      if (pem.trim().isEmpty) continue;
      return pem;
    } catch (e) {
      SafeLog.d('read default ssh key $name failed', e);
    }
  }
  return null;
}

/// True when something accepts TCP on [host.port] (usually sshd).
Future<bool> isLocalSshPortOpen(Host host) async {
  if (!isLocalThisComputerHost(host)) return true;
  try {
    final socket = await Socket.connect(
      host.hostname,
      host.port,
      timeout: const Duration(milliseconds: 600),
    );
    await socket.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// Human guidance when local SSH is refused / unreachable.
///
/// Agents on This Mac/PC now use a local shell + ADSM process (like the
/// Terminal button). SSH / Remote Login is only needed for true remote hosts.
String localThisComputerSshHint() {
  if (Platform.isMacOS) {
    return 'Could not reach 127.0.0.1:22 (Remote Login appears off).\n\n'
        'Agents and Terminal on This Mac usually do not need Remote Login '
        'anymore — reopen Agent Dock and try again.\n\n'
        'If you still need SSH for something else: System Settings → General → '
        'Sharing → Remote Login (allow your user).';
  }
  if (Platform.isWindows) {
    return 'Could not reach 127.0.0.1:22 (OpenSSH Server appears off).\n\n'
        'Agents and Terminal on This PC usually do not need OpenSSH '
        'anymore — reopen Agent Dock and try again.\n\n'
        'If you still need SSH: install/start OpenSSH Server in Optional Features.';
  }
  return 'Local SSH on 127.0.0.1:22 refused the connection.';
}

/// Rewrite low-level socket errors for the auto "This Mac/PC" host.
String describeLocalHostConnectError(Object error, Host host) {
  if (!isLocalThisComputerHost(host)) return error.toString();
  final text = error.toString();
  if (text.contains('Connection refused') ||
      text.contains('errno = 61') ||
      text.contains('errno = 111') ||
      text.toLowerCase().contains('connection refused')) {
    return localThisComputerSshHint();
  }
  return text;
}

/// Opens macOS Sharing / Remote Login settings when possible.
Future<void> openLocalRemoteLoginSettings() async {
  if (!Platform.isMacOS) return;
  try {
    final r = await Process.run('open', [
      'x-apple.systempreferences:com.apple.Sharing-Settings.extension',
    ]);
    if (r.exitCode == 0) return;
  } catch (e) {
    SafeLog.d('open Sharing settings failed', e);
  }
  try {
    await Process.run('open', [
      '/System/Library/PreferencePanes/SharingPref.prefPane',
    ]);
  } catch (e) {
    SafeLog.d('open Sharing pref pane failed', e);
  }
}
