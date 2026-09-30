import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_dock/services/archon_voice.dart';
import 'package:agent_dock/services/deepgram_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeRecorder implements VoiceRecorder {
  _FakeRecorder({this.permitted = true, this.captured});
  bool permitted;
  Uint8List? captured;
  bool started = false;
  bool cancelled = false;
  String? path;

  @override
  Future<bool> hasPermission() async => permitted;
  @override
  Future<void> start(String p) async {
    started = true;
    path = p;
  }

  @override
  Future<Uint8List?> stop() async => captured;
  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Future<void> dispose() async {}
}

class _FakePlayer implements VoicePlayer {
  Uint8List? played;
  bool stopped = false;
  @override
  Future<void> play(Uint8List audio, {required String mimeType}) async =>
      played = audio;
  @override
  Future<void> stop() async => stopped = true;
  @override
  Future<void> dispose() async {}
}

void main() {
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

  ({ArchonVoice voice, _FakeRecorder rec, _FakePlayer play, List<String> calls})
  build({
    Uint8List? captured,
    bool permitted = true,
    String transcript = 'ship it',
  }) {
    final recorder = _FakeRecorder(permitted: permitted, captured: captured);
    final player = _FakePlayer();
    final calls = <String>[];
    final deepgram = DeepgramService(
      settings: () async => const DeepgramSettings(apiKey: 'k'),
      client: MockClient((req) async {
        calls.add(req.url.path);
        if (req.url.path == '/v1/speak') {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response(transcriptBody(transcript), 200);
      }),
    );
    return (
      voice: ArchonVoice(
        deepgram: deepgram,
        recorder: recorder,
        player: player,
        tempDir: () async => '/tmp',
      ),
      rec: recorder,
      play: player,
      calls: calls,
    );
  }

  test('a spoken message becomes text', () async {
    final h = build(captured: Uint8List.fromList([1, 2]));
    await h.voice.startRecording();
    expect(h.rec.started, isTrue);
    expect(h.voice.state, ArchonVoiceState.recording);

    expect(await h.voice.stopAndTranscribe(), 'ship it');
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  test('a cancelled recording never leaves the device', () async {
    final h = build(captured: Uint8List.fromList([1, 2]));
    await h.voice.startRecording();
    await h.voice.cancelRecording();

    expect(h.rec.cancelled, isTrue);
    expect(h.calls, isEmpty, reason: 'nothing may be sent to Deepgram');
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  test('releasing the mic without speaking is not an error', () async {
    final h = build(captured: Uint8List(0));
    await h.voice.startRecording();
    expect(await h.voice.stopAndTranscribe(), '');
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  test('a refused microphone says what to allow', () async {
    final h = build(permitted: false);
    await expectLater(
      h.voice.startRecording(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Microphone'),
        ),
      ),
    );
    expect(h.rec.started, isFalse);
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  test('a second start while recording is ignored', () async {
    final h = build(captured: Uint8List.fromList([1]));
    await h.voice.startRecording();
    final firstPath = h.rec.path;
    await h.voice.startRecording();
    expect(h.rec.path, firstPath, reason: 'the take in progress is kept');
  });

  test('stopping when not recording transcribes nothing', () async {
    final h = build(captured: Uint8List.fromList([1]));
    expect(await h.voice.stopAndTranscribe(), '');
    expect(h.calls, isEmpty);
  });

  test('a reply is spoken through the player', () async {
    final h = build();
    await h.voice.speak('Done. Check it out.');
    expect(h.play.played, [1, 2, 3]);
    expect(h.calls, contains('/v1/speak'));
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  test('nothing to say means no request and no sound', () async {
    final h = build();
    await h.voice.speak('   ');
    expect(h.calls, isEmpty);
    expect(h.play.played, isNull);
  });

  test('state returns to idle even when transcription fails', () async {
    final recorder = _FakeRecorder(captured: Uint8List.fromList([1]));
    final voice = ArchonVoice(
      deepgram: DeepgramService(
        settings: () async => const DeepgramSettings(apiKey: 'k'),
        client: MockClient((_) async => http.Response('nope', 500)),
      ),
      recorder: recorder,
      player: _FakePlayer(),
      tempDir: () async => '/tmp',
    );
    await voice.startRecording();
    await expectLater(voice.stopAndTranscribe(), throwsA(isA<StateError>()));
    // A stuck "transcribing…" would leave the mic unusable for the session.
    expect(voice.state, ArchonVoiceState.idle);
  });

  test('state changes are observable', () async {
    final h = build(captured: Uint8List.fromList([1]));
    final seen = <ArchonVoiceState>[];
    final sub = h.voice.states.listen(seen.add);
    await h.voice.startRecording();
    await h.voice.stopAndTranscribe();
    // Broadcast delivery is async; let the last event land before unsubscribing.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen.first, ArchonVoiceState.recording);
    expect(seen.last, ArchonVoiceState.idle);
    expect(seen, contains(ArchonVoiceState.transcribing));
  });
}
