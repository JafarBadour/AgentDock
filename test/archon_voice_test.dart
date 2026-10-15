import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agentplantation/services/archon_voice.dart';
import 'package:agentplantation/services/deepgram_service.dart';
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
  String? deviceId;
  List<VoiceInputDevice> devices = const [];

  @override
  Future<bool> hasPermission() async => permitted;
  @override
  Future<List<VoiceInputDevice>> inputDevices() async => devices;
  @override
  Future<void> start(String p, {String? deviceId}) async {
    started = true;
    path = p;
    this.deviceId = deviceId;
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
  final plays = <Uint8List>[];
  bool stopped = false;

  /// When set, playback holds until it completes, the way real audio lasts.
  Completer<void>? gate;

  @override
  Future<void> play(Uint8List audio, {required String mimeType}) async {
    played = audio;
    plays.add(audio);
    await gate?.future;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (gate != null && !gate!.isCompleted) gate!.complete();
  }

  @override
  Future<void> dispose() async {}
}

/// A 16 kHz mono WAV, [seconds] long, every sample at [level].
Uint8List _wav(double seconds, int level) {
  final samples = (seconds * 16000).round();
  final b = ByteData(44 + samples * 2);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + samples * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    b.setInt16(44 + i * 2, i.isEven ? level : -level, Endian.little);
  }
  return b.buffer.asUint8List();
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

  ({
    ArchonVoice voice,
    _FakeRecorder rec,
    _FakePlayer play,
    List<String> calls,
    List<String> spoken,
  })
  build({
    Uint8List? captured,
    bool permitted = true,
    String transcript = 'ship it',
    String? mic,
  }) {
    final recorder = _FakeRecorder(permitted: permitted, captured: captured);
    final player = _FakePlayer();
    final calls = <String>[];
    final spoken = <String>[];
    final deepgram = DeepgramService(
      settings: () async => const DeepgramSettings(apiKey: 'k'),
      client: MockClient((req) async {
        calls.add(req.url.path);
        if (req.url.path == '/v1/speak') {
          spoken.add((jsonDecode(req.body) as Map)['text'] as String);
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
        inputDeviceId: () async => mic,
      ),
      rec: recorder,
      play: player,
      calls: calls,
      spoken: spoken,
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

  test('a silent take says the mic is silent and sends nothing', () async {
    final h = build(captured: _wav(2, 0));
    await h.voice.startRecording();
    await expectLater(
      h.voice.stopAndTranscribe(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('silence'),
        ),
      ),
    );
    expect(h.calls, isEmpty, reason: 'silence is not worth a Deepgram call');
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  test('a quiet but live take is still transcribed', () async {
    final h = build(captured: _wav(2, 300));
    await h.voice.startRecording();
    expect(await h.voice.stopAndTranscribe(), 'ship it');
  });

  test('records from the picked mic while it is plugged in', () async {
    final h = build(captured: _wav(1, 300), mic: 'usb');
    h.rec.devices = const [VoiceInputDevice(id: 'usb', label: 'USB mic')];
    await h.voice.startRecording();
    expect(h.rec.deviceId, 'usb');
  });

  test('an unplugged picked mic falls back to the default', () async {
    final h = build(captured: _wav(1, 300), mic: 'gone');
    h.rec.devices = const [VoiceInputDevice(id: 'usb', label: 'USB mic')];
    await h.voice.startRecording();
    expect(h.rec.started, isTrue);
    expect(h.rec.deviceId, isNull);
  });

  test('speaking lasts until the audio has played', () async {
    final h = build();
    h.play.gate = Completer<void>();
    final done = h.voice.speak('Hello there.');
    await pumpEventQueue();
    expect(h.voice.state, ArchonVoiceState.speaking);
    h.play.gate!.complete();
    await done;
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  test('pressing the mic while Archon speaks interrupts it', () async {
    final h = build(captured: _wav(1, 300));
    h.play.gate = Completer<void>();
    unawaited(h.voice.speak('A long answer.'));
    await pumpEventQueue();
    await h.voice.startRecording();
    expect(h.play.stopped, isTrue);
    expect(h.voice.state, ArchonVoiceState.recording);
  });

  test('a long reply is spoken in pieces Deepgram accepts', () async {
    final h = build();
    const sentence = 'This sentence is part of a very long answer. ';
    await h.voice.speak(sentence * 120);
    expect(h.spoken.length, greaterThan(1));
    for (final piece in h.spoken) {
      expect(piece.length, lessThanOrEqualTo(ArchonVoice.maxSpeechChars));
      expect(piece, endsWith('.'), reason: 'pieces break at sentence ends');
    }
    expect(h.play.plays.length, h.spoken.length);
  });

  test('stopping a long reply skips the pieces not yet played', () async {
    final h = build();
    h.play.gate = Completer<void>();
    final done = h.voice.speak('Sentence number one is here. ' * 200);
    await pumpEventQueue();
    await h.voice.stopSpeaking();
    await done;
    expect(h.play.plays.length, 1);
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  test('markdown is read as prose', () {
    final said = ArchonVoice.speakable(
      '## Status\n\n- **Build** is `green`\n- See [the PR](https://x.y/1)\n\n'
      '| a | b |\n|---|---|\n| 1 | 2 |\n\n'
      '```dart\nfinal x = 1;\n```\nDone at https://example.com/a',
    );
    expect(said, isNot(contains('#')));
    expect(said, isNot(contains('*')));
    expect(said, isNot(contains('`')));
    expect(said, isNot(contains('---')));
    expect(said, isNot(contains('final x')));
    expect(said, contains('Build is green'));
    expect(said, contains('See the PR'));
    expect(said, contains('a link'));
  });
}
