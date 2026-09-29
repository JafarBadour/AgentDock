import 'dart:io';

import 'package:agent_dock/data/local/app_database.dart';
import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/services/transcript_budget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opening a chat used to deserialize the whole archive to keep the newest
/// slice — 12 MB of row decoding on the UI isolate to show 1 MiB, behind the
/// opening spinner. The window is computed in SQL now; these pin that it
/// still returns exactly what the in-memory budget would have.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late List<ChatMessage> all;

  Future<void> seed({int count = 40, String body = 'x'}) async {
    final dir = await Directory.systemTemp.createTemp('agentdock-window');
    addTearDown(() => dir.delete(recursive: true));
    db = AppDatabase(overridePath: p.join(dir.path, 'w.db'));
    final handle = await db.database;
    // Tear-downs run last-first: close before the directory goes, or
    // Windows refuses to delete the still-open file.
    addTearDown(handle.close);
    await handle.execute('PRAGMA foreign_keys = OFF');
    all = [
      for (var i = 0; i < count; i++)
        ChatMessage(
          id: 'm$i',
          chatId: 'c',
          role: i.isEven ? MessageRole.user : MessageRole.assistant,
          content: '$body${'.' * (i * 3)} $i',
          createdAt: DateTime.utc(2026, 9, 1, 10).add(Duration(minutes: i)),
        ),
    ];
    for (final m in all) {
      await db.insertMessage(m);
    }
  }

  test('recent window matches the in-memory budget exactly', () async {
    await seed();
    for (final budget in [200, 900, 4000, 1 << 20]) {
      final sql = await db.listRecentMessagesByBytes('c', maxBytes: budget);
      final memory = takeRecentMessagesByBytes(all, maxBytes: budget);
      expect(
        sql.messages.map((m) => m.id),
        memory.map((m) => m.id),
        reason: 'budget $budget',
      );
      expect(sql.hasMore, memory.length < all.length, reason: 'budget $budget');
    }
  });

  test('older window matches the in-memory budget exactly', () async {
    await seed();
    for (final pivot in ['m10', 'm25', 'm39']) {
      final sql = await db.listOlderMessagesByBytes(
        'c',
        beforeId: pivot,
        maxBytes: 900,
      );
      final memory = takeOlderMessagesByBytes(
        all,
        beforeId: pivot,
        maxBytes: 900,
      );
      expect(sql.messages.map((m) => m.id), memory.map((m) => m.id),
          reason: 'pivot $pivot');
    }
  });

  test('the oldest pivot reports nothing older', () async {
    await seed();
    final page = await db.listOlderMessagesByBytes(
      'c',
      beforeId: 'm0',
      maxBytes: 1 << 20,
    );
    expect(page.messages, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('an unknown pivot still yields the archive', () async {
    await seed();
    final page = await db.listOlderMessagesByBytes(
      'c',
      beforeId: 'never-persisted',
      maxBytes: 1 << 20,
    );
    expect(page.messages.length, all.length);
  });

  test('budget is counted in UTF-8 bytes, not characters', () async {
    // LENGTH() on TEXT counts characters; a chat of multi-byte content would
    // then admit several times the intended bytes.
    await seed(count: 12, body: 'これは日本語のテキストです');
    final page = await db.listRecentMessagesByBytes('c', maxBytes: 600);
    final used = page.messages.fold<int>(0, (n, m) => n + chatMessageBytes(m));
    expect(used, lessThanOrEqualTo(600 + chatMessageBytes(page.messages.first)));
    expect(
      page.messages.map((m) => m.id),
      takeRecentMessagesByBytes(all, maxBytes: 600).map((m) => m.id),
    );
  });

  test('an empty chat is empty, not an error', () async {
    await seed(count: 0);
    final page = await db.listRecentMessagesByBytes('c', maxBytes: 1 << 20);
    expect(page.messages, isEmpty);
    expect(page.hasMore, isFalse);
  });
}
