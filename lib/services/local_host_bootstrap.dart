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
  return Platform.isMacOS || Platform.isWindows;
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
  return Platform.isMacOS ? 'This Mac' : 'This PC';
}

/// Ensure a Host entry for the machine Agent Dock is running on (Mac / Windows).
///
/// Uses `127.0.0.1` so agents/ADSM talk to the local SSH daemon (Remote Login
/// on macOS, OpenSSH Server on Windows). The in-app terminal for this host uses
/// a local PTY instead (like VS Code) and does not need SSH.
/// Idempotent — does not overwrite an existing row the user may have edited.
Future<Host?> ensureLocalThisComputerHost(AppDatabase db) async {
  if (!isDesktopLocalHostPlatform) return null;

  final existing = await db.getHost(kLocalThisComputerHostId);
  if (existing != null) return existing;

  final username = localOsUsername();
  final computer = await localComputerDisplayName();
  final alias =
      Platform.isMacOS ? 'This Mac · $computer' : 'This PC · $computer';

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
