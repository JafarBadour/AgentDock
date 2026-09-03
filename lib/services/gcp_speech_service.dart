import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';

/// Hold-to-talk mic using **on-device** speech recognition (fast; no Gemini).
///
/// Gemini upload was routinely slower than the UI's 3s budget, so the mic now
/// uses the platform recognizer (`speech_to_text`) and returns as soon as you
/// release. [SecureStore] language preference is still used as a locale hint.
class GcpSpeechService {
  GcpSpeechService(this._store);

  final SecureStore _store;
  final SpeechToText _speech = SpeechToText();

  bool _ready = false;
  bool _recording = false;
  String _words = '';
  String? _lastError;

  bool get isRecording => _recording;

  /// Mic no longer needs a cloud key — native STT is enough.
  Future<bool> hasApiKey() => isAvailable();

  Future<bool> isAvailable() async {
    try {
      return await _ensureReady();
    } catch (e) {
      SafeLog.d('speech init failed', e);
      return false;
    }
  }

  Future<bool> hasMicPermission() async {
    return _ensureReady();
  }

  Future<bool> _ensureReady() async {
    if (_ready) return true;
    _lastError = null;
    final ok = await _speech.initialize(
      onError: (e) {
        _lastError = e.errorMsg;
        SafeLog.d('speech error', e.errorMsg);
      },
      onStatus: (status) {
        SafeLog.d('speech status: $status');
      },
    );
    _ready = ok;
    return ok;
  }

  /// Start listening; partial results accumulate until [stopAndTranscribe].
  Future<void> start() async {
    if (_recording) return;
    final ok = await _ensureReady();
    if (!ok) {
      throw StateError(
        _lastError == null || _lastError!.isEmpty
            ? 'Speech recognition is not available on this device.'
            : 'Speech recognition unavailable: $_lastError',
      );
    }

    final language = await _store.readGcpSpeechLanguage();
    _words = '';
    _recording = true;

    // Prefer the saved BCP-47 code when the OS exposes it.
    String? localeId;
    try {
      final locales = await _speech.locales();
      final want = language.toLowerCase();
      for (final loc in locales) {
        final id = loc.localeId.toLowerCase();
        if (id == want || id.startsWith(want.split('-').first)) {
          localeId = loc.localeId;
          break;
        }
      }
    } catch (e) {
      SafeLog.d('speech locales failed', e);
    }

    await _speech.listen(
      onResult: (result) {
        _words = result.recognizedWords;
      },
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 8),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        // Prefer OS recognizer (on-device when available, network otherwise).
        // Still far faster than uploading WAV to Gemini.
        onDevice: false,
      ),
    );
  }

  /// Stop listening and return the recognized text (may be empty).
  Future<String> stopAndTranscribe() async {
    if (!_recording) return _words.trim();
    _recording = false;
    try {
      await _speech.stop();
    } catch (e) {
      SafeLog.d('speech stop failed', e);
    }
    // Brief settle so a final partial can land.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return _words.trim();
  }

  /// Cancel without keeping the transcript.
  Future<void> cancel() async {
    if (!_recording && !_speech.isListening) {
      _words = '';
      return;
    }
    _recording = false;
    _words = '';
    try {
      await _speech.cancel();
    } catch (e) {
      SafeLog.d('speech cancel failed', e);
    }
  }

  static String userFacingMessage(Object error) {
    final raw = error.toString();
    const prefix = 'Bad state: ';
    if (raw.startsWith(prefix)) return raw.substring(prefix.length);
    return raw;
  }

  Future<void> dispose() async {
    await cancel();
  }
}

/// Legacy Gemini response parser (unit tests).
@visibleForTesting
String extractGeminiTranscript(String responseBody) {
  final decoded = jsonDecode(responseBody);
  if (decoded is! Map) return '';
  final candidates = decoded['candidates'];
  if (candidates is! List || candidates.isEmpty) {
    final feedback = decoded['promptFeedback'];
    if (feedback is Map) {
      final reason = feedback['blockReason']?.toString();
      if (reason != null && reason.isNotEmpty) {
        throw StateError('Speech blocked by Gemini ($reason).');
      }
    }
    return '';
  }
  final first = candidates.first;
  if (first is! Map) return '';
  final content = first['content'];
  if (content is! Map) return '';
  final parts = content['parts'];
  if (parts is! List) return '';
  final buf = StringBuffer();
  for (final part in parts) {
    if (part is! Map) continue;
    if (part['thought'] == true) continue;
    final text = part['text'];
    if (text is String) buf.write(text);
  }
  return buf.toString();
}
