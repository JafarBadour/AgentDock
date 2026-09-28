import 'dart:convert';

import 'package:agent_dock/app/app_theme.dart';
import 'package:agent_dock/data/local/app_database.dart';
import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:agent_dock/features/agents/transcript_blocks.dart';
import 'package:agent_dock/features/agents/transcript_snapshot.dart';
import 'package:agent_dock/features/agents/transcript_view.dart';
import 'package:agent_dock/services/chat_session_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Scroll benchmark for the chat transcript on real data.
///
///   flutter drive --profile -d macos \
///     --driver=test_driver/perf_driver.dart \
///     --target=integration_test/transcript_scroll_perf_test.dart \
///     --dart-define=PERF_DB=/path/to/copy/agentic_phone.db \
///     --dart-define=PERF_CHAT="thinking set"
///
/// Point PERF_DB at a *copy* of the app database — never the live file.
const _dbPath = String.fromEnvironment('PERF_DB');
const _chatTitle = String.fromEnvironment('PERF_CHAT');

/// Record a timeline with per-widget build/layout events instead of frame
/// stats (`--dart-define=PERF_TRACE=true`).
const _trace = bool.fromEnvironment('PERF_TRACE');

/// Seconds to sit idle after opening before scrolling (0 = scroll at once).
const _waitSeconds = int.fromEnvironment('PERF_WAIT', defaultValue: 1);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('transcript scroll', (tester) async {
    expect(_dbPath, isNotEmpty, reason: 'pass --dart-define=PERF_DB=...');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = AppDatabase(overridePath: _dbPath);
    final chats = await db.listAllChats();
    // Titles are not unique (an empty duplicate is common): take the fullest.
    var messages = <ChatMessage>[];
    for (final c in chats.where((c) => c.title == _chatTitle)) {
      final m = await db.listMessagesChronological(c.id);
      if (m.length > messages.length) messages = m;
    }
    expect(messages, isNotEmpty);

    final entries = <TranscriptEntry>[];
    for (final m in messages) {
      if (m.role == MessageRole.tool) {
        try {
          final tool = ToolCallState.fromJson(
            jsonDecode(m.content) as Map<String, dynamic>,
          ).withoutPayloads();
          entries.add(
            TranscriptEntry.tool(tool, messageId: m.id, createdAt: m.createdAt),
          );
          continue;
        } catch (_) {}
      }
      entries.add(TranscriptEntry.message(m));
    }
    final blocks = buildTranscriptBlocks(entriesByTime(entries));
    final snapshot = ValueNotifier(TranscriptSnapshot(blocks: blocks));
    final controller = TranscriptController();

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(
          backgroundColor: AppColors.deep,
          body: TranscriptView(snapshot: snapshot, controller: controller),
        ),
      ),
    );
    // Let idle-time work (background parse, layout warm-up) run as it would
    // while the user reads the newest messages.
    for (var i = 0; i < _waitSeconds * 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final list = find.byType(Scrollable).first;
    binding.reportData = {
      'chat': _chatTitle,
      'messages': messages.length,
      'blocks': blocks.length,
    };
    Future<void> scroll() async {
      // Reversed list: dragging down scrolls up into history.
      for (var i = 0; i < 12; i++) {
        await tester.fling(list, const Offset(0, 600), 2500);
        await tester.pumpAndSettle(const Duration(milliseconds: 16));
      }
      for (var i = 0; i < 12; i++) {
        await tester.fling(list, const Offset(0, -600), 2500);
        await tester.pumpAndSettle(const Duration(milliseconds: 16));
      }
    }

    if (_trace) {
      debugProfileBuildsEnabled = true;
      debugProfileLayoutsEnabled = true;
      // The timeline ring buffer only holds a few seconds: trace three
      // flings into history (first builds of heavy rows), not the full run.
      await binding.traceAction(() async {
        for (var i = 0; i < 3; i++) {
          await tester.fling(list, const Offset(0, 600), 2500);
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
        }
      }, streams: const ['Dart', 'Embedder'], reportKey: 'timeline');
      debugProfileBuildsEnabled = false;
      debugProfileLayoutsEnabled = false;
    } else {
      await binding.watchPerformance(scroll, reportKey: 'scroll');
      // Back at the live end: stream an answer the way ChatScreen publishes
      // flushes, to catch whole-list rebuilds on every snapshot.
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      await binding.watchPerformance(() async {
        var text = '';
        for (var i = 0; i < 60; i++) {
          text += 'Streaming token run $i with some **markdown** and `code`. ';
          if (i % 10 == 9) text += '\n\n';
          snapshot.value = snapshot.value.copyWith(
            liveAssistant: text,
            liveAssistantId: 'live',
            streaming: true,
          );
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 16));
        }
      }, reportKey: 'stream');
    }
  });
}
