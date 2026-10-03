import 'dart:io';

import 'package:agentplantation/data/local/app_database.dart';
import 'package:agentplantation/data/models/archon_chat.dart';
import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/services/archon_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Host _host(String id) => Host(
  id: id,
  alias: 'host-$id',
  hostname: '$id.example',
  username: 'me',
  createdAt: DateTime.utc(2026, 9, 30),
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late ArchonService archon;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('archon-service');
    addTearDown(() => dir.delete(recursive: true));
    db = AppDatabase(overridePath: p.join(dir.path, 'a.db'));
    archon = ArchonService(db);
    for (final id in ['a', 'b']) {
      await db.upsertHost(_host(id));
    }
  });

  test('Archon does not exist until it is placed', () async {
    expect(await archon.current(), isNull);
    expect(await archon.currentHost(), isNull);
  });

  test('placing it creates the chat and its own workspace', () async {
    final chat = await archon.placeOn(_host('a'));
    expect(chat.id, kArchonChatId);

    final repo = await db.getRepo(chat.repoId);
    // Its own folder, not one of the user's repos: Archon directs agents and
    // never executes anything itself.
    expect(repo!.remotePath, ArchonService.workspacePath);
    expect(repo.hostId, 'a');
    expect((await archon.currentHost())!.id, 'a');
  });

  test('placing it twice on the same host does not make a second one', () async {
    await archon.placeOn(_host('a'));
    await archon.placeOn(_host('a'));
    expect((await db.listAllChats()).where((c) => c.isArchon).length, 1);
    expect(
      (await db.listRepos()).where((r) => r.name == 'Archon').length,
      1,
    );
  });

  test('moving hosts repoints the same row, keeping the conversation', () async {
    final first = await archon.placeOn(_host('a'));
    final moved = await archon.placeOn(_host('b'));

    expect(moved.id, first.id, reason: 'one Archon, not two');
    expect((await archon.currentHost())!.id, 'b');
    expect((await db.listAllChats()).where((c) => c.isArchon).length, 1);
    expect(moved.createdAt, first.createdAt);
  });

  test('a move drops the session id, which belonged to the old host', () async {
    await archon.placeOn(_host('a'));
    final placed = (await archon.current())!;
    await db.upsertChat(placed.copyWith(acpSessionId: 'session-on-a'));

    await archon.placeOn(_host('b'));
    // Resuming a session the new host never minted would fail on arrival.
    expect((await archon.current())!.acpSessionId, isNull);
  });

  test('isOn answers for the host it is actually on', () async {
    await archon.placeOn(_host('a'));
    expect(await archon.isOn(_host('a')), isTrue);
    expect(await archon.isOn(_host('b')), isFalse);
  });

  test('the workspace row id is derived, so hosts cannot accumulate', () {
    expect(ArchonService.repoIdFor('a'), ArchonService.repoIdFor('a'));
    expect(
      ArchonService.repoIdFor('a'),
      isNot(ArchonService.repoIdFor('b')),
    );
  });

  test('Archon never shows up in the Agents list', () async {
    await archon.placeOn(_host('a'));
    expect(withoutArchon(await db.listAllChats()), isEmpty);
  });
}
