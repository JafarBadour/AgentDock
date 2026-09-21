import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:agent_dock/features/agents/tool_call_card.dart';
import 'package:agent_dock/features/agents/transcript_blocks.dart';
import 'package:agent_dock/features/agents/transcript_snapshot.dart';
import 'package:agent_dock/features/agents/transcript_view.dart';
import 'package:agent_dock/services/chat_session_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _msg(String id, MessageRole role, String content, {int minute = 0}) =>
    ChatMessage(
      id: id,
      chatId: 'c1',
      role: role,
      content: content,
      createdAt: DateTime(2026, 9, 7, 12, minute),
    );

TranscriptEntry _user(String id, String text, {int minute = 0}) =>
    TranscriptEntry.message(_msg(id, MessageRole.user, text, minute: minute));

TranscriptEntry _assistant(String id, String text, {int minute = 0}) =>
    TranscriptEntry.message(
      _msg(id, MessageRole.assistant, text, minute: minute),
    );

TranscriptEntry _tool(String id, {String kind = 'read', String? path}) =>
    TranscriptEntry.tool(
      ToolCallState(
        toolCallId: id,
        title: 'Read',
        kind: kind,
        status: 'completed',
        locations: [path ?? 'lib/$id.dart'],
        rawOutput: 'contents of $id',
      ),
      messageId: 'm-$id',
      createdAt: DateTime(2026, 9, 7, 12),
    );

List<ChatBlock> _blocks(List<TranscriptEntry> entries) =>
    buildTranscriptBlocks(entries);

/// Enough turns to make the list scrollable in the test viewport.
List<TranscriptEntry> _longHistory(int turns) => [
      for (var i = 0; i < turns; i++) ...[
        _user('u$i', 'Question $i', minute: i),
        _assistant('a$i', 'Answer $i\n\n' * 6, minute: i),
      ],
    ];

Widget _host(
  ValueNotifier<TranscriptSnapshot> snapshot,
  TranscriptController controller, {
  Future<void> Function()? onLoadOlder,
}) =>
    MaterialApp(
      home: Scaffold(
        body: TranscriptView(
          snapshot: snapshot,
          controller: controller,
          onLoadOlder: onLoadOlder,
        ),
      ),
    );

void main() {
  testWidgets('newest row sits at the bottom; oldest at the top',
      (tester) async {
    final snapshot = ValueNotifier(
      TranscriptSnapshot(
        blocks: _blocks([
          _user('u1', 'first question'),
          _assistant('a1', 'first answer'),
          _user('u2', 'second question'),
        ]),
      ),
    );
    final ctl = TranscriptController();
    await tester.pumpWidget(_host(snapshot, ctl));
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(find.text('first question'));
    final last = tester.getTopLeft(find.text('second question'));
    expect(first.dy, lessThan(last.dy));
    expect(ctl.following.value, isTrue);
    ctl.dispose();
  });

  testWidgets('live assistant text renders as markdown while streaming',
      (tester) async {
    final snapshot = ValueNotifier(
      TranscriptSnapshot(
        blocks: _blocks([_user('u1', 'hi')]),
        liveAssistant: '## Plan\n\nFirst **bold** point\n\n- item one\n- item',
        liveAssistantId: 'a-live',
        streaming: true,
      ),
    );
    final ctl = TranscriptController();
    await tester.pumpWidget(_host(snapshot, ctl));
    await tester.pumpAndSettle();

    // Heading and emphasis were parsed: no literal markdown syntax on screen.
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('Plan'), findsWidgets);

    // Extending the text keeps rendering (settled prefix + tail).
    snapshot.value = snapshot.value.copyWith(
      liveAssistant: '${snapshot.value.liveAssistant} two\n\nDone.',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Done.'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    ctl.dispose();
  });

  testWidgets('scrolling up freezes the document and counts new rows',
      (tester) async {
    final snapshot = ValueNotifier(
      TranscriptSnapshot(blocks: _blocks(_longHistory(12))),
    );
    final ctl = TranscriptController();
    await tester.pumpWidget(_host(snapshot, ctl));
    await tester.pumpAndSettle();

    // Drag downward (reveals older rows in a reversed list).
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(ctl.following.value, isFalse);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

    // A new turn arrives: not painted, but counted on the badge.
    snapshot.value = snapshot.value.copyWith(
      blocks: _blocks([
        ..._longHistory(12),
        _user('u99', 'late question', minute: 40),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('late question'), findsNothing);
    expect(find.text('1 new'), findsOneWidget);

    // Jump to latest resumes following and paints the new row.
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pumpAndSettle();
    expect(ctl.following.value, isTrue);
    expect(find.text('late question'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    ctl.dispose();
  });

  testWidgets('expanded tool group survives rows inserted after it',
      (tester) async {
    final history = [
      _user('u1', 'go'),
      _tool('t1'),
      _tool('t2', kind: 'execute'),
    ];
    final snapshot = ValueNotifier(
      TranscriptSnapshot(blocks: _blocks(history)),
    );
    final ctl = TranscriptController();
    await tester.pumpWidget(_host(snapshot, ctl));
    await tester.pumpAndSettle();

    // Collapsed header describes the run.
    expect(find.textContaining('Read 1 file'), findsOneWidget);
    expect(find.textContaining('Ran 1 command'), findsOneWidget);

    await tester.tap(find.byType(ToolCallGroupCard));
    await tester.pumpAndSettle();
    expect(find.byType(ToolCallCard), findsNWidgets(2));

    // Assistant text lands after the group — the group stays expanded.
    snapshot.value = snapshot.value.copyWith(
      blocks: _blocks([...history, _assistant('a1', 'done', minute: 1)]),
    );
    await tester.pumpAndSettle();
    expect(find.text('done'), findsOneWidget);
    expect(find.byType(ToolCallCard), findsNWidgets(2));
    ctl.dispose();
  });

  testWidgets('load earlier prepends rows even while frozen', (tester) async {
    var loads = 0;
    final snapshot = ValueNotifier(
      TranscriptSnapshot(
        blocks: _blocks(_longHistory(12)),
        hasMoreOlder: true,
      ),
    );
    final ctl = TranscriptController();
    await tester.pumpWidget(
      _host(snapshot, ctl, onLoadOlder: () async => loads++),
    );
    await tester.pumpAndSettle();

    // Reversed list: dragging down reveals older rows, up to the top button.
    for (var i = 0; i < 40; i++) {
      if (find.text('Load earlier messages').evaluate().isNotEmpty) break;
      await tester.drag(find.byType(ListView), const Offset(0, 500));
      await tester.pumpAndSettle();
    }
    expect(ctl.following.value, isFalse);
    await tester.tap(find.text('Load earlier messages'));
    await tester.pumpAndSettle();
    expect(loads, 1);

    snapshot.value = snapshot.value.copyWith(
      blocks: _blocks([
        _user('u-old', 'ancient question'),
        ..._longHistory(12),
        _user('u-new', 'brand new', minute: 50),
      ]),
      hasMoreOlder: false,
    );
    await tester.pumpAndSettle();
    // Older rows merged into the frozen document; the new tail is held back.
    expect(find.text('ancient question'), findsOneWidget);
    expect(find.text('brand new'), findsNothing);
    expect(find.text('Load earlier messages'), findsNothing);
    ctl.dispose();
  });
}
