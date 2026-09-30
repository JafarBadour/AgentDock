import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_dock/app/app_theme.dart';
import 'package:agent_dock/features/archon/archon_voice_bar.dart';
import 'package:agent_dock/services/archon_voice.dart';
import 'package:agent_dock/services/deepgram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Same seam the service tests use: no microphone, no speaker, no device.
class _FakeRecorder implements VoiceRecorder {
  _FakeRecorder({this.permitted = true, this.captured});
  bool permitted;
  Uint8List? captured;
  bool started = false;
  bool cancelled = false;

  @override
  Future<bool> hasPermission() async => permitted;
  @override
  Future<void> start(String p) async => started = true;
  @override
  Future<Uint8List?> stop() async => captured;
  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Future<void> dispose() async {}
}

class _FakePlayer implements VoicePlayer {
  bool stopped = false;

  /// Held open so a test can look at the bar mid-playback; a player that
  /// returns at once is never observably speaking.
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> play(Uint8List audio, {required String mimeType}) => gate.future;
  @override
  Future<void> stop() async {
    stopped = true;
    if (!gate.isCompleted) gate.complete();
  }

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

  ({
    ArchonVoice voice,
    _FakeRecorder rec,
    _FakePlayer play,
    List<String> calls,
  })
  buildVoice({
    Uint8List? captured,
    bool permitted = true,
    String transcript = 'ship it',
    int status = 200,
  }) {
    final recorder = _FakeRecorder(
      permitted: permitted,
      // A default take, so every test does not have to invent audio bytes;
      // an explicit empty one means the user held the mic and said nothing.
      captured: captured ?? Uint8List.fromList([1, 2]),
    );
    final player = _FakePlayer();
    final calls = <String>[];
    final deepgram = DeepgramService(
      settings: () async => const DeepgramSettings(apiKey: 'k'),
      client: MockClient((req) async {
        calls.add(req.url.path);
        if (status != 200) return http.Response('nope', status);
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

  Future<void> pumpBar(
    WidgetTester tester, {
    required ArchonVoice voice,
    required void Function(String) onTranscribed,
    void Function(String)? onError,
    void Function(ArchonVoiceMode)? onModeChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          backgroundColor: AppColors.deep,
          body: Column(
            children: [
              const Spacer(),
              ArchonVoiceBar(
                voice: voice,
                animate: false,
                onTranscribed: onTranscribed,
                onError: onError,
                onModeChanged: onModeChanged,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<TestGesture> holdMic(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ArchonVoiceBar.micKey)),
    );
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets('holding the mic starts recording', (tester) async {
    final h = buildVoice();
    await pumpBar(tester, voice: h.voice, onTranscribed: (_) {});

    await holdMic(tester);

    expect(h.rec.started, isTrue);
    expect(h.voice.state, ArchonVoiceState.recording);
    expect(find.textContaining('Recording'), findsOneWidget);
  });

  testWidgets('releasing transcribes and reports the text', (tester) async {
    final h = buildVoice(transcript: 'open the pull request');
    final sent = <String>[];
    await pumpBar(tester, voice: h.voice, onTranscribed: sent.add);

    final gesture = await holdMic(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(sent, ['open the pull request']);
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  testWidgets('sliding away discards the take without sending it', (
    tester,
  ) async {
    final h = buildVoice();
    final sent = <String>[];
    await pumpBar(tester, voice: h.voice, onTranscribed: sent.add);

    final gesture = await holdMic(tester);
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('Release to discard'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(sent, isEmpty, reason: 'a cancelled take is never reported');
    expect(h.rec.cancelled, isTrue);
    expect(h.calls, isEmpty, reason: 'nothing may reach Deepgram');
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  testWidgets('a failed transcription is shown and the mic returns to idle', (
    tester,
  ) async {
    final h = buildVoice(status: 500);
    final sent = <String>[];
    final errors = <String>[];
    await pumpBar(
      tester,
      voice: h.voice,
      onTranscribed: sent.add,
      onError: errors.add,
    );

    final gesture = await holdMic(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(find.textContaining('Transcription failed'), findsOneWidget);
    expect(errors.single, contains('Transcription failed'));
    // A bar stuck on "Transcribing…" would cost the user the whole session.
    expect(h.voice.state, ArchonVoiceState.idle);
    expect(find.textContaining('Transcribing'), findsNothing);

    // The mic still works afterwards.
    final again = await holdMic(tester);
    expect(h.voice.state, ArchonVoiceState.recording);
    await again.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a refused microphone says what to allow', (tester) async {
    final h = buildVoice(permitted: false);
    await pumpBar(tester, voice: h.voice, onTranscribed: (_) {});

    final gesture = await holdMic(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('Microphone'), findsOneWidget);
    expect(h.voice.state, ArchonVoiceState.idle);
  });

  testWidgets('releasing without speaking reports nothing', (tester) async {
    final h = buildVoice(captured: Uint8List(0));
    final sent = <String>[];
    await pumpBar(tester, voice: h.voice, onTranscribed: sent.add);

    final gesture = await holdMic(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(h.calls, isEmpty, reason: 'silence is not worth a request');
    expect(find.textContaining('Nothing heard'), findsOneWidget);
  });

  testWidgets('picking an audio-chat mode reports it', (tester) async {
    final h = buildVoice();
    final modes = <ArchonVoiceMode>[];
    await pumpBar(
      tester,
      voice: h.voice,
      onTranscribed: (_) {},
      onModeChanged: modes.add,
    );

    await tester.tap(find.byTooltip(ArchonVoiceMode.voiceOnly.label));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(ArchonVoiceMode.talkAndText.label));
    await tester.pumpAndSettle();

    expect(modes, [ArchonVoiceMode.voiceOnly, ArchonVoiceMode.talkAndText]);
    expect(find.text(ArchonVoiceMode.talkAndText.hint), findsOneWidget);
  });

  testWidgets('a spoken reply can be cut short', (tester) async {
    final h = buildVoice();
    await pumpBar(tester, voice: h.voice, onTranscribed: (_) {});

    // The caller starts playback; the bar learns about it from the stream.
    final speaking = h.voice.speak('Pull request opened.');
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Archon is speaking'), findsOneWidget);

    await tester.tap(find.byTooltip('Stop speaking'));
    await tester.pumpAndSettle();
    expect(h.play.stopped, isTrue);
    await speaking;
    await tester.pumpAndSettle();
  });

  testWidgets('the pulsing mic renders and is torn down on release', (
    tester,
  ) async {
    // The animated path ships to users, so it is built at least once here —
    // with bare pumps, since pumpAndSettle never returns under a live ticker.
    final h = buildVoice();
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ArchonVoiceBar(voice: h.voice, onTranscribed: sent.add),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ArchonVoiceBar.micKey)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Recording'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump();
    // A surviving controller would fail the test with "a Ticker was active".
    expect(sent, ['ship it']);
  });

  testWidgets('the bar settles when the pulse is off', (tester) async {
    final h = buildVoice();
    await pumpBar(tester, voice: h.voice, onTranscribed: (_) {});
    await holdMic(tester);
    // Would time out if the recording ring kept a repeating ticker alive.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
