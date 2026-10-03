import 'package:agentplantation/features/agents/chat_markdown.dart';
import 'package:agentplantation/features/agents/rich_copy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _src = '''# Plan

Some **bold** and *italic* text with a [link](https://example.com).

- first item
- second `code` item

| Name | Value |
|------|-------|
| a    | 1     |
| b    | 2     |

```dart
final x = 1 < 2;
```
''';

void main() {
  test('whole message keeps structure', () {
    const selected =
        'Plan\nSome bold and italic text with a link.\nfirst item\n'
        'second code item\nName\tValue\na\t1\nb\t2\nfinal x = 1 < 2;';
    final html = selectionToHtml(_src, selected)!;
    expect(html, contains('<h1>Plan</h1>'));
    expect(html, contains('<strong>bold</strong>'));
    expect(html, contains('<em>italic</em>'));
    expect(html, contains('<a href="https://example.com">link</a>'));
    expect(html, contains('<li>first item</li>'));
    expect(html, contains('<code>code</code>'));
    expect(html, contains('<table style='));
    expect(html, contains('1 &lt; 2'));
  });

  test('partial selection is cut to the selected text', () {
    final html = selectionToHtml(_src, 'old and italic')!;
    expect(html, '<p><strong>old</strong> and <em>italic</em></p>');
  });

  test('selection across list items keeps the list', () {
    final html = selectionToHtml(_src, 'item\nsecond code')!;
    expect(html, contains('<ul>'));
    expect(html, contains('<li>item</li>'));
    expect(html, contains('<li>second <code>code</code></li>'));
  });

  test('table row selection keeps every cell of the row', () {
    final html = selectionToHtml(_src, 'b\t2')!;
    expect(
      html,
      contains('<td style="border:1px solid #c8c8c8;padding:6px 10px;">b</td>'),
    );
    expect(html, contains('>2</td>'));
    expect(html, isNot(contains('>a</td>')));
  });

  test('unknown text gives null', () {
    expect(selectionToHtml(_src, 'nothing like this at all'), isNull);
  });

  testWidgets('Cmd/Ctrl+C in a message copies through the rich path', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RichCopySelectionArea(
            source: _src,
            child: ChatMarkdown(text: _src),
          ),
        ),
      ),
    );
    await tester.tapAt(tester.getCenter(find.textContaining('Some')));
    await tester.pump();
    final primary = defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.meta
        : LogicalKeyboardKey.control;
    await tester.sendKeyDownEvent(primary);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(primary);
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    expect(copied.single, contains('first item'));
    // List markers are not part of the selection.
    expect(copied.single, isNot(contains('•')));
  });
}
