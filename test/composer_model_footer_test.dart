import 'dart:io';

import 'package:agent_dock/app/app_theme.dart';
import 'package:agent_dock/features/agents/composer_model_footer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {double width = 360}) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(
    backgroundColor: AppColors.deep,
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  setUpAll(() async {
    // The test font draws every glyph a full em wide, so widths only mean
    // something with a real system font.
    final font = [
      '/System/Library/Fonts/SFNS.ttf',
      r'C:\Windows\Fonts\segoeui.ttf',
      '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    ].map(File.new).where((f) => f.existsSync()).firstOrNull;
    if (font != null) {
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(font.readAsBytesSync().buffer.asByteData()));
      await loader.load();
    }
  });

  testWidgets('a long model name shortens instead of overflowing', (
    tester,
  ) async {
    // The name that broke the old two-line box into "Default (rec/ommended)".
    await tester.pumpWidget(
      _host(
        const ComposerModelFooter(
          label: 'Default (recommended)',
          usage: '128k/200k (64%)',
        ),
        width: 200,
      ),
    );
    expect(tester.takeException(), isNull);

    final name = tester.widget<Text>(
      find.text('Default (recommended)'),
    );
    expect(name.maxLines, 1, reason: 'the name must never wrap mid-word');
    expect(name.overflow, TextOverflow.ellipsis);
  });

  testWidgets('the context reading survives a squeeze intact', (tester) async {
    await tester.pumpWidget(
      _host(
        const ComposerModelFooter(
          label: 'Some Extremely Long Model Name That Will Not Fit At All',
          usage: '128k/200k (64%)',
        ),
        width: 160,
      ),
    );
    expect(tester.takeException(), isNull);
    // The name gives up space; the number stays whole and readable.
    expect(find.text('128k/200k (64%)'), findsOneWidget);
  });

  testWidgets('renders on one line at phone width', (tester) async {
    await tester.pumpWidget(
      _host(
        const ComposerModelFooter(
          label: 'Default (recommended)',
          usage: '128k/200k (64%)',
        ),
        width: 300,
      ),
    );
    final box = tester.getSize(find.byType(ComposerModelFooter));
    expect(
      box.height,
      lessThan(30),
      reason: 'one line plus padding — two lines was the bug',
    );
  });

  testWidgets('usage is dropped before the agent reports one', (tester) async {
    await tester.pumpWidget(
      _host(const ComposerModelFooter(label: 'Sonnet 5')),
    );
    expect(find.text('Sonnet 5'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('an empty label takes no space', (tester) async {
    await tester.pumpWidget(_host(const ComposerModelFooter(label: '')));
    expect(tester.getSize(find.byType(ComposerModelFooter)).height, 0);
  });

  testWidgets('tapping asks for the model picker', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        ComposerModelFooter(
          label: 'Sonnet 5',
          usage: '10k/200k (5%)',
          onTap: () => taps++,
        ),
      ),
    );
    await tester.tap(find.text('Sonnet 5'));
    expect(taps, 1);
  });
}
