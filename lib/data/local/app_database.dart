import 'dart:convert';
import 'dart:math' show max, min;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/chat.dart';
import '../models/chat_message.dart';
import '../models/code_change_stats.dart';
import '../models/host.dart';
import '../models/mcp_server.dart';
import '../models/repo.dart';
import '../models/scheduled_job.dart';
import '../../services/transcript_budget.dart';

/// Local metadata only — never stores secrets.
class AppDatabase {
  AppDatabase({this.overridePath});

  /// Explicit database location. Used by tests; production resolves the app
  /// documents directory instead.
  final String? overridePath;

  Database? _db;
  Future<Database>? _opening;

  Future<Database> get database async {
    if (_db != null) return _db!;
    // Several providers start together on the first frame. Without memoizing
    // the in-flight open, each caller can race through `_db == null` and open
    // the same SQLite file independently (including concurrent migrations).
    // Besides lock contention, result decoding from those duplicate opens can
    // starve Flutter's UI isolate.
    final opening = _opening ??= _open();
    try {
      final db = await opening;
      _db = db;
      return db;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  Future<Database> _open() async {
    final path =
        overridePath ??
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          'agentic_phone.db',
        );
    return openDatabase(
      path,
      version: 18,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE hosts (
  id TEXT PRIMARY KEY NOT NULL,
  alias TEXT NOT NULL,
  hostname TEXT NOT NULL,
  username TEXT NOT NULL,
  port INTEGER NOT NULL,
  jump_host_id TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  FOREIGN KEY (jump_host_id) REFERENCES hosts (id) ON DELETE SET NULL
)''');
        await db.execute('''
CREATE TABLE repos (
  id TEXT PRIMARY KEY NOT NULL,
  host_id TEXT NOT NULL,
  name TEXT NOT NULL,
  remote_path TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  FOREIGN KEY (host_id) REFERENCES hosts (id) ON DELETE CASCADE
)''');
        await db.execute('''
CREATE TABLE chats (
  id TEXT PRIMARY KEY NOT NULL,
  repo_id TEXT NOT NULL,
  title TEXT NOT NULL,
  provider TEXT NOT NULL,
  tmux_session TEXT,
  acp_session_id TEXT,
  journal_offset INTEGER NOT NULL DEFAULT 0,
  model_id TEXT,
  last_read_at TEXT,
  last_auto_number INTEGER,
  lines_added INTEGER NOT NULL DEFAULT 0,
  lines_removed INTEGER NOT NULL DEFAULT 0,
  files_changed INTEGER NOT NULL DEFAULT 0,
  code_delta_day TEXT,
  outbound_queue TEXT,
  status TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  title_updated_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (repo_id) REFERENCES repos (id) ON DELETE CASCADE
)''');
        await db.execute('''
CREATE TABLE messages (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (chat_id) REFERENCES chats (id) ON DELETE CASCADE
)''');
        await db.execute('CREATE INDEX idx_repos_host ON repos(host_id)');
        await db.execute('CREATE INDEX idx_chats_repo ON chats(repo_id)');
        await db.execute('CREATE INDEX idx_messages_chat ON messages(chat_id)');
        await db.execute(
          'CREATE INDEX idx_messages_chat_created '
          'ON messages(chat_id, created_at DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_messages_unread '
          'ON messages(role, chat_id, created_at)',
        );
        await _createMcpTables(db);
        await _createScheduledJobsTable(db);
        await db.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_mcp_servers_name_unique '
          'ON mcp_servers(name COLLATE NOCASE)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE hosts ADD COLUMN jump_host_id TEXT');
        }
        if (oldVersion < 3) {
          await _createMcpTables(db);
        }
        if (oldVersion < 4) {
          await _addSortOrderColumns(db);
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE chats ADD COLUMN journal_offset INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE chats ADD COLUMN model_id TEXT');
        }
        if (oldVersion < 7) {
          await db.execute('ALTER TABLE chats ADD COLUMN last_read_at TEXT');
          // Treat everything that already exists as seen, otherwise every old
          // chat would light up unread on first launch after the update.
          await db.execute('UPDATE chats SET last_read_at = updated_at');
        }
        if (oldVersion < 8) {
          await db.execute('ALTER TABLE chats ADD COLUMN outbound_queue TEXT');
        }
        if (oldVersion < 9) {
          await _createScheduledJobsTable(db);
        }
        if (oldVersion < 10) {
          await db.execute(
            'ALTER TABLE chats ADD COLUMN last_auto_number INTEGER',
          );
          await _ensureScheduledJobNumbers(db);
        }
        if (oldVersion < 11) {
          await _addScheduledJobHostFields(db);
        }
        if (oldVersion < 12) {
          await db.execute(
            'ALTER TABLE chats ADD COLUMN lines_added INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE chats ADD COLUMN lines_removed INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE chats ADD COLUMN files_changed INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 13) {
          await db.execute('ALTER TABLE chats ADD COLUMN code_delta_day TEXT');
          final today = codeDeltaLocalDayKey();
          await db.update(
            'chats',
            {'code_delta_day': today},
            where:
                'code_delta_day IS NULL AND (lines_added > 0 OR lines_removed > 0 OR files_changed > 0)',
          );
        }
        if (oldVersion < 14) {
          await db.execute(
            'ALTER TABLE chats ADD COLUMN title_updated_at TEXT',
          );
          // Seed a title clock from the row's existing updated_at so renames
          // after this migrate can win against ADSM status bumps.
          await db.execute(
            'UPDATE chats SET title_updated_at = updated_at '
            'WHERE title_updated_at IS NULL',
          );
        }
        if (oldVersion < 15) {
          // Agents list sorts by updated_at = last user/assistant message.
          await db.execute('''
UPDATE chats
SET updated_at = (
  SELECT MAX(m.created_at) FROM messages m
  WHERE m.chat_id = chats.id
    AND m.role IN ('user', 'assistant')
)
WHERE EXISTS (
  SELECT 1 FROM messages m
  WHERE m.chat_id = chats.id
    AND m.role IN ('user', 'assistant')
)
AND (
  updated_at IS NULL
  OR updated_at < (
    SELECT MAX(m.created_at) FROM messages m
    WHERE m.chat_id = chats.id
      AND m.role IN ('user', 'assistant')
  )
)
''');
        }
        if (oldVersion < 16) {
          await db.execute(
            'ALTER TABLE mcp_host_links ADD COLUMN targets_json TEXT',
          );
        }
        if (oldVersion < 17) {
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_chat_created '
            'ON messages(chat_id, created_at DESC)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_unread '
            'ON messages(role, chat_id, created_at)',
          );
        }
        if (oldVersion < 18) {
          // Duplicate mcp_servers rows (same name, different ids) are cleaned
          // in [dedupeMcpServersByName] on first open after this migrate.
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_mcp_servers_name '
            'ON mcp_servers(name COLLATE NOCASE)',
          );
        }
      },
    );
  }

  bool _mcpDeduped = false;

  /// Collapse duplicate MCP definitions that share a name (case-insensitive).
  ///
  /// Remote sync used to mint a new UUID stub whenever it raced or when a
  /// configured row and a probe stub both existed — the settings list then
  /// showed the same server many times.
  Future<int> dedupeMcpServersByName() async {
    final db = await database;
    final rows = await db.query('mcp_servers', orderBy: 'name COLLATE NOCASE');
    final all = rows.map(McpServer.fromMap).toList();
    if (all.length < 2) return 0;

    final groups = <String, List<McpServer>>{};
    for (final mcp in all) {
      final key = mcp.name.trim().toLowerCase();
      if (key.isEmpty) continue;
      (groups[key] ??= <McpServer>[]).add(mcp);
    }

    var removed = 0;
    for (final group in groups.values) {
      if (group.length < 2) continue;
      group.sort(_mcpDedupeRank);
      final winner = group.first;
      for (final loser in group.skip(1)) {
        await _reassignMcpLinks(fromId: loser.id, toId: winner.id);
        await db.delete('mcp_servers', where: 'id = ?', whereArgs: [loser.id]);
        removed++;
      }
      // Normalize stored name to trimmed form.
      if (winner.name != winner.name.trim()) {
        await upsertMcpServer(
          McpServer(
            id: winner.id,
            name: winner.name.trim(),
            transport: winner.transport,
            command: winner.command,
            args: winner.args,
            url: winner.url,
            env: winner.env,
            createdAt: winner.createdAt,
          ),
        );
      }
    }
    return removed;
  }

  static int _mcpDedupeRank(McpServer a, McpServer b) {
    int score(McpServer m) {
      var s = 0;
      if ((m.url ?? '').trim().isNotEmpty) s += 4;
      if ((m.command ?? '').trim().isNotEmpty) s += 4;
      if (m.env.isNotEmpty) s += 2;
      if (m.args.isNotEmpty) s += 1;
      return s;
    }

    final byScore = score(b).compareTo(score(a));
    if (byScore != 0) return byScore;
    return a.createdAt.compareTo(b.createdAt);
  }

  Future<void> _reassignMcpLinks({
    required String fromId,
    required String toId,
  }) async {
    if (fromId == toId) return;
    final losers = await listMcpHostLinks(mcpId: fromId);
    for (final link in losers) {
      final existing = await listMcpHostLinks(mcpId: toId, hostId: link.hostId);
      if (existing.isEmpty) {
        await upsertMcpHostLink(
          McpHostLink(
            mcpId: toId,
            hostId: link.hostId,
            enabled: link.enabled,
            installStatus: link.installStatus,
            installDetail: link.installDetail,
            targets: link.targets,
          ),
        );
      } else {
        final keep = existing.first;
        final mergedTargets = <McpClientTarget>{
          ...keep.targets,
          ...link.targets,
        }.toList();
        final preferLoser =
            link.installStatus == McpHostInstallStatus.installed &&
            keep.installStatus != McpHostInstallStatus.installed;
        await upsertMcpHostLink(
          keep.copyWith(
            enabled: keep.enabled || link.enabled,
            installStatus: preferLoser ? link.installStatus : keep.installStatus,
            installDetail: preferLoser
                ? link.installDetail
                : (keep.installDetail ?? link.installDetail),
            targets: mergedTargets,
          ),
        );
      }
      await deleteMcpHostLink(fromId, link.hostId);
    }
  }

  Future<McpServer?> findMcpServerByName(String name) async {
    final key = name.trim().toLowerCase();
    if (key.isEmpty) return null;
    final db = await database;
    final rows = await db.query('mcp_servers', orderBy: 'name COLLATE NOCASE');
    for (final row in rows) {
      final mcp = McpServer.fromMap(row);
      if (mcp.name.trim().toLowerCase() == key) return mcp;
    }
    return null;
  }

  /// Ensure duplicates are collapsed once per process (and after v18 migrate).
  Future<void> ensureMcpServersDeduped() async {
    if (_mcpDeduped) return;
    // Mark early so nested listMcpServers/dedupe calls don't re-enter.
    _mcpDeduped = true;
    try {
      // Use the open DB without going through listMcpServers (avoids recursion).
      final db = await database;
      final rows = await db.query('mcp_servers', orderBy: 'name COLLATE NOCASE');
      final all = rows.map(McpServer.fromMap).toList();
      if (all.length >= 2) {
        final groups = <String, List<McpServer>>{};
        for (final mcp in all) {
          final key = mcp.name.trim().toLowerCase();
          if (key.isEmpty) continue;
          (groups[key] ??= <McpServer>[]).add(mcp);
        }
        for (final group in groups.values) {
          if (group.length < 2) continue;
          group.sort(_mcpDedupeRank);
          final winner = group.first;
          for (final loser in group.skip(1)) {
            await _reassignMcpLinks(fromId: loser.id, toId: winner.id);
            await db.delete(
              'mcp_servers',
              where: 'id = ?',
              whereArgs: [loser.id],
            );
          }
          if (winner.name != winner.name.trim()) {
            await db.insert(
              'mcp_servers',
              McpServer(
                id: winner.id,
                name: winner.name.trim(),
                transport: winner.transport,
                command: winner.command,
                args: winner.args,
                url: winner.url,
                env: winner.env,
                createdAt: winner.createdAt,
              ).toMap(),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      }
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_mcp_servers_name_unique '
        'ON mcp_servers(name COLLATE NOCASE)',
      );
    } catch (_) {
      _mcpDeduped = false;
      rethrow;
    }
  }

  static Future<void> _createScheduledJobsTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS scheduled_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  number INTEGER NOT NULL DEFAULT 0,
  title TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  prompt TEXT NOT NULL,
  kind TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  interval_minutes INTEGER,
  hour INTEGER,
  minute INTEGER,
  weekdays TEXT,
  next_run_at TEXT NOT NULL,
  last_run_at TEXT,
  last_error TEXT,
  done_prompt TEXT,
  context_summary TEXT,
  repeat_until_done INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (chat_id) REFERENCES chats (id) ON DELETE CASCADE
)''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_next '
      'ON scheduled_jobs(enabled, next_run_at)',
    );
  }

  static Future<void> _addScheduledJobHostFields(Database db) async {
    final info = await db.rawQuery('PRAGMA table_info(scheduled_jobs)');
    final names = {for (final c in info) c['name'] as String?};
    if (!names.contains('done_prompt')) {
      await db.execute(
        'ALTER TABLE scheduled_jobs ADD COLUMN done_prompt TEXT',
      );
    }
    if (!names.contains('context_summary')) {
      await db.execute(
        'ALTER TABLE scheduled_jobs ADD COLUMN context_summary TEXT',
      );
    }
    if (!names.contains('repeat_until_done')) {
      await db.execute(
        'ALTER TABLE scheduled_jobs ADD COLUMN repeat_until_done '
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  /// Adds [number] if missing (v9 installs) and backfills 1…N by created_at.
  static Future<void> _ensureScheduledJobNumbers(Database db) async {
    final info = await db.rawQuery('PRAGMA table_info(scheduled_jobs)');
    final hasNumber = info.any((c) => c['name'] == 'number');
    if (!hasNumber) {
      await db.execute(
        'ALTER TABLE scheduled_jobs ADD COLUMN number INTEGER NOT NULL DEFAULT 0',
      );
    }
    final rows = await db.query('scheduled_jobs', orderBy: 'created_at ASC');
    for (var i = 0; i < rows.length; i++) {
      final current = rows[i]['number'] as int? ?? 0;
      if (current > 0) continue;
      await db.update(
        'scheduled_jobs',
        {'number': i + 1},
        where: 'id = ?',
        whereArgs: [rows[i]['id']],
      );
    }
  }

  static Future<void> _addSortOrderColumns(Database db) async {
    await db.execute(
      'ALTER TABLE hosts ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE repos ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE chats ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
    );

    final hosts = await db.query('hosts', orderBy: 'alias COLLATE NOCASE');
    for (var i = 0; i < hosts.length; i++) {
      await db.update(
        'hosts',
        {'sort_order': i},
        where: 'id = ?',
        whereArgs: [hosts[i]['id']],
      );
    }

    final hostIds = hosts.map((h) => h['id']! as String).toList();
    for (final hostId in hostIds) {
      final repos = await db.query(
        'repos',
        where: 'host_id = ?',
        whereArgs: [hostId],
        orderBy: 'name COLLATE NOCASE',
      );
      for (var i = 0; i < repos.length; i++) {
        await db.update(
          'repos',
          {'sort_order': i},
          where: 'id = ?',
          whereArgs: [repos[i]['id']],
        );
      }
    }

    final repos = await db.query('repos');
    for (final repo in repos) {
      final chats = await db.query(
        'chats',
        where: 'repo_id = ?',
        whereArgs: [repo['id']],
        orderBy: 'updated_at DESC',
      );
      for (var i = 0; i < chats.length; i++) {
        await db.update(
          'chats',
          {'sort_order': i},
          where: 'id = ?',
          whereArgs: [chats[i]['id']],
        );
      }
    }
  }

  static Future<void> _createMcpTables(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS mcp_servers (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  transport TEXT NOT NULL,
  command TEXT,
  args_json TEXT,
  url TEXT,
  env_json TEXT,
  created_at TEXT NOT NULL
)''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS mcp_host_links (
  mcp_id TEXT NOT NULL,
  host_id TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  install_status TEXT NOT NULL DEFAULT 'pending',
  install_detail TEXT,
  targets_json TEXT,
  PRIMARY KEY (mcp_id, host_id),
  FOREIGN KEY (mcp_id) REFERENCES mcp_servers (id) ON DELETE CASCADE,
  FOREIGN KEY (host_id) REFERENCES hosts (id) ON DELETE CASCADE
)''');
  }

  Future<List<Host>> listHosts() async {
    final db = await database;
    final rows = await db.query(
      'hosts',
      orderBy: 'sort_order ASC, alias COLLATE NOCASE',
    );
    return rows.map(Host.fromMap).toList();
  }

  Future<int> nextHostSortOrder() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM hosts',
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> reorderHosts(List<String> orderedIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await txn.update(
          'hosts',
          {'sort_order': i},
          where: 'id = ?',
          whereArgs: [orderedIds[i]],
        );
      }
    });
  }

  Future<Host?> getHost(String id) async {
    final db = await database;
    final rows = await db.query('hosts', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Host.fromMap(rows.first);
  }

  Future<void> upsertHost(Host host) async {
    final db = await database;
    await db.insert(
      'hosts',
      host.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteHost(String id) async {
    final db = await database;
    await db.delete('hosts', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Repo>> listRepos({String? hostId}) async {
    final db = await database;
    final rows = hostId == null
        ? await db.query(
            'repos',
            orderBy: 'sort_order ASC, name COLLATE NOCASE',
          )
        : await db.query(
            'repos',
            where: 'host_id = ?',
            whereArgs: [hostId],
            orderBy: 'sort_order ASC, name COLLATE NOCASE',
          );
    return rows.map(Repo.fromMap).toList();
  }

  Future<int> nextRepoSortOrder(String hostId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM repos WHERE host_id = ?',
      [hostId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> reorderRepos(String hostId, List<String> orderedIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await txn.update(
          'repos',
          {'sort_order': i},
          where: 'id = ? AND host_id = ?',
          whereArgs: [orderedIds[i], hostId],
        );
      }
    });
  }

  Future<Repo?> getRepo(String id) async {
    final db = await database;
    final rows = await db.query('repos', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Repo.fromMap(rows.first);
  }

  /// Match ignoring trailing slashes (except root `/`).
  Future<Repo?> findRepoByHostAndPath(String hostId, String remotePath) async {
    final normalized = _normalizePath(remotePath);
    final repos = await listRepos(hostId: hostId);
    for (final repo in repos) {
      if (_normalizePath(repo.remotePath) == normalized) return repo;
    }
    return null;
  }

  Future<Repo> findOrCreateRepoByPath({
    required String hostId,
    required String remotePath,
    required String name,
  }) async {
    final path = _normalizePath(remotePath);
    final existing = await findRepoByHostAndPath(hostId, path);
    if (existing != null) return existing;
    final base = path == '/'
        ? 'root'
        : path.split('/').where((s) => s.isNotEmpty).last;
    final repo = Repo(
      id: const Uuid().v4(),
      hostId: hostId,
      name: name.trim().isEmpty ? base : name.trim(),
      remotePath: path,
      sortOrder: await nextRepoSortOrder(hostId),
      createdAt: DateTime.now(),
    );
    await upsertRepo(repo);
    return repo;
  }

  static String _normalizePath(String path) {
    var p = path.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  Future<void> upsertRepo(Repo repo) async {
    final db = await database;
    await db.insert(
      'repos',
      repo.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteRepo(String id) async {
    final db = await database;
    await db.delete('repos', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Chat>> listChats(String repoId) async {
    final db = await database;
    final rows = await db.query(
      'chats',
      where: 'repo_id = ?',
      whereArgs: [repoId],
      orderBy: 'sort_order ASC, updated_at DESC',
    );
    return rows.map(Chat.fromMap).toList();
  }

  Future<List<Chat>> listAllChats() async {
    final db = await database;
    final rows = await db.query('chats', orderBy: 'updated_at DESC');
    return rows.map(Chat.fromMap).toList();
  }

  Future<int> nextChatSortOrder(String repoId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM chats WHERE repo_id = ?',
      [repoId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> reorderChats(String repoId, List<String> orderedIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await txn.update(
          'chats',
          {'sort_order': i},
          where: 'id = ? AND repo_id = ?',
          whereArgs: [orderedIds[i], repoId],
        );
      }
    });
  }

  Future<Chat?> getChat(String id) async {
    final db = await database;
    final rows = await db.query('chats', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Chat.fromMap(rows.first);
  }

  Future<void> upsertChat(Chat chat) async {
    final db = await database;
    final row = chat.toMap();
    // A full-row replace would otherwise let any caller carrying an older Chat
    // snapshot rewind the read watermark or wipe the outbound queue.
    final existing = await db.query(
      'chats',
      columns: ['last_read_at', 'outbound_queue', 'last_auto_number'],
      where: 'id = ?',
      whereArgs: [chat.id],
    );
    if (existing.isNotEmpty) {
      final current = existing.first['last_read_at'] as String?;
      final incoming = row['last_read_at'] as String?;
      if (current != null &&
          (incoming == null || current.compareTo(incoming) > 0)) {
        row['last_read_at'] = current;
      }
      row['outbound_queue'] = existing.first['outbound_queue'];
      // Keep the automation badge unless this write explicitly sets one.
      if (row['last_auto_number'] == null) {
        row['last_auto_number'] = existing.first['last_auto_number'];
      }
    }
    await db.insert('chats', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Persist the in-memory outbound prompt queue for [chatId].
  Future<void> setOutboundQueue(String chatId, List<ChatMessage> queue) async {
    final db = await database;
    final payload = queue.isEmpty
        ? null
        : jsonEncode(queue.map((m) => m.toMap()).toList());
    await db.update(
      'chats',
      {'outbound_queue': payload},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  Future<List<ChatMessage>> getOutboundQueue(String chatId) async {
    final db = await database;
    final rows = await db.query(
      'chats',
      columns: ['outbound_queue'],
      where: 'id = ?',
      whereArgs: [chatId],
      limit: 1,
    );
    if (rows.isEmpty) return const [];
    final raw = rows.first['outbound_queue'] as String?;
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => ChatMessage.fromMap(Map<String, Object?>.from(m)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> deleteChat(String id) async {
    final db = await database;
    await db.delete('chats', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<ChatMessage>> listMessages(String chatId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at ASC, rowid ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// Newest [limit] messages (ASC order) — for fast chat open without loading
  /// the full history into memory on the UI isolate.
  Future<List<ChatMessage>> listRecentMessages(
    String chatId, {
    int limit = 250,
  }) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      // Reverse below restores chronological + insertion order, including
      // deterministic ordering when two events share the same timestamp.
      orderBy: 'created_at DESC, rowid DESC',
      limit: limit,
    );
    return rows.reversed.map(ChatMessage.fromMap).toList();
  }

  /// Chronological messages for a chat (full local archive). Prefer
  /// [listRecentMessagesByBytes] for UI opens.
  Future<List<ChatMessage>> listMessagesChronological(String chatId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at ASC, rowid ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// Last ~[maxBytes] of local message content (UTF-8), chronological.
  Future<({List<ChatMessage> messages, bool hasMore})> listRecentMessagesByBytes(
    String chatId, {
    required int maxBytes,
  }) async {
    final all = await listMessagesChronological(chatId);
    final slice = takeRecentMessagesByBytes(all, maxBytes: maxBytes);
    return (messages: slice, hasMore: slice.length < all.length);
  }

  /// Next older ~[maxBytes] before [beforeId], chronological.
  Future<({List<ChatMessage> messages, bool hasMore})> listOlderMessagesByBytes(
    String chatId, {
    required String beforeId,
    required int maxBytes,
  }) async {
    final all = await listMessagesChronological(chatId);
    final slice = takeOlderMessagesByBytes(
      all,
      beforeId: beforeId,
      maxBytes: maxBytes,
    );
    final pivot = all.indexWhere((m) => m.id == beforeId);
    final olderCount = pivot < 0 ? 0 : pivot;
    return (
      messages: slice,
      hasMore: slice.isNotEmpty && slice.length < olderCount,
    );
  }

  /// Stable chronological page without materializing the whole transcript.
  Future<List<ChatMessage>> listMessagePage(
    String chatId, {
    required int offset,
    int? limit,
  }) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at ASC, rowid ASC',
      limit: limit ?? -1,
      offset: offset,
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<int> countMessages(String chatId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM messages WHERE chat_id = ?',
      [chatId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> clearMessages(String chatId) async {
    final db = await database;
    await db.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
  }

  Future<void> insertMessage(ChatMessage message) async {
    final db = await database;
    await db.insert('messages', message.toMap());
    if (message.role == MessageRole.user ||
        message.role == MessageRole.assistant) {
      await touchChatActivity(message.chatId, at: message.createdAt);
    }
  }

  Future<void> deleteMessage(String id) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateMessage(ChatMessage message) async {
    final db = await database;
    await db.update(
      'messages',
      message.toMap(),
      where: 'id = ?',
      whereArgs: [message.id],
    );
  }

  /// Insert or overwrite a single message by id.
  ///
  /// Used to keep the row for an in-progress agent turn up to date as text
  /// streams in, so the transcript on disk never lags far behind the screen.
  Future<void> upsertMessage(ChatMessage message) async {
    final db = await database;
    final existing = await db.query(
      'messages',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [message.id],
      limit: 1,
    );
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // Only bump list order on the first write of a user/assistant bubble —
    // streaming checkpoints must not reshuffle the Agents list every token.
    if (existing.isEmpty &&
        (message.role == MessageRole.user ||
            message.role == MessageRole.assistant)) {
      await touchChatActivity(message.chatId, at: message.createdAt);
    }
  }

  /// Move [chatId] to the top of the Agents list (newest activity first).
  ///
  /// Returns true when [updated_at] actually moved forward.
  Future<bool> touchChatActivity(String chatId, {DateTime? at}) async {
    final db = await database;
    final ts = (at ?? DateTime.now()).toUtc().toIso8601String();
    final n = await db.rawUpdate(
      'UPDATE chats SET updated_at = ? '
      'WHERE id = ? AND (updated_at IS NULL OR updated_at < ?)',
      [ts, chatId, ts],
    );
    return n > 0;
  }

  /// Replace all messages for a chat (destructive; only for an explicit reset).
  Future<void> replaceMessages(
    String chatId,
    List<ChatMessage> messages,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
      for (final m in messages) {
        await txn.insert(
          'messages',
          m.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Union [incoming] into a chat's transcript, keyed by message id.
  ///
  /// New ids are inserted. For ids we already have, the longer body wins —
  /// that covers assistant checkpoints growing on another device while this
  /// one still holds the truncated copy. Identical role+content with a
  /// different id (phone vs ADSM) is skipped to avoid duplicate bubbles.
  Future<int> mergeMessages(String chatId, List<ChatMessage> incoming) async {
    if (incoming.isEmpty) return 0;
    final db = await database;
    var changed = 0;
    await db.transaction((txn) async {
      // Never deserialize the entire local transcript to merge a bounded host
      // tail. Fetch exact ids in SQLite-sized chunks, plus a bounded recent
      // window for cross-device duplicate-content detection.
      final byId = <String, Map<String, Object?>>{};
      final ids = incoming.map((m) => m.id).toSet().toList(growable: false);
      const idChunk = 300;
      for (var i = 0; i < ids.length; i += idChunk) {
        final end = min(i + idChunk, ids.length);
        final chunk = ids.sublist(i, end);
        final rows = await txn.query(
          'messages',
          where:
              'chat_id = ? AND id IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: [chatId, ...chunk],
        );
        for (final row in rows) {
          byId[row['id']! as String] = row;
        }
      }
      final duplicateWindow = max(1800, incoming.length * 2);
      final recent = await txn.query(
        'messages',
        columns: ['id', 'role', 'content'],
        where: 'chat_id = ?',
        whereArgs: [chatId],
        orderBy: 'created_at DESC, rowid DESC',
        limit: duplicateWindow,
      );
      final contentKeys = <(String, String)>{
        for (final row in recent)
          (row['role']! as String, row['content']! as String),
        for (final row in byId.values)
          (row['role']! as String, row['content']! as String),
      };
      for (final m in incoming) {
        final prev = byId[m.id];
        if (prev == null) {
          final key = (m.role.name, m.content);
          if (contentKeys.contains(key)) {
            // Same bubble already present under another id.
            continue;
          }
          await txn.insert(
            'messages',
            m.toMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          byId[m.id] = m.toMap();
          contentKeys.add(key);
          changed++;
          continue;
        }
        final prevContent = prev['content']! as String;
        if (m.content.length > prevContent.length) {
          await txn.update(
            'messages',
            m.toMap(),
            where: 'id = ?',
            whereArgs: [m.id],
          );
          contentKeys.remove((m.role.name, prevContent));
          contentKeys.add((m.role.name, m.content));
          changed++;
        }
      }
    });
    return changed;
  }

  /// Mark everything in [chatId] up to [at] (default now) as seen.
  ///
  /// The watermark only ever moves forward. Long-lived runtimes hold a [Chat]
  /// snapshot from when the screen opened, and a stale write must not make
  /// already-read replies unread again — nor may a lagging device undo a read
  /// that another device already synced.
  Future<void> markChatRead(String chatId, {DateTime? at}) async {
    final stamp = (at ?? DateTime.now()).toIso8601String();
    final db = await database;
    await db.rawUpdate(
      'UPDATE chats SET last_read_at = ? '
      'WHERE id = ? AND (last_read_at IS NULL OR last_read_at < ?)',
      [stamp, chatId, stamp],
    );
  }

  /// Unseen agent replies per chat, for the unread badge.
  ///
  /// Only assistant messages count: the user's own messages and tool noise are
  /// not something they need to be called back to.
  Future<Map<String, int>> unreadCounts() async {
    final db = await database;
    final rows = await db.rawQuery('''
SELECT m.chat_id AS chat_id, COUNT(*) AS unread
FROM messages m
JOIN chats c ON c.id = m.chat_id
WHERE m.role = 'assistant'
  AND (c.last_read_at IS NULL OR m.created_at > c.last_read_at)
GROUP BY m.chat_id
''');
    return {
      for (final row in rows)
        row['chat_id'] as String: (row['unread'] as int?) ?? 0,
    };
  }

  Future<void> setJournalOffset(String chatId, int offset) async {
    final db = await database;
    await db.update(
      'chats',
      {'journal_offset': offset},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  // --- MCP ---

  Future<List<McpServer>> listMcpServers() async {
    try {
      await ensureMcpServersDeduped();
    } catch (_) {}
    final db = await database;
    final rows = await db.query('mcp_servers', orderBy: 'name COLLATE NOCASE');
    return rows.map(McpServer.fromMap).toList();
  }

  Future<McpServer?> getMcpServer(String id) async {
    final db = await database;
    final rows = await db.query(
      'mcp_servers',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return McpServer.fromMap(rows.first);
  }

  Future<void> upsertMcpServer(McpServer server) async {
    final db = await database;
    await db.insert(
      'mcp_servers',
      server.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteMcpServer(String id) async {
    final db = await database;
    await db.delete('mcp_servers', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<McpHostLink>> listMcpHostLinks({
    String? mcpId,
    String? hostId,
  }) async {
    final db = await database;
    if (mcpId != null && hostId != null) {
      final rows = await db.query(
        'mcp_host_links',
        where: 'mcp_id = ? AND host_id = ?',
        whereArgs: [mcpId, hostId],
      );
      return rows.map(McpHostLink.fromMap).toList();
    }
    if (mcpId != null) {
      final rows = await db.query(
        'mcp_host_links',
        where: 'mcp_id = ?',
        whereArgs: [mcpId],
      );
      return rows.map(McpHostLink.fromMap).toList();
    }
    if (hostId != null) {
      final rows = await db.query(
        'mcp_host_links',
        where: 'host_id = ?',
        whereArgs: [hostId],
      );
      return rows.map(McpHostLink.fromMap).toList();
    }
    final rows = await db.query('mcp_host_links');
    return rows.map(McpHostLink.fromMap).toList();
  }

  Future<void> upsertMcpHostLink(McpHostLink link) async {
    final db = await database;
    await db.insert(
      'mcp_host_links',
      link.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteMcpHostLink(String mcpId, String hostId) async {
    final db = await database;
    await db.delete(
      'mcp_host_links',
      where: 'mcp_id = ? AND host_id = ?',
      whereArgs: [mcpId, hostId],
    );
  }

  /// MCP servers enabled for [hostId] (for ACP session/new).
  Future<List<McpServer>> listEnabledMcpsForHost(String hostId) async {
    final links = await listMcpHostLinks(hostId: hostId);
    final enabledIds = links
        .where((l) => l.enabled)
        .map((l) => l.mcpId)
        .toSet();
    if (enabledIds.isEmpty) return const [];
    final all = await listMcpServers();
    return all.where((m) => enabledIds.contains(m.id)).toList();
  }

  Future<List<ScheduledJob>> listScheduledJobs() async {
    final db = await database;
    final rows = await db.query(
      'scheduled_jobs',
      orderBy: 'number ASC, created_at ASC',
    );
    return rows.map(ScheduledJob.fromMap).toList();
  }

  Future<List<ScheduledJob>> listDueScheduledJobs(DateTime now) async {
    final db = await database;
    final rows = await db.query(
      'scheduled_jobs',
      where: 'enabled = 1 AND next_run_at <= ?',
      whereArgs: [now.toIso8601String()],
      orderBy: 'next_run_at ASC',
    );
    return rows.map(ScheduledJob.fromMap).toList();
  }

  Future<ScheduledJob?> getScheduledJob(String id) async {
    final db = await database;
    final rows = await db.query(
      'scheduled_jobs',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return ScheduledJob.fromMap(rows.first);
  }

  Future<int> nextScheduledJobNumber() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(number), 0) + 1 AS n FROM scheduled_jobs',
    );
    return (rows.first['n'] as int?) ?? 1;
  }

  Future<void> upsertScheduledJob(ScheduledJob job) async {
    final db = await database;
    await db.insert(
      'scheduled_jobs',
      job.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteScheduledJob(String id) async {
    final db = await database;
    await db.delete('scheduled_jobs', where: 'id = ?', whereArgs: [id]);
  }
}
