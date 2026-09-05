import 'package:agent_dock/data/local/app_database.dart';
import 'package:agent_dock/data/models/agent_provider.dart';
import 'package:agent_dock/data/models/chat.dart';
import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/data/models/host.dart';
import 'package:agent_dock/data/models/repo.dart';
import 'package:agent_dock/services/agentdock_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ChatMessage _msg(String id, String text, DateTime at, {MessageRole? role}) {
  return ChatMessage(
    id: id,
    chatId: 'chat-1',
    role: role ?? MessageRole.user,
    content: text,
    createdAt: at,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(overridePath: inMemoryDatabasePath);
    final now = DateTime(2026, 1, 1);
    await db.upsertHost(
      Host(
        id: 'host-1',
        alias: 'box',
        hostname: 'example.com',
        username: 'me',
        createdAt: now,
      ),
    );
    await db.upsertRepo(
      Repo(
        id: 'repo-1',
        hostId: 'host-1',
        name: 'proj',
        remotePath: '/home/me/proj',
        createdAt: now,
      ),
    );
    await db.upsertChat(
      Chat(
        id: 'chat-1',
        repoId: 'repo-1',
        title: 'Agent',
        provider: AgentProvider.cursor,
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  test('merge keeps local messages the remote has never seen', () async {
    final base = DateTime(2026, 1, 1, 10);
    await db.insertMessage(_msg('local-only', 'written offline', base));

    // Remote copy carries a newer timestamp but is missing the offline message.
    await db.mergeMessages('chat-1', [
      _msg('remote-1', 'from the host', base.add(const Duration(minutes: 5))),
    ]);

    final all = await db.listMessages('chat-1');
    expect(all.map((m) => m.id), containsAll(['local-only', 'remote-1']));
    expect(all, hasLength(2));
  });

  test('merge is idempotent and preserves order', () async {
    final base = DateTime(2026, 1, 1, 10);
    final incoming = [
      _msg('b', 'second', base.add(const Duration(minutes: 2))),
      _msg('a', 'first', base),
      _msg('c', 'third', base.add(const Duration(minutes: 4))),
    ];

    final firstPass = await db.mergeMessages('chat-1', incoming);
    final secondPass = await db.mergeMessages('chat-1', incoming);

    expect(firstPass, 3);
    expect(secondPass, 0, reason: 'a repeated sync must not duplicate rows');

    final all = await db.listMessages('chat-1');
    expect(all.map((m) => m.id).toList(), ['a', 'b', 'c']);
  });

  test('merge does not overwrite a locally edited message body', () async {
    final at = DateTime(2026, 1, 1, 10);
    await db.insertMessage(_msg('shared', 'local streaming copy', at));

    await db.mergeMessages('chat-1', [_msg('shared', 'stale remote copy', at)]);

    final all = await db.listMessages('chat-1');
    expect(all, hasLength(1));
    expect(all.single.content, 'local streaming copy');
  });

  test('merge prefers the longer body when ids match', () async {
    final at = DateTime(2026, 1, 1, 10);
    await db.insertMessage(
      _msg('a1', 'partial', at, role: MessageRole.assistant),
    );

    await db.mergeMessages('chat-1', [
      _msg('a1', 'partial then the rest of the turn', at,
          role: MessageRole.assistant),
    ]);

    final all = await db.listMessages('chat-1');
    expect(all, hasLength(1));
    expect(all.single.content, 'partial then the rest of the turn');
  });

  test('merge skips same role+content under a different host id', () async {
    final at = DateTime(2026, 1, 1, 10);
    await db.insertMessage(_msg('phone-u1', 'hello from phone', at));

    final changed = await db.mergeMessages('chat-1', [
      _msg('adsm-u1', 'hello from phone', at),
      _msg('adsm-a1', 'host reply', at, role: MessageRole.assistant),
    ]);

    expect(changed, 1, reason: 'only the assistant is new');
    final all = await db.listMessages('chat-1');
    expect(all.map((m) => m.id).toList(), ['phone-u1', 'adsm-a1']);
  });

  test('reconnect merge restores host transcript without duplicates', () async {
    final base = DateTime(2026, 1, 1, 10);
    // Phone already has the user turn locally; host also stored it under the
    // same id, plus an assistant turn written while the phone was away.
    await db.insertMessage(_msg('u1', 'do the thing', base));

    final changed = await db.mergeMessages('chat-1', [
      _msg('u1', 'do the thing', base),
      _msg(
        'a1',
        'done on host',
        base.add(const Duration(seconds: 2)),
        role: MessageRole.assistant,
      ),
    ]);

    expect(changed, 1);
    final all = await db.listMessages('chat-1');
    expect(all.map((m) => m.id).toList(), ['u1', 'a1']);
    expect(all.last.content, 'done on host');
  });

  test('ChatMessage round-trips host snake_case maps', () {
    final map = <String, Object?>{
      'id': 'm1',
      'chat_id': 'chat-1',
      'role': 'assistant',
      'content': 'from ads',
      'created_at': '2026-01-01T10:00:00.000Z',
    };
    final msg = ChatMessage.fromMap(map);
    expect(msg.toMap()['id'], 'm1');
    expect(msg.role, MessageRole.assistant);
    expect(ChatMessage.fromMap(msg.toMap()).content, 'from ads');
  });

  test('AgentDockService union keeps host-only rows across rewrite', () {
    final base = DateTime(2026, 1, 1, 10);
    final local = [
      _msg('u1', 'local', base),
      _msg('a1', 'short', base.add(const Duration(seconds: 1)),
          role: MessageRole.assistant),
    ];
    final remote = [
      _msg('u1', 'local', base),
      _msg('a1', 'short then longer on host',
          base.add(const Duration(seconds: 1)),
          role: MessageRole.assistant),
      _msg('a2', 'host only', base.add(const Duration(seconds: 2)),
          role: MessageRole.assistant),
    ];
    final merged = AgentDockService.unionMessagesForTest(remote, local);
    expect(merged.map((m) => m.id).toList(), ['u1', 'a1', 'a2']);
    expect(merged[1].content, 'short then longer on host');
  });

  test('replaceMessages still resets a transcript when asked', () async {
    final at = DateTime(2026, 1, 1, 10);
    await db.insertMessage(_msg('old', 'gone', at));
    await db.replaceMessages('chat-1', [_msg('new', 'kept', at)]);

    final all = await db.listMessages('chat-1');
    expect(all.map((m) => m.id).toList(), ['new']);
  });

  test('journal offset round-trips', () async {
    await db.setJournalOffset('chat-1', 4096);
    final chat = await db.getChat('chat-1');
    expect(chat!.journalOffset, 4096);
  });

  group('unread counts', () {
    test('only agent replies newer than the read watermark count', () async {
      await db.markChatRead('chat-1');
      final after = DateTime.now().add(const Duration(minutes: 1));

      await db.insertMessage(
        _msg('u1', 'my question', after, role: MessageRole.user),
      );
      await db.insertMessage(
        _msg('a1', 'my answer', after, role: MessageRole.assistant),
      );
      await db.insertMessage(
        _msg('t1', 'ran a tool', after, role: MessageRole.tool),
      );

      // All three landed after the watermark, but only the assistant reply is
      // something the user needs to be called back to.
      expect(await db.unreadCounts(), {'chat-1': 1});
    });

    test('messages older than the watermark stay read', () async {
      await db.insertMessage(
        _msg(
          'a1',
          'seen long ago',
          DateTime(2026, 1, 1, 10),
          role: MessageRole.assistant,
        ),
      );

      await db.markChatRead('chat-1');

      expect(await db.unreadCounts(), isEmpty);
    });

    test('opening the chat clears the badge', () async {
      await db.insertMessage(
        _msg(
          'a1',
          'answer',
          DateTime(2026, 1, 1, 10),
          role: MessageRole.assistant,
        ),
      );
      expect(await db.unreadCounts(), {'chat-1': 1});

      await db.markChatRead('chat-1');

      expect(await db.unreadCounts(), isEmpty);
    });

    test('a stale chat snapshot cannot rewind the watermark', () async {
      // What a long-lived runtime holds: the chat as it looked on open.
      final stale = (await db.getChat('chat-1'))!;
      await db.markChatRead('chat-1');
      await db.insertMessage(
        _msg(
          'a1',
          'reply',
          DateTime(2026, 1, 1, 10),
          role: MessageRole.assistant,
        ),
      );
      expect(await db.unreadCounts(), isEmpty);

      await db.upsertChat(stale.copyWith(title: 'renamed'));

      expect((await db.getChat('chat-1'))!.title, 'renamed');
      expect(
        await db.unreadCounts(),
        isEmpty,
        reason: 'an unrelated write must not resurrect read messages',
      );
    });

    test('markChatRead only ever moves forward', () async {
      final late = DateTime(2026, 5, 1);
      await db.markChatRead('chat-1', at: late);
      await db.markChatRead('chat-1', at: DateTime(2026, 1, 1));

      expect((await db.getChat('chat-1'))!.lastReadAt, late);
    });

    test('a read on another device carries over the host record', () async {
      final chat = (await db.getChat('chat-1'))!;
      final repo = (await db.listRepos()).single;
      final readThere = DateTime(2026, 4, 1);

      // Round-trip through exactly what lands in ~/.agentdock/agents/<id>.json.
      final json = AgentDockRecord.fromChat(
        chat.copyWith(lastReadAt: readThere),
        repo,
      ).toJson();
      final back = AgentDockRecord.fromJson(Map<String, dynamic>.from(json));

      expect(back.lastReadAt, readThere);
      await db.markChatRead('chat-1', at: back.lastReadAt);
      expect((await db.getChat('chat-1'))!.lastReadAt, readThere);
    });

    test('replies arriving after the last read still count', () async {
      await db.markChatRead('chat-1');
      await db.insertMessage(
        _msg(
          'a1',
          'later',
          DateTime.now().add(const Duration(minutes: 1)),
          role: MessageRole.assistant,
        ),
      );

      expect(await db.unreadCounts(), {'chat-1': 1});
    });
  });

  test('a catalog merge keeps the handles to the running agent', () async {
    // What the chat looks like after connecting: local-only state the host
    // record has no idea about.
    final connected = (await db.getChat('chat-1'))!.copyWith(
      acpSessionId: 'acp-session-abc',
      journalOffset: 264219,
      modelId: 'claude-opus-5',
    );
    await db.upsertChat(connected);

    final repo = (await db.listRepos()).single;
    final record = AgentDockRecord.fromChat(connected, repo);

    // The host only ever knew title/status/timestamps.
    await db.upsertChat(
      (await db.getChat('chat-1'))!.copyWith(
        title: record.title,
        updatedAt: record.updatedAt,
      ),
    );

    final after = (await db.getChat('chat-1'))!;
    expect(
      after.acpSessionId,
      'acp-session-abc',
      reason: 'losing this makes every restart look like a brand new chat',
    );
    expect(after.journalOffset, 264219);
    expect(after.modelId, 'claude-opus-5');
  });

  test('session handles round-trip through the host record', () async {
    final chat = (await db.getChat('chat-1'))!;
    final repo = (await db.listRepos()).single;
    const sessionId = 'acp-session-xyz';
    const modelId =
        'claude-opus-5[thinking=true,context=300k,effort=high,fast=false]';

    final json = AgentDockRecord.fromChat(
      chat.copyWith(
        acpSessionId: sessionId,
        journalOffset: 8192,
        modelId: modelId,
      ),
      repo,
    ).toJson();
    final back = AgentDockRecord.fromJson(Map<String, dynamic>.from(json));

    expect(back.acpSessionId, sessionId);
    expect(back.journalOffset, 8192);
    expect(back.modelId, modelId);

    final merged = AgentDockRecord.mergeSessionState(chat, back);
    expect(merged.acpSessionId, sessionId);
    expect(merged.journalOffset, 8192);
    expect(merged.modelId, modelId);
  });

  test('merge session state picks up handles from another device', () async {
    final local = (await db.getChat('chat-1'))!;
    final repo = (await db.listRepos()).single;
    final remoteRecord = AgentDockRecord.fromChat(
      local.copyWith(
        acpSessionId: 'from-mac',
        journalOffset: 12000,
        modelId: 'claude-opus-5',
        updatedAt: DateTime(2026, 2, 1),
      ),
      repo,
    );

    final merged = AgentDockRecord.mergeSessionState(local, remoteRecord);
    expect(merged.acpSessionId, 'from-mac');
    expect(merged.journalOffset, 12000);
    expect(merged.modelId, 'claude-opus-5');
  });

  test('selected model round-trips so reconnects can re-apply it', () async {
    const modelId = 'claude-opus-5[thinking=true,context=300k,effort=high,fast=false]';
    final chat = await db.getChat('chat-1');
    expect(chat!.modelId, isNull);

    await db.upsertChat(chat.copyWith(modelId: modelId));

    expect((await db.getChat('chat-1'))!.modelId, modelId);
  });

  group('title sync across devices', () {
    test('rename clock wins over a newer ADSM updated_at with old title', () {
      final renamedAt = DateTime(2026, 3, 1, 12);
      final local = Chat(
        id: 'chat-1',
        repoId: 'repo-1',
        title: 'My rename',
        provider: AgentProvider.cursor,
        titleUpdatedAt: renamedAt,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: renamedAt,
      );
      final remote = AgentDockRecord(
        id: 'chat-1',
        title: 'Agent',
        provider: AgentProvider.cursor.id,
        repoPath: '/home/me/proj',
        repoName: 'proj',
        status: ChatStatus.running.name,
        // ADSM bumped updated_at without touching the title.
        titleUpdatedAt: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 3, 1, 13),
      );

      final merged = AgentDockRecord.mergeTitle(local, remote);
      expect(merged.title, 'My rename');
      expect(merged.titleUpdatedAt, renamedAt);
    });

    test('a newer remote rename replaces the local title', () {
      final local = Chat(
        id: 'chat-1',
        repoId: 'repo-1',
        title: 'Old name',
        provider: AgentProvider.cursor,
        titleUpdatedAt: DateTime(2026, 3, 1, 10),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 3, 1, 10),
      );
      final remote = AgentDockRecord(
        id: 'chat-1',
        title: 'Phone rename',
        provider: AgentProvider.cursor.id,
        repoPath: '/home/me/proj',
        repoName: 'proj',
        status: ChatStatus.idle.name,
        titleUpdatedAt: DateTime(2026, 3, 1, 12),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 3, 1, 12),
      );

      final merged = AgentDockRecord.mergeTitle(local, remote);
      expect(merged.title, 'Phone rename');
      expect(merged.titleUpdatedAt, DateTime(2026, 3, 1, 12));
    });

    test('legacy remote without title_updated_at cannot overwrite a rename', () {
      final local = Chat(
        id: 'chat-1',
        repoId: 'repo-1',
        title: 'Kept',
        provider: AgentProvider.cursor,
        titleUpdatedAt: DateTime(2026, 3, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 3, 1),
      );
      final remote = AgentDockRecord(
        id: 'chat-1',
        title: 'Stale',
        provider: AgentProvider.cursor.id,
        repoPath: '/home/me/proj',
        repoName: 'proj',
        status: ChatStatus.running.name,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 3, 2),
      );

      expect(AgentDockRecord.mergedTitle(local, remote), 'Kept');
    });

    test('title_updated_at round-trips through the host JSON', () {
      final at = DateTime(2026, 3, 1, 15, 30);
      final chat = Chat(
        id: 'chat-1',
        repoId: 'repo-1',
        title: 'Synced name',
        provider: AgentProvider.cursor,
        titleUpdatedAt: at,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: at,
      );
      final repo = Repo(
        id: 'repo-1',
        hostId: 'host-1',
        name: 'proj',
        remotePath: '/home/me/proj',
        createdAt: DateTime(2026, 1, 1),
      );
      final json = AgentDockRecord.fromChat(chat, repo).toJson();
      final back =
          AgentDockRecord.fromJson(Map<String, dynamic>.from(json));
      expect(back.title, 'Synced name');
      expect(back.titleUpdatedAt, at);
    });
  });
}
