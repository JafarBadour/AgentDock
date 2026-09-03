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
  static const _anthropicApiKey = 'anthropic_api_key';
  static const _gcpSpeechApiKey = 'gcp_speech_api_key';
  static const _gcpSpeechLanguage = 'gcp_speech_language';

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

  Future<void> saveAnthropicApiKey(String? key) async {
    if (key == null || key.trim().isEmpty) {
      await _delete(_anthropicApiKey);
      return;
    }
    await _write(_anthropicApiKey, key.trim());
  }

  Future<String?> readAnthropicApiKey() => _read(_anthropicApiKey);

  Future<bool> hasAnthropicApiKey() async {
    final value = await readAnthropicApiKey();
    return value != null && value.trim().isNotEmpty;
  }

  Future<void> saveGcpSpeechApiKey(String? key) async {
    if (key == null || key.trim().isEmpty) {
      await _delete(_gcpSpeechApiKey);
      return;
    }
    await _write(_gcpSpeechApiKey, key.trim());
  }

  /// Gemini key from Connect, else `GEMINI_API_KEY` env / project `.env` (dev).
  Future<String?> readGcpSpeechApiKey() async {
    final stored = await _read(_gcpSpeechApiKey);
    if (stored != null && stored.trim().isNotEmpty) return stored.trim();
    final fromEnv = Platform.environment['GEMINI_API_KEY']?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    return _readDotEnvValue('GEMINI_API_KEY');
  }

  Future<bool> hasGcpSpeechApiKey() async {
    final value = await readGcpSpeechApiKey();
    return value != null && value.trim().isNotEmpty;
  }

  /// Best-effort `KEY=value` from a local `.env` (flutter run / tests only).
  Future<String?> _readDotEnvValue(String key) async {
    try {
      for (final path in ['.env', '../.env']) {
        final f = File(path);
        if (!await f.exists()) continue;
        for (final line in await f.readAsLines()) {
          final t = line.trim();
          if (t.isEmpty || t.startsWith('#')) continue;
          final i = t.indexOf('=');
          if (i <= 0) continue;
          if (t.substring(0, i).trim() != key) continue;
          var v = t.substring(i + 1).trim();
          if ((v.startsWith('"') && v.endsWith('"')) ||
              (v.startsWith("'") && v.endsWith("'"))) {
            v = v.substring(1, v.length - 1);
          }
          if (v.isNotEmpty) return v;
        }
      }
    } catch (e) {
      SafeLog.d('dotenv read failed', e);
    }
    return null;
  }

  Future<void> saveGcpSpeechLanguage(String? code) async {
    if (code == null || code.trim().isEmpty) {
      await _delete(_gcpSpeechLanguage);
      return;
    }
    await _write(_gcpSpeechLanguage, code.trim());
  }

  Future<String> readGcpSpeechLanguage() async {
    final v = await _read(_gcpSpeechLanguage);
    if (v == null || v.trim().isEmpty) return 'en-US';
    return v.trim();
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
