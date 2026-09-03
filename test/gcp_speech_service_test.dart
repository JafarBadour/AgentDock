import 'package:agent_dock/services/gcp_speech_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractGeminiTranscript', () {
    test('reads text parts', () {
      const body = '''
{"candidates":[{"content":{"parts":[{"text":"hello world"}]},"finishReason":"STOP"}]}
''';
      expect(extractGeminiTranscript(body), 'hello world');
    });

    test('skips thought parts', () {
      const body = '''
{"candidates":[{"content":{"parts":[
  {"text":"thinking…","thought":true},
  {"text":"final answer"}
]},"finishReason":"STOP"}]}
''';
      expect(extractGeminiTranscript(body), 'final answer');
    });

    test('empty candidates returns empty', () {
      expect(extractGeminiTranscript('{"candidates":[]}'), '');
    });
  });
}
