import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../data/local/app_database.dart';
import '../data/models/agent_provider.dart';
import '../data/models/chat.dart';
import '../data/models/chat_message.dart';
import '../data/models/host.dart';
import '../data/models/repo.dart';
import '../data/secure/safe_log.dart';
import 'ssh_service.dart';

/// One agent metadata file under `~/.agentdock/agents/<id>.json`.
class AgentDockRecord {
  const AgentDockRecord({
    required this.id,
    required this.title,
    required this.provider,
    required this.repoPath,
    required this.repoName,
    this.tmuxSession,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String provider;
  final String repoPath;
  final String repoName;
  final String? tmuxSession;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'provider': provider,
        'repo_path': repoPath,
        'repo_name': repoName,
        'tmux_session': tmuxSession,
        'status': status,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory AgentDockRecord.fromJson(Map<String, dynamic> json) {
    return AgentDockRecord(
      id: json['id'] as String,
      title: (json['title'] as String?) ?? 'Agent',
      provider: (json['provider'] as String?) ?? AgentProvider.cursor.id,
      repoPath: SshService.normalizeRemotePath(
        (json['repo_path'] as String?) ?? '',
      ),
      repoName: (json['repo_name'] as String?) ?? 'repo',
      tmuxSession: json['tmux_session'] as String?,
      status: (json['status'] as String?) ?? ChatStatus.idle.name,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  factory AgentDockRecord.fromChat(Chat chat, Repo repo) {
    return AgentDockRecord(
      id: chat.id,
      title: chat.title,
      provider: chat.provider.id,
      repoPath: SshService.normalizeRemotePath(repo.remotePath),
      repoName: repo.name,
      tmuxSession: chat.tmuxSession,
      status: chat.status.name,
      createdAt: chat.createdAt,
      updatedAt: chat.updatedAt,
    );
  }

  Chat toChat({required String repoId, int sortOrder = 0}) {
    return Chat(
      id: id,
      repoId: repoId,
      title: title,
      provider: AgentProviderX.fromId(provider),
      tmuxSession: tmuxSession,
      status: ChatStatus.values.firstWhere(
        (s) => s.name == status,
        orElse: () => ChatStatus.idle,
      ),
      sortOrder: sortOrder,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// Sync agents + transcripts via `$HOME/.agentdock` on each SSH host.
class AgentDockService {
  AgentDockService(this._ssh, this._db);

  final SshService _ssh;
  final AppDatabase _db;

  final Map<String, Timer> _pushTimers = {};

  static String normalizePath(String path) => SshService.normalizeRemotePath(path);

  /// Debounced push of one chat's metadata + messages (after local writes).
  void schedulePushChat(String chatId) {
    _pushTimers[chatId]?.cancel();
    _pushTimers[chatId] = Timer(const Duration(seconds: 2), () {
      unawaited(pushChatById(chatId));
    });
  }

  Future<void> pushChatById(String chatId) async {
    try {
      final chat = await _db.getChat(chatId);
      if (chat == null) return;
      final repo = await _db.getRepo(chat.repoId);
      if (repo == null) return;
      final host = await _db.getHost(repo.hostId);
      if (host == null) return;
      final messages = await _db.listMessages(chatId);
      await pushAgent(host: host, chat: chat, repo: repo);
      await pushMessages(host: host, chatId: chatId, messages: messages);
    } catch (e) {
      SafeLog.d('agentdock pushChat failed', e);
    }
  }

  Future<void> pushAgent({
    required Host host,
    required Chat chat,
    required Repo repo,
  }) async {
    final record = AgentDockRecord.fromChat(chat, repo);
    final client = await _ssh.connect(host);
    try {
      final root = await _ensureLayout(client);
      final path = '$root/agents/${chat.id}.json';
      final payload = const JsonEncoder.withIndent('  ').convert(record.toJson());
      await _writeFile(client, path, payload);
    } finally {
      client.close();
    }
  }

  Future<void> deleteAgent({
    required Host host,
    required String chatId,
  }) async {
    final client = await _ssh.connect(host);
    try {
      final root = await _ensureLayout(client);
      await _run(
        client,
        'rm -f ${SshService.shellQuote('$root/agents/$chatId.json')} '
        '${SshService.shellQuote('$root/messages/$chatId.jsonl')}',
      );
    } finally {
      client.close();
    }
  }

  Future<void> pushMessages({
    required Host host,
    required String chatId,
    required List<ChatMessage> messages,
  }) async {
    final client = await _ssh.connect(host);
    try {
      final root = await _ensureLayout(client);
      final path = '$root/messages/$chatId.jsonl';
      final buf = StringBuffer();
      for (final m in messages) {
        buf.writeln(jsonEncode(m.toMap()));
      }
      await _writeFile(client, path, buf.toString());
    } finally {
      client.close();
    }
  }

  Future<List<AgentDockRecord>> pullAgents(Host host) async {
    final client = await _ssh.connect(host);
    try {
      final root = await _ensureLayout(client);
      final listing = await _run(
        client,
        'ls -1 ${SshService.shellQuote('$root/agents')} 2>/dev/null || true',
      );
      final files = listing
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.endsWith('.json'))
          .toList();
      final out = <AgentDockRecord>[];
      for (final name in files) {
        try {
          final raw = await _run(
            client,
            'cat ${SshService.shellQuote('$root/agents/$name')}',
          );
          final trimmed = raw.trim();
          if (trimmed.isEmpty) continue;
          final decoded = jsonDecode(trimmed);
          if (decoded is Map<String, dynamic>) {
            out.add(AgentDockRecord.fromJson(decoded));
          } else if (decoded is Map) {
            out.add(AgentDockRecord.fromJson(Map<String, dynamic>.from(decoded)));
          }
        } catch (e) {
          SafeLog.d('agentdock read $name failed', e);
        }
      }
      return out;
    } finally {
      client.close();
    }
  }

  Future<List<ChatMessage>> pullMessages(Host host, String chatId) async {
    final client = await _ssh.connect(host);
    try {
      final root = await _ensureLayout(client);
      final raw = await _run(
        client,
        'test -f ${SshService.shellQuote('$root/messages/$chatId.jsonl')} && '
        'cat ${SshService.shellQuote('$root/messages/$chatId.jsonl')} || true',
      );
      final messages = <ChatMessage>[];
      for (final line in raw.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        try {
          final decoded = jsonDecode(t);
          if (decoded is Map) {
            final map = Map<String, Object?>.from(decoded);
            messages.add(ChatMessage.fromMap(map));
          }
        } catch (e) {
          SafeLog.d('agentdock message line parse failed', e);
        }
      }
      return messages;
    } finally {
      client.close();
    }
  }

  /// Pull all agents for [host] into local DB (create repos by path as needed).
  Future<int> syncHostCatalog(Host host) async {
    final remote = await pullAgents(host).timeout(const Duration(seconds: 12));
    var merged = 0;
    for (final record in remote) {
      if (record.repoPath.isEmpty) continue;
      final repo = await _db.findOrCreateRepoByPath(
        hostId: host.id,
        remotePath: record.repoPath,
        name: record.repoName,
      );
      final local = await _db.getChat(record.id);
      if (local == null) {
        final sort = await _db.nextChatSortOrder(repo.id);
        await _db.upsertChat(record.toChat(repoId: repo.id, sortOrder: sort));
        merged++;
      } else if (!local.updatedAt.isAfter(record.updatedAt)) {
        await _db.upsertChat(
          record.toChat(repoId: repo.id, sortOrder: local.sortOrder),
        );
        merged++;
      }
    }
    return merged;
  }

  /// Pull messages for [chatId] when remote is newer or local is empty.
  Future<bool> syncChatMessages({
    required Host host,
    required String chatId,
  }) async {
    final local = await _db.listMessages(chatId);
    final remote = await pullMessages(host, chatId)
        .timeout(const Duration(seconds: 12));
    if (remote.isEmpty) return false;

    if (local.isEmpty) {
      await _db.replaceMessages(chatId, remote);
      return true;
    }

    DateTime maxAt(List<ChatMessage> list) {
      var m = list.first.createdAt;
      for (final x in list) {
        if (x.createdAt.isAfter(m)) m = x.createdAt;
      }
      return m;
    }

    if (!maxAt(local).isAfter(maxAt(remote))) {
      await _db.replaceMessages(chatId, remote);
      return true;
    }
    return false;
  }

  /// Best-effort catalog sync for every host (used by Agents refresh).
  Future<String?> syncAllHostsCatalog() async {
    final hosts = await _db.listHosts();
    if (hosts.isEmpty) return null;
    final errors = <String>[];
    var total = 0;
    await Future.wait(hosts.map((host) async {
      try {
        total += await syncHostCatalog(host);
      } catch (e) {
        SafeLog.d('agentdock sync ${host.alias} failed', e);
        errors.add(host.displayLabel);
      }
    }));
    if (errors.isEmpty) {
      return total > 0 ? 'Synced $total agent(s) from remote' : null;
    }
    return 'AgentDock: failed for ${errors.join(', ')}'
        '${total > 0 ? ' · merged $total' : ''}';
  }

  Future<String> _ensureLayout(SSHClient client) async {
    final homeOut = await _run(client, r'printf %s "$HOME"');
    final home = homeOut.trim().isEmpty ? '.' : homeOut.trim();
    final root = '$home/.agentdock';
    await _run(
      client,
      'mkdir -p ${SshService.shellQuote('$root/agents')} '
      '${SshService.shellQuote('$root/messages')}',
    );
    return root;
  }

  Future<void> _writeFile(SSHClient client, String path, String contents) async {
    final b64 = base64Encode(utf8.encode(contents));
    await _run(
      client,
      'printf %s ${SshService.shellQuote(b64)} | base64 -d > ${SshService.shellQuote(path)}',
    );
  }

  Future<String> _run(SSHClient client, String command) async {
    final session = await client.execute(command);
    final out = await utf8.decoder.bind(session.stdout).join();
    final err = await utf8.decoder.bind(session.stderr).join();
    await session.done;
    final code = session.exitCode ?? 0;
    if (code != 0 && err.trim().isNotEmpty) {
      SafeLog.d('agentdock cmd exit=$code stderr=${err.trim()}');
    }
    return out;
  }

  void dispose() {
    for (final t in _pushTimers.values) {
      t.cancel();
    }
    _pushTimers.clear();
  }
}
