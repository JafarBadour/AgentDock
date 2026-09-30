import 'dart:io';

import 'package:agent_dock/data/local/app_database.dart';
import 'package:agent_dock/data/models/archon_brief.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The user switches an agent on and says what done looks like. Archon works
/// toward it, then switches the agent off and leaves a note — so "enabled"
/// always reads as "Archon is still on this".
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('archon-brief');
    addTearDown(() => dir.delete(recursive: true));
    db = AppDatabase(overridePath: p.join(dir.path, 'b.db'));
    await (await db.database).execute('PRAGMA foreign_keys = OFF');
  });

  ArchonBrief brief({
    bool enabled = false,
    String? goal,
    String? note,
    DateTime? doneAt,
  }) => ArchonBrief(
    chatId: 'c1',
    enabled: enabled,
    goal: goal,
    note: note,
    doneAt: doneAt,
    updatedAt: DateTime.utc(2026, 9, 30),
  );

  group('state', () {
    test('switched on with a goal is work in progress', () {
      final b = brief(enabled: true, goal: 'green CI');
      expect(b.isActive, isTrue);
      expect(b.isDone, isFalse);
    });

    test('switched on without a goal is not work', () {
      // Nothing to work toward means nothing to call finished.
      expect(brief(enabled: true).isActive, isFalse);
      expect(brief(enabled: true, goal: '   ').isActive, isFalse);
    });

    test('off with a note is finished', () {
      final b = brief(goal: 'green CI', note: 'CI green since 14:02');
      expect(b.isDone, isTrue);
      expect(b.isActive, isFalse);
    });

    test('off with no note is simply not being managed', () {
      expect(brief(goal: 'green CI').isDone, isFalse);
    });
  });

  group('storage', () {
    test('a brief round-trips', () async {
      await db.saveArchonBrief(brief(enabled: true, goal: 'green CI'));
      final got = await db.archonBrief('c1');
      expect(got!.enabled, isTrue);
      expect(got.goal, 'green CI');
      expect(got.note, isNull);
    });

    test('an agent with no brief has none', () async {
      expect(await db.archonBrief('never-set'), isNull);
    });

    test('saving again replaces rather than duplicates', () async {
      await db.saveArchonBrief(brief(enabled: true, goal: 'first'));
      await db.saveArchonBrief(brief(enabled: true, goal: 'second'));
      expect((await db.archonBriefs()).length, 1);
      expect((await db.archonBrief('c1'))!.goal, 'second');
    });

    test('finishing switches it off and keeps the note together', () async {
      await db.saveArchonBrief(brief(enabled: true, goal: 'green CI'));
      final current = (await db.archonBrief('c1'))!;
      await db.saveArchonBrief(
        current.copyWith(
          enabled: false,
          note: 'CI green since 14:02',
          doneAt: DateTime.utc(2026, 9, 30, 14, 2),
        ),
      );

      final done = (await db.archonBrief('c1'))!;
      // A toggle left on beside a note would read as work still in progress.
      expect(done.enabled, isFalse);
      expect(done.isDone, isTrue);
      expect(done.note, 'CI green since 14:02');
      expect(done.doneAt, DateTime.utc(2026, 9, 30, 14, 2));
    });

    test('a new goal clears the note from the last one', () {
      final done = brief(note: 'old result', doneAt: DateTime.utc(2026, 9, 1));
      final restarted = done.copyWith(
        enabled: true,
        goal: 'new goal',
        clearNote: true,
      );
      expect(restarted.note, isNull);
      expect(restarted.doneAt, isNull);
      expect(restarted.isActive, isTrue);
    });

    test('briefs come back keyed by chat', () async {
      await db.saveArchonBrief(brief(enabled: true, goal: 'a'));
      await db.saveArchonBrief(
        ArchonBrief(
          chatId: 'c2',
          enabled: false,
          note: 'done',
          updatedAt: DateTime.utc(2026, 9, 30),
        ),
      );
      final all = await db.archonBriefs();
      expect(all.keys.toSet(), {'c1', 'c2'});
      expect(all['c1']!.isActive, isTrue);
      expect(all['c2']!.isDone, isTrue);
    });

    test('deleting a brief leaves the agent alone', () async {
      await db.saveArchonBrief(brief(enabled: true, goal: 'a'));
      await db.deleteArchonBrief('c1');
      expect(await db.archonBrief('c1'), isNull);
    });
  });
}
