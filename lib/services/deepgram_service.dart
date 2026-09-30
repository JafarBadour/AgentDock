import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';

/// What a Deepgram call needs, resolved once per request.
///
/// Held apart from [SecureStore] so the service is a pure HTTP client: on
/// desktop the store reads files through `path_provider`, which no unit test
/// can reach.
class DeepgramSettings {
  const DeepgramSettings({
    this.apiKey,
    this.sttModel,
    this.ttsModel,
    this.language,
  });

  final String? apiKey;
  final String? sttModel;
  final String? ttsModel;

  /// BCP-47 tag, or null to let Deepgram detect the language.
  final String? language;

  bool get hasKey => (apiKey ?? '').trim().isNotEmpty;

  static Future<DeepgramSettings> fromStore(SecureStore store) async =>
      DeepgramSettings(
        apiKey: await store.readDeepgramApiKey(),
        sttModel: await store.readDeepgramSttModel(),
        ttsModel: await store.readDeepgramTtsModel(),
        language: await store.readDeepgramLanguage(),
      );
}

/// Deepgram speech for Archon: transcription in, spoken replies out.
///
/// Deepgram handles speech only. The reply itself comes from an agent session
/// on the host, the same kind a regular chat uses — nothing here talks to a
/// model.
///
/// Returns audio as bytes rather than playing it, so playback stays the
/// caller's decision and this whole class is testable without a device.
class DeepgramService {
  DeepgramService({required this.settings, http.Client? client})
    : _client = client ?? http.Client();

  /// Resolved per request, so a key added in settings takes effect at once.
  final Future<DeepgramSettings> Function() settings;

  final http.Client _client;

  /// Reads its configuration from [store].
  factory DeepgramService.fromStore(SecureStore store, {http.Client? client}) =>
      DeepgramService(
        settings: () => DeepgramSettings.fromStore(store),
        client: client,
      );

  static const _listenUrl = 'https://api.deepgram.com/v1/listen';
  static const _speakUrl = 'https://api.deepgram.com/v1/speak';

  /// Deepgram's current general-purpose transcription model.
  static const defaultSttModel = 'nova-3';

  /// A voice, not just a model — Deepgram names them `aura-2-<voice>-<lang>`.
  static const defaultTtsModel = 'aura-2-thalia-en';

  /// Deepgram is slow to fail on a bad network; a voice turn that hangs is
  /// worse than one that gives up and says so.
  static const timeout = Duration(seconds: 30);

  Future<bool> hasApiKey() async => (await settings()).hasKey;

  Future<DeepgramSettings> _requireKey() async {
    final resolved = await settings();
    if (!resolved.hasKey) {
      throw StateError(
        'No Deepgram API key — add one in Archon settings to use voice.',
      );
    }
    return resolved;
  }

  /// Transcribe recorded [audio]. Empty speech returns an empty string rather
  /// than throwing: saying nothing is a normal thing to do with a mic.
  Future<String> transcribe(
    Uint8List audio, {
    String contentType = 'audio/wav',
  }) async {
    if (audio.isEmpty) return '';
    final config = await _requireKey();
    final model = _orDefault(config.sttModel, defaultSttModel);
    final language = config.language;

    final uri = Uri.parse(_listenUrl).replace(
      queryParameters: {
        'model': model,
        // Punctuation and casing, so a dictated message reads like writing.
        'smart_format': 'true',
        // Absent, Deepgram detects the language itself.
        if (language != null && language.trim().isNotEmpty)
          'language': language.trim(),
      },
    );

    final response = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Token ${config.apiKey!.trim()}',
            'Content-Type': contentType,
          },
          body: audio,
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw StateError(_errorFor('Transcription', response));
    }
    return parseTranscript(response.body);
  }

  /// Speak [text], returning the audio Deepgram produced.
  Future<Uint8List> speak(String text, {String encoding = 'linear16'}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Uint8List(0);
    final config = await _requireKey();
    final model = _orDefault(config.ttsModel, defaultTtsModel);

    final uri = Uri.parse(_speakUrl).replace(
      queryParameters: {
        'model': model,
        'encoding': encoding,
        if (encoding == 'linear16') 'sample_rate': '24000',
      },
    );

    final response = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Token ${config.apiKey!.trim()}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'text': trimmed}),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw StateError(_errorFor('Speech', response));
    }
    return response.bodyBytes;
  }

  static String _orDefault(String? value, String fallback) =>
      (value == null || value.trim().isEmpty) ? fallback : value.trim();

  /// The transcript out of a Deepgram `listen` response.
  ///
  /// Deepgram nests it under channels and alternatives, and omits the whole
  /// branch for silence, so every level is treated as optional.
  static String parseTranscript(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return '';
      final channels = (decoded['results'] as Map?)?['channels'];
      if (channels is! List || channels.isEmpty) return '';
      final alternatives = (channels.first as Map?)?['alternatives'];
      if (alternatives is! List || alternatives.isEmpty) return '';
      final transcript = (alternatives.first as Map?)?['transcript'];
      return transcript is String ? transcript.trim() : '';
    } catch (e) {
      SafeLog.d('deepgram transcript parse failed', e);
      return '';
    }
  }

  /// Deepgram's own message when it sends one — "project does not have access
  /// to model X" is worth surfacing; "400" alone is not.
  static String _errorFor(String what, http.Response response) {
    final detail = _messageFrom(response.body);
    final code = response.statusCode;
    final hint = switch (code) {
      401 || 403 => ' — check the Deepgram API key in Archon settings',
      429 => ' — Deepgram rate limit reached',
      _ => '',
    };
    return detail.isEmpty
        ? '$what failed (HTTP $code)$hint'
        : '$what failed (HTTP $code): $detail$hint';
  }

  static String _messageFrom(String body) {
    if (body.isEmpty) return '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in const ['err_msg', 'message', 'error', 'reason']) {
          final value = decoded[key];
          if (value is String && value.trim().isNotEmpty) return value.trim();
        }
      }
    } catch (_) {
      // Not JSON — a short body is still better than nothing.
    }
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 200 ? flat : '${flat.substring(0, 200)}…';
  }

  void dispose() => _client.close();
}
