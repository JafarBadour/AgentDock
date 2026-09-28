import 'dart:io';

import 'package:agent_dock/data/local/app_database.dart';
import 'package:agent_dock/data/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('updateMessage keeps the original created_at and order', () async {
    // Tool updates used to restamp created_at with now(), moving finished
    // tools to the end of the chat and breaking the host append-push path.
    final dir = await Directory.systemTemp.createTemp('agentdock-messages');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase(overridePath: p.join(dir.path, 'm.db'));
    // Only message rows matter here; skip building a host/repo/chat chain.
    await (await db.database).execute('PRAGMA foreign_keys = OFF');

    final t0 = DateTime.utc(2026, 9, 1, 10);
    ChatMessage msg(String id, String content, DateTime at) => ChatMessage(
          id: id,
          chatId: 'c',
          role: MessageRole.tool,
          content: content,
          createdAt: at,
        );
    await db.insertMessage(msg('tool', 'running', t0));
    await db.insertMessage(
      msg('reply', 'done', t0.add(const Duration(minutes: 1))),
    );

    await db.updateMessage(msg('tool', 'finished', DateTime.utc(2026, 9, 2)));

    final rows = await db.listMessagesChronological('c');
    expect(rows.map((m) => m.id), ['tool', 'reply']);
    expect(rows.first.content, 'finished');
    expect(rows.first.createdAt, t0);
    await (await db.database).close();
  });
}
