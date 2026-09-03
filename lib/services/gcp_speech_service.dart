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

  /// Flash is multimodal, cheap, and accepts inline WAV under the request limit.
  static const _model = 'gemini-2.0-flash';

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
        bitRate: 256000,
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
      if (bytes.isEmpty) {
        throw StateError('Recording was empty.');
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

    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$_model:generateContent',
      {'key': apiKey},
    );

    final prompt =
        'Transcribe the spoken audio to plain text. '
        'Language hint: $language. '
        'Return only the transcript — no quotes, labels, or commentary. '
        'If there is no intelligible speech, return an empty string.';

    final body = jsonEncode({
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
            {
              'inlineData': {
                'mimeType': 'audio/wav',
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
      String detail = response.body;
      try {
        final err = jsonDecode(response.body);
        if (err is Map && err['error'] is Map) {
          detail = (err['error'] as Map)['message']?.toString() ?? detail;
        }
      } catch (_) {}
      throw StateError('Speech-to-text failed: $detail');
    }

    return _extractText(response.body).trim();
  }

  static String _extractText(String responseBody) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map) return '';
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) return '';
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
