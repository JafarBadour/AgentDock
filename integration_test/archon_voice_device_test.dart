import 'package:agentplantation/data/secure/secure_store.dart';
import 'package:agentplantation/services/archon_voice.dart';
import 'package:agentplantation/services/deepgram_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Archon's voice on a real device: the real microphones, the real speaker
/// and the real Deepgram, with the key the app itself has saved.
///
///   flutter test integration_test/archon_voice_device_test.dart -d windows
///
/// Needs speakers, not headphones: Archon talks while a mic listens, and the
/// mic is expected to hear it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late DeepgramService deepgram;

  setUp(() => deepgram = DeepgramService.fromStore(SecureStore()));
  tearDown(() => deepgram.dispose());

  testWidgets('speaking lasts as long as the sound', (tester) async {
    await tester.runAsync(() async {
      expect(await deepgram.hasApiKey(), isTrue, reason: 'no Deepgram key');
      final voice = ArchonVoice(deepgram: deepgram);
      final watch = Stopwatch()..start();
      await voice.speak(
        'Hello. I am Archon, and this sentence takes a few seconds to say.',
      );
      // ignore: avoid_print
      print('VOICE spoke for ${watch.elapsedMilliseconds}ms');
      expect(watch.elapsed, greaterThan(const Duration(seconds: 2)));
      await voice.dispose();
    });
  });

  testWidgets('every mic either hears Archon or says it is silent', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final probe = ArchonVoice(deepgram: deepgram);
      final mics = [null, ...await probe.inputDevices()];
      await probe.dispose();
      var heard = 0;
      for (final mic in mics) {
        final voice = ArchonVoice(
          deepgram: deepgram,
          inputDeviceId: () async => mic?.id,
        );
        final speaker = ArchonVoice(deepgram: deepgram);
        String outcome;
        try {
          await voice.startRecording();
          await speaker.speak('Archon, list my agents please.');
          final text = await voice.stopAndTranscribe();
          outcome = 'heard "$text"';
          if (text.toLowerCase().contains('agent')) heard++;
        } on StateError catch (e) {
          outcome = 'error: ${e.message}';
        }
        // ignore: avoid_print
        print('VOICE ${mic?.label ?? '<default>'}: $outcome');
        await speaker.dispose();
        await voice.dispose();
      }
      expect(heard, greaterThan(0), reason: 'no mic heard Archon speak');
    });
  });
}
