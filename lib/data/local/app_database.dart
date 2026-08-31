import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/chat.dart';
import '../models/chat_message.dart';
import '../models/host.dart';
import '../models/mcp_server.dart';
import '../models/repo.dart';

/// Local metadata only — never stores secrets.
class AppDatabase {
  AppDatabase({this.overridePath});

  /// Explicit database location. Used by tests; production resolves the app
  /// documents directory instead.
  final String? overridePath;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = overridePath ??
        p.join((await getApplicationDocumentsDirectory()).path, 'agentic_phone.db');
    return openDatabase(
      path,
      version: 8,
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
  outbound_queue TEXT,
  status TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
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
        await _createMcpTables(db);
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
      },
    );
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
    await db.insert('hosts', host.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
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
    final base = path == '/' ? 'root' : path.split('/').where((s) => s.isNotEmpty).last;
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
    await db.insert('repos', repo.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
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
      columns: ['last_read_at', 'outbound_queue'],
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
    }
    await db.insert('chats', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Persist the in-memory outbound prompt queue for [chatId].
  Future<void> setOutboundQueue(
    String chatId,
    List<ChatMessage> queue,
  ) async {
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
      orderBy: 'created_at ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<void> insertMessage(ChatMessage message) async {
    final db = await database;
    await db.insert('messages', message.toMap());
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
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Replace all messages for a chat (destructive; only for an explicit reset).
  Future<void> replaceMessages(String chatId, List<ChatMessage> messages) async {
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
  /// one still holds the truncated copy.
  Future<int> mergeMessages(String chatId, List<ChatMessage> incoming) async {
    if (incoming.isEmpty) return 0;
    final db = await database;
    var changed = 0;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'messages',
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );
      final byId = {
        for (final row in existing) row['id']! as String: row,
      };
      for (final m in incoming) {
        final prev = byId[m.id];
        if (prev == null) {
          await txn.insert(
            'messages',
            m.toMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
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
    final db = await database;
    final rows = await db.query('mcp_servers', orderBy: 'name COLLATE NOCASE');
    return rows.map(McpServer.fromMap).toList();
  }

  Future<McpServer?> getMcpServer(String id) async {
    final db = await database;
    final rows = await db.query('mcp_servers', where: 'id = ?', whereArgs: [id]);
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

  Future<List<McpHostLink>> listMcpHostLinks({String? mcpId, String? hostId}) async {
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
    final enabledIds = links.where((l) => l.enabled).map((l) => l.mcpId).toSet();
    if (enabledIds.isEmpty) return const [];
    final all = await listMcpServers();
    return all.where((m) => enabledIds.contains(m.id)).toList();
  }
}
