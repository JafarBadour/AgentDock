import 'dart:convert';
import 'dart:typed_data';

import 'package:agentplantation/services/deepgram_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  DeepgramService build(
    DeepgramSettings config,
    Future<http.Response> Function(http.Request) handler,
  ) => DeepgramService(
    settings: () async => config,
    client: MockClient(handler),
  );

  const key = DeepgramSettings(apiKey: 'dg-test-key');

  String transcriptBody(String text) => jsonEncode({
    'results': {
      'channels': [
        {
          'alternatives': [
            {'transcript': text},
          ],
        },
      ],
    },
  });

  group('transcribe', () {
    test('sends the audio with the key and returns the transcript', () async {
      late http.Request seen;
      final service = build(key, (req) async {
        seen = req;
        return http.Response(transcriptBody('ship the connector today'), 200);
      });

      expect(
        await service.transcribe(Uint8List.fromList([1, 2, 3])),
        'ship the connector today',
      );
      expect(seen.headers['Authorization'], 'Token dg-test-key');
      expect(seen.url.path, '/v1/listen');
      expect(
        seen.url.queryParameters['model'],
        DeepgramService.defaultSttModel,
      );
      // Punctuation and casing, so dictation reads like writing.
      expect(seen.url.queryParameters['smart_format'], 'true');
      expect(seen.bodyBytes, [1, 2, 3]);
    });

    test('omits language so Deepgram detects it, unless one is set', () async {
      late Uri detected;
      await build(key, (req) async {
        detected = req.url;
        return http.Response(transcriptBody('x'), 200);
      }).transcribe(Uint8List.fromList([1]));
      expect(detected.queryParameters.containsKey('language'), isFalse);

      late Uri pinned;
      await build(const DeepgramSettings(apiKey: 'k', language: 'nl'), (
        req,
      ) async {
        pinned = req.url;
        return http.Response(transcriptBody('x'), 200);
      }).transcribe(Uint8List.fromList([1]));
      expect(pinned.queryParameters['language'], 'nl');
    });

    test('a configured STT model overrides the default', () async {
      late Uri seen;
      await build(const DeepgramSettings(apiKey: 'k', sttModel: 'nova-2'), (
        req,
      ) async {
        seen = req.url;
        return http.Response(transcriptBody('x'), 200);
      }).transcribe(Uint8List.fromList([1]));
      expect(seen.queryParameters['model'], 'nova-2');
    });

    test('silence is an empty transcript, not a failure', () async {
      final service = build(
        key,
        (_) async => http.Response(transcriptBody(''), 200),
      );
      expect(await service.transcribe(Uint8List.fromList([1])), '');
    });

    test('empty audio never reaches the network', () async {
      var called = false;
      final service = build(key, (_) async {
        called = true;
        return http.Response('{}', 200);
      });
      expect(await service.transcribe(Uint8List(0)), '');
      expect(called, isFalse);
    });

    test('a rejected key says which key to fix', () async {
      final service = build(
        key,
        (_) async =>
            http.Response(jsonEncode({'err_msg': 'Invalid credentials'}), 401),
      );
      await expectLater(
        service.transcribe(Uint8List.fromList([1])),
        throwsA(
          isA<StateError>()
              .having(
                (e) => e.message,
                'message',
                contains('Invalid credentials'),
              )
              .having((e) => e.message, 'message', contains('Archon settings')),
        ),
      );
    });

    test('a rate limit is named, not shown as a bare 429', () async {
      final service = build(key, (_) async => http.Response('', 429));
      await expectLater(
        service.transcribe(Uint8List.fromList([1])),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('rate limit'),
          ),
        ),
      );
    });

    test('a missing key is explained before any request', () async {
      var called = false;
      final service = build(const DeepgramSettings(), (_) async {
        called = true;
        return http.Response('{}', 200);
      });
      await expectLater(
        service.transcribe(Uint8List.fromList([1])),
        throwsA(isA<StateError>()),
      );
      expect(called, isFalse, reason: 'no key means no request');
    });
  });

  group('speak', () {
    test('posts the text and returns the audio', () async {
      late http.Request seen;
      final service = build(key, (req) async {
        seen = req;
        return http.Response.bytes([9, 8, 7], 200);
      });

      expect(await service.speak('  Done. Check it out.  '), [9, 8, 7]);
      expect(seen.url.path, '/v1/speak');
      expect(
        seen.url.queryParameters['model'],
        DeepgramService.defaultTtsModel,
      );
      expect(jsonDecode(seen.body)['text'], 'Done. Check it out.');
    });

    test('a configured voice overrides the default', () async {
      late Uri seen;
      await build(
        const DeepgramSettings(apiKey: 'k', ttsModel: 'aura-2-orion-en'),
        (req) async {
          seen = req.url;
          return http.Response.bytes([1], 200);
        },
      ).speak('hi');
      expect(seen.queryParameters['model'], 'aura-2-orion-en');
    });

    test('nothing to say means no request and no audio', () async {
      var called = false;
      final service = build(key, (_) async {
        called = true;
        return http.Response.bytes([1], 200);
      });
      expect(await service.speak('   '), isEmpty);
      expect(called, isFalse);
    });
  });

  group('parseTranscript', () {
    test('survives every shape Deepgram omits on silence', () {
      for (final body in [
        '{}',
        '{"results":{}}',
        '{"results":{"channels":[]}}',
        '{"results":{"channels":[{}]}}',
        '{"results":{"channels":[{"alternatives":[]}]}}',
        '[]',
        'not json at all',
        '',
      ]) {
        expect(DeepgramService.parseTranscript(body), '', reason: 'body: $body');
      }
    });
  });

  group('settings', () {
    test('a blank key does not count as configured', () async {
      expect(
        await build(
          const DeepgramSettings(apiKey: '   '),
          (_) async => http.Response('{}', 200),
        ).hasApiKey(),
        isFalse,
      );
    });

    test('settings are resolved per call, so a new key takes effect', () async {
      var key = '';
      final service = DeepgramService(
        settings: () async => DeepgramSettings(apiKey: key),
        client: MockClient((_) async => http.Response(transcriptBody('x'), 200)),
      );
      expect(await service.hasApiKey(), isFalse);
      key = 'added-later';
      expect(await service.hasApiKey(), isTrue);
    });
  });
}
