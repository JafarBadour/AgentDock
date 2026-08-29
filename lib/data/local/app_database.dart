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
  AppDatabase();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'agentic_phone.db');
    return openDatabase(
      path,
      version: 4,
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
    await db.insert('chats', chat.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
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

  Future<void> updateMessage(ChatMessage message) async {
    final db = await database;
    await db.update(
      'messages',
      message.toMap(),
      where: 'id = ?',
      whereArgs: [message.id],
    );
  }

  /// Replace all messages for a chat (AgentDock pull).
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
