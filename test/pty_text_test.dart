import 'package:agentplantation/services/pty_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const url = 'https://claude.ai/oauth/authorize?code=true&state=xyz';

  group('stripAnsi', () {
    test('drops colour codes without splitting the text', () {
      expect(stripAnsi('\x1b[31mhello\x1b[0m world'), 'hello world');
    });

    test('an OSC 8 hyperlink does not glue its target to its label', () {
      // The CLI prints the link once; the terminal sees the target in the
      // escape and the label in the body.
      final out = stripAnsi('Open \x1b]8;;$url\x07$url\x1b]8;;\x07 to sign in');
      expect(out.contains('$url$url'), isFalse);
      expect(out.contains(url), isTrue);
    });

    test('a redrawn frame does not glue the old line to the new one', () {
      final out = stripAnsi('$url\x1b[2K\x1b[1A$url');
      expect(out.contains('$url$url'), isFalse);
    });

    test('a stray control byte separates rather than joins', () {
      expect(stripAnsi('$url\x07$url').contains('$url$url'), isFalse);
    });
  });

  group('dedupeGluedUrl', () {
    test('collapses an exact repeat', () {
      expect(dedupeGluedUrl('$url$url'), url);
    });

    test('keeps the full copy when the first render was cut short', () {
      expect(dedupeGluedUrl('https://claude.ai/oauth$url'), url);
      expect(dedupeGluedUrl('${url}https://claude.ai/oauth'), url);
    });

    test('leaves a single URL alone', () {
      expect(dedupeGluedUrl(url), url);
    });

    test('leaves an unencoded URL inside a query string alone', () {
      const nested =
          'https://claude.ai/oauth/authorize?redirect_uri=https://console.anthropic.com/cb';
      expect(dedupeGluedUrl(nested), nested);
    });
  });
}
