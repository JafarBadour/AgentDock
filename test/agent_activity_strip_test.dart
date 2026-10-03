import 'package:agentplantation/app/app_theme.dart';
import 'package:agentplantation/features/agents/agent_activity_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(
    backgroundColor: AppColors.deep,
    body: Column(children: [const Spacer(), child]),
  ),
);

Material _strip(WidgetTester tester) => tester.widget<Material>(
  find.descendant(
    of: find.byType(AgentActivityStrip),
    matching: find.byType(Material),
  ),
);

void main() {
  testWidgets('working is not an error — the strip avoids the error palette', (
    tester,
  ) async {
    // The bug: a healthy agent announced its work in alarm red, because the
    // strip was filled with colorScheme.errorContainer.
    await tester.pumpWidget(
      _host(
        const AgentActivityStrip(
          animate: false,
          label: Text('Ran a command…'),
        ),
      ),
    );
    final scheme = buildAppTheme().colorScheme;
    final fill = _strip(tester).color!;
    expect(fill, isNot(scheme.error));
    expect(fill, isNot(scheme.errorContainer));
    // It wears the agent accent instead: more red would mean it drifted back.
    expect(fill.b, greaterThan(fill.r));
  });

  testWidgets('the fill is opaque, so scrolling text cannot bleed through', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const AgentActivityStrip(animate: false, label: Text('Thinking…'))),
    );
    expect(_strip(tester).color!.a, 1.0);
  });

  testWidgets('keeps a fixed height whatever the label', (tester) async {
    await tester.pumpWidget(
      _host(
        const AgentActivityStrip(
          animate: false,
          label: Text('A very long activity label that would happily wrap'),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(AgentActivityStrip)).height,
      AgentActivityStrip.height,
    );
  });

  testWidgets('shows the label it is given', (tester) async {
    await tester.pumpWidget(
      _host(
        const AgentActivityStrip(
          animate: false,
          label: Text('Exploring 8 files…'),
        ),
      ),
    );
    expect(find.text('Exploring 8 files…'), findsOneWidget);
  });

  testWidgets('settles when the dots are off', (tester) async {
    await tester.pumpWidget(
      _host(const AgentActivityStrip(animate: false, label: Text('Thinking…'))),
    );
    // Would time out if a repeating ticker were still running.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
