import 'package:agentplantation/app/app_theme.dart';
import 'package:agentplantation/features/agents/agent_activity_strip.dart';
import 'package:agentplantation/features/agents/transcript_snapshot.dart';
import 'package:agentplantation/features/agents/transcript_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Both the jump-to-latest button and the activity strip live on the
/// transcript's bottom edge. They used to be pinned there independently, so
/// the button landed inside the strip's band and the strip painted over it.
Future<TranscriptController> _pump(
  WidgetTester tester, {
  required bool following,
  Widget? overlay,
  double overlayHeight = 0,
}) async {
  final ctl = TranscriptController();
  addTearDown(ctl.dispose);
  final snap = ValueNotifier(
    TranscriptSnapshot(blocks: const [], liveAssistant: ''),
  );
  addTearDown(snap.dispose);
  ctl.following.value = following;

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.deep,
        body: TranscriptView(
          snapshot: snap,
          controller: ctl,
          overlayHeight: overlayHeight,
          overlay: overlay,
        ),
      ),
    ),
  );
  await tester.pump();
  return ctl;
}

/// The jump-to-latest pill: a Material wrapping the chevron.
Finder _jumpButton() => find
    .ancestor(
      of: find.byIcon(Icons.keyboard_arrow_down_rounded),
      matching: find.byType(Material),
    )
    .first;

void main() {
  testWidgets('the jump button clears the activity strip', (tester) async {
    await _pump(
      tester,
      following: false,
      overlayHeight: AgentActivityStrip.height,
      overlay: const AgentActivityStrip(
        animate: false,
        label: Text('Ran a command…'),
      ),
    );

    final strip = tester.getRect(find.byType(AgentActivityStrip));
    final button = tester.getRect(_jumpButton());
    expect(
      button.bottom,
      lessThanOrEqualTo(strip.top),
      reason: 'the strip would paint over the button',
    );
  });

  testWidgets('the jump button drops to the bottom with no strip', (
    tester,
  ) async {
    await _pump(tester, following: false);
    final view = tester.getRect(find.byType(TranscriptView));
    final button = tester.getRect(_jumpButton());
    // Still near the bottom edge — no strip means no gap to leave for one.
    expect(view.bottom - button.bottom, lessThan(24));
  });

  testWidgets('list padding reserves the strip height', (tester) async {
    await _pump(
      tester,
      following: true,
      overlayHeight: AgentActivityStrip.height,
      overlay: const AgentActivityStrip(
        animate: false,
        label: Text('Thinking…'),
      ),
    );
    // Reserved whatever the strip is doing, so toggling it cannot jump the
    // scroll — and the newest line is never hidden under an opaque bar.
    final padded = tester.widgetList<SliverPadding>(find.byType(SliverPadding));
    expect(
      padded.any((s) => s.padding.resolve(TextDirection.ltr).bottom >=
          AgentActivityStrip.height),
      isTrue,
    );
  });
}
