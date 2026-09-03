import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';

/// Records mic audio and transcribes it with the Gemini API (Google AI key).
class GcpSpeechService {
  GcpSpeechService(this._store);

  final SecureStore _store;
  final AudioRecorder _recorder = AudioRecorder();
  String? _activePath;
  bool _recording = false;

  /// Prefer current Flash models; fall back if a key's project lags.
  static const _models = <String>[
    'gemini-2.5-flash',
    'gemini-2.0-flash',
    'gemini-1.5-flash',
  ];

  bool get isRecording => _recording;

  Future<bool> hasApiKey() => _store.hasGcpSpeechApiKey();

  Future<bool> hasMicPermission() => _recorder.hasPermission();

  /// Start capturing mono 16 kHz WAV to a temp file.
  Future<void> start() async {
    if (_recording) return;
    final ok = await _recorder.hasPermission();
    if (!ok) {
      throw StateError('Microphone permission denied.');
    }
    final dir = await getTemporaryDirectory();
    final path = p.join(
      dir.path,
      'agentdock-stt-${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    _activePath = path;
    _recording = true;
  }

  /// Stop recording and return the transcript (may be empty).
  Future<String> stopAndTranscribe() async {
    if (!_recording) return '';
    _recording = false;
    final path = await _recorder.stop() ?? _activePath;
    _activePath = null;
    if (path == null || path.isEmpty) {
      throw StateError('No audio captured.');
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        throw StateError('Recording file missing.');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length < 44) {
        throw StateError('Recording was empty — hold longer and try again.');
      }
      return await _recognize(bytes);
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Cancel without uploading.
  Future<void> cancel() async {
    if (!_recording) return;
    _recording = false;
    final path = await _recorder.stop() ?? _activePath;
    _activePath = null;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  Future<String> _recognize(Uint8List wavBytes) async {
    final apiKey = await _store.readGcpSpeechApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('Add a Gemini API key in Connect first.');
    }
    final language = await _store.readGcpSpeechLanguage();

    Object? lastError;
    for (final model in _models) {
      try {
        return await _recognizeWithModel(
          apiKey: apiKey,
          model: model,
          language: language,
          wavBytes: wavBytes,
        );
      } catch (e) {
        lastError = e;
        SafeLog.d('Gemini STT $model failed', e);
        // Auth / quota — no point trying other models.
        final msg = e.toString().toLowerCase();
        if (msg.contains('api key') ||
            msg.contains('permission') ||
            msg.contains('403') ||
            msg.contains('401') ||
            msg.contains('quota') ||
            msg.contains('billing')) {
          rethrow;
        }
      }
    }
    throw StateError(
      lastError == null
          ? 'Speech-to-text failed.'
          : _friendlyError(lastError),
    );
  }

  Future<String> _recognizeWithModel({
    required String apiKey,
    required String model,
    required String language,
    required Uint8List wavBytes,
  }) async {
    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$model:generateContent',
      {'key': apiKey},
    );

    final prompt =
        'Transcribe the spoken audio to plain text. '
        'Language hint: $language. '
        'Return only the transcript — no quotes, labels, or commentary. '
        'If there is no intelligible speech, return an empty string.';

    // REST uses proto-JSON snake_case for Blob fields.
    final body = jsonEncode({
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'audio/wav',
                'data': base64Encode(wavBytes),
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0,
        'maxOutputTokens': 2048,
      },
    });

    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: body,
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      SafeLog.d('Gemini STT HTTP ${response.statusCode}: ${response.body}');
      throw StateError(_httpDetail(response.statusCode, response.body));
    }

    return _extractText(response.body).trim();
  }

  static String _httpDetail(int status, String body) {
    String detail = body;
    try {
      final err = jsonDecode(body);
      if (err is Map && err['error'] is Map) {
        detail = (err['error'] as Map)['message']?.toString() ?? detail;
      }
    } catch (_) {}
    if (status == 400 && detail.toLowerCase().contains('api key')) {
      return 'Invalid Gemini API key — paste a key from aistudio.google.com in Connect.';
    }
    if (status == 403 || status == 401) {
      return 'Gemini rejected the API key (HTTP $status). Check Connect → Gemini key.';
    }
    if (status == 404) {
      return 'Gemini model not available for this key (HTTP 404).';
    }
    if (detail.length > 240) detail = '${detail.substring(0, 240)}…';
    return 'Speech-to-text failed (HTTP $status): $detail';
  }

  static String _friendlyError(Object error) {
    final raw = error.toString();
    const prefix = 'Bad state: ';
    if (raw.startsWith(prefix)) return raw.substring(prefix.length);
    return raw;
  }

  /// Strip Dart's `Bad state:` prefix for snackbars.
  static String userFacingMessage(Object error) => _friendlyError(error);

  static String _extractText(String responseBody) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map) return '';
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      // Often blocked / empty audio — treat as no speech rather than a hard fail.
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
      if (part is Map && part['text'] is String) {
        buf.write(part['text']);
      }
    }
    return buf.toString();
  }

  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}
