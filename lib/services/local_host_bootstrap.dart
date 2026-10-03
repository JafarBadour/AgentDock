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

/// "This Mac" / "This PC" for the machine AgentPlantation runs on.
String get localComputerLabel => Platform.isMacOS ? 'This Mac' : 'This PC';

// Windows: agents on This PC run natively (see `WindowsLocalAgent`), and its
// paths are drive paths with forward slashes (`C:/Users/me/x`), which dart:io
// opens as they are.

/// User-facing reason the local shell failed to start.
String localShellMissingHint(Object error) => Platform.isWindows
    ? 'Could not run Git Bash on This PC ($error).\n'
          'Install Git for Windows (`winget install Git.Git`), then open '
          'AgentPlantation again.'
    : 'Could not run local shell: $error';

/// Home directory of This Mac/PC, as the agent's shell sees it.
String localHostHome() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return '/';
  return Platform.isWindows ? home.replaceAll(r'\', '/') : home;
}

/// A path on This Mac/PC → a path dart:io can open.
String localFsPath(String hostPath) => hostPath;

bool isLocalThisComputerHost(Host host) {
  if (host.id == kLocalThisComputerHostId) return true;
  // ProxyJump / SSH tunnels (e.g. VDI via bastion on localhost:2255) are not
  // the machine AgentPlantation is running on.
  if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) return false;
  final h = host.hostname.trim().toLowerCase();
  final loopback = h == 'localhost' || h == '127.0.0.1' || h == '::1';
  // Port 22 only — non-22 localhost ports are almost always port-forwards.
  return loopback && host.port == 22;
}

/// Whether [path] is an absolute folder path of this OS's shape: a drive path
/// (`C:/…`) on Windows, a POSIX path (`/…`) elsewhere.
bool isLocalFolderPathForThisOs(String path, {bool? windows}) {
  final isDrivePath = RegExp(r'^/?[A-Za-z]:([\\/]|$)').hasMatch(path.trim());
  return (windows ?? Platform.isWindows)
      ? isDrivePath
      : !isDrivePath && path.trim().startsWith('/');
}

/// Shell used for local commands on This Mac/PC.
///
/// On Windows a bare `bash` resolves through System32 before PATH, which is
/// WSL's launcher — a different filesystem that cannot see `C:\` as `C:\`.
/// Prefer Git Bash, and fall back to `bash` only when it is not found.
String localBashExecutable() {
  if (!Platform.isWindows) return '/bin/bash';
  final env = Platform.environment;
  final candidates = [
    for (final root in [
      env['ProgramFiles'],
      env['ProgramW6432'],
      env['ProgramFiles(x86)'],
      if (env['LOCALAPPDATA'] != null) p.join(env['LOCALAPPDATA']!, 'Programs'),
    ])
      if (root != null && root.isNotEmpty)
        p.join(root, 'Git', 'bin', 'bash.exe'),
    // `git.exe` on PATH lives in `<Git>\cmd`; bash is in the sibling `bin`.
    for (final dir in (env['PATH'] ?? '').split(';'))
      if (dir.trim().isNotEmpty &&
          File(p.join(dir.trim(), 'git.exe')).existsSync())
        p.join(p.dirname(dir.trim()), 'bin', 'bash.exe'),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return 'bash';
}

/// `PATH` for local commands: ~/.local/bin and common tool dirs first.
String localShellPathEnv() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  return [
    if (home != null && home.isNotEmpty) p.join(home, '.local', 'bin'),
    if (Platform.isMacOS) '/opt/homebrew/bin',
    if (!Platform.isWindows) '/usr/local/bin',
    Platform.environment['PATH'] ?? '',
  ].where((s) => s.isNotEmpty).join(Platform.isWindows ? ';' : ':');
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

/// Ensure a Host entry for the machine AgentPlantation is running on (Mac / Windows).
///
/// Uses `127.0.0.1` so agents/ADSM talk to the local SSH daemon (Remote Login
/// on macOS, OpenSSH Server on Windows). The in-app terminal for this host uses
/// a local PTY instead (like VS Code) and does not need SSH.
/// Idempotent — does not overwrite an existing row the user may have edited.
Future<Host?> ensureLocalThisComputerHost(AppDatabase db) async {
  if (!isDesktopLocalHostPlatform) return null;

  final existing = await db.getHost(kLocalThisComputerHostId);
  if (existing != null) {
    // A `.ag` import from another OS used to carry that machine's row across
    // (e.g. "This Mac · MacBook Pro" on a Windows PC). Re-label it here.
    final foreignPrefix = Platform.isMacOS ? 'This PC' : 'This Mac';
    if (!existing.alias.startsWith(foreignPrefix)) return existing;
    final healed = existing.copyWith(
      alias: await _localHostAlias(),
      username: localOsUsername(),
    );
    await db.upsertHost(healed);
    SafeLog.d('Re-labelled imported local host as ${healed.alias}');
    return healed;
  }

  final username = localOsUsername();
  final alias = await _localHostAlias();

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

Future<String> _localHostAlias() async {
  final computer = await localComputerDisplayName();
  return '$localComputerLabel · $computer';
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
        'anymore — reopen AgentPlantation and try again.\n\n'
        'If you still need SSH for something else: System Settings → General → '
        'Sharing → Remote Login (allow your user).';
  }
  if (Platform.isWindows) {
    return 'Could not reach 127.0.0.1:22 (OpenSSH Server appears off).\n\n'
        'Agents and Terminal on This PC usually do not need OpenSSH '
        'anymore — reopen AgentPlantation and try again.\n\n'
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
