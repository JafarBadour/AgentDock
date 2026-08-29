import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'safe_log.dart';

/// Secrets storage.
///
/// - **Android / iOS:** platform keystore / keychain.
/// - **macOS / desktop:** mode-0600 files under Application Support only.
///   Unsigned macOS builds spam Keychain password dialogs (-128 / -34018);
///   we never touch Keychain on desktop so the OS never asks.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  static const _sshPrivateKey = 'ssh_private_key';
  static const _sshPassphrase = 'ssh_key_passphrase';
  static const _cursorApiKey = 'cursor_api_key';

  final FlutterSecureStorage _storage;

  /// Desktop always uses files. Mobile uses keystore unless a write fails once.
  bool? _useFileFallback = (!kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows))
      ? true
      : null;

  Future<void> saveSshPrivateKey(String pem) =>
      _write(_sshPrivateKey, pem.trim());

  Future<String?> readSshPrivateKey() => _read(_sshPrivateKey);

  Future<void> clearSshPrivateKey() async {
    await _delete(_sshPrivateKey);
    await _delete(_sshPassphrase);
  }

  Future<void> saveSshPassphrase(String? passphrase) async {
    if (passphrase == null || passphrase.isEmpty) {
      await _delete(_sshPassphrase);
      return;
    }
    await _write(_sshPassphrase, passphrase);
  }

  Future<String?> readSshPassphrase() => _read(_sshPassphrase);

  Future<bool> hasSshPrivateKey() async {
    final value = await readSshPrivateKey();
    return value != null && value.trim().isNotEmpty;
  }

  Future<void> saveCursorApiKey(String? key) async {
    if (key == null || key.trim().isEmpty) {
      await _delete(_cursorApiKey);
      return;
    }
    await _write(_cursorApiKey, key.trim());
  }

  Future<String?> readCursorApiKey() => _read(_cursorApiKey);

  Future<bool> hasCursorApiKey() async {
    final value = await readCursorApiKey();
    return value != null && value.trim().isNotEmpty;
  }

  Future<void> _write(String key, String value) async {
    if (await _shouldUseFileFallback()) {
      await _fileWrite(key, value);
      return;
    }
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      SafeLog.d('Keystore write failed, switching to file fallback', e);
      _useFileFallback = true;
      await _fileWrite(key, value);
    }
  }

  Future<String?> _read(String key) async {
    if (await _shouldUseFileFallback()) {
      return _fileRead(key);
    }
    try {
      return await _storage.read(key: key);
    } catch (e) {
      SafeLog.d('Keystore read failed, switching to file fallback', e);
      _useFileFallback = true;
      return _fileRead(key);
    }
  }

  Future<void> _delete(String key) async {
    if (await _shouldUseFileFallback()) {
      await _fileDelete(key);
      return;
    }
    try {
      await _storage.delete(key: key);
    } catch (e) {
      SafeLog.d('Keystore delete ignored', e);
      _useFileFallback = true;
      await _fileDelete(key);
    }
  }

  Future<bool> _shouldUseFileFallback() async {
    if (_useFileFallback != null) return _useFileFallback!;
    if (kIsWeb) {
      _useFileFallback = true;
      return true;
    }
    // Phone OS: keystore. Never probe Keychain on desktop (set in field init).
    _useFileFallback = false;
    return false;
  }

  Future<File> _secretFile(String key) async {
    final dir = await getApplicationSupportDirectory();
    final secretsDir = Directory(p.join(dir.path, 'secrets'));
    if (!await secretsDir.exists()) {
      await secretsDir.create(recursive: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['700', secretsDir.path]);
      }
    }
    return File(p.join(secretsDir.path, key));
  }

  Future<void> _fileWrite(String key, String value) async {
    final file = await _secretFile(key);
    await file.writeAsString(value, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', file.path]);
    }
  }

  Future<String?> _fileRead(String key) async {
    final file = await _secretFile(key);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<void> _fileDelete(String key) async {
    final file = await _secretFile(key);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
