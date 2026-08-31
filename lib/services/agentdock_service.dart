import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

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
    this.lastReadAt,
    this.outboundQueue = const [],
    this.acpSessionId,
    this.journalOffset = 0,
    this.modelId,
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

  /// Read watermark, shared through the host so the unread badge is consistent
  /// across every device pointed at the same agent.
  final DateTime? lastReadAt;

  /// User messages queued on another device, waiting for the agent turn.
  final List<ChatMessage> outboundQueue;

  /// Live ACP session id on the remote agent — without this, another device
  /// reconnects as a brand-new conversation even when the transcript matches.
  final String? acpSessionId;

  /// Bytes of the remote ACP journal already consumed on whichever device last
  /// connected, so a handoff does not replay old turns into the transcript.
  final int journalOffset;

  /// Last model id chosen for this chat, re-applied on reconnect.
  final String? modelId;

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
        'last_read_at': lastReadAt?.toIso8601String(),
        if (outboundQueue.isNotEmpty)
          'outbound_queue':
              outboundQueue.map((m) => m.toMap()).toList(growable: false),
        if (acpSessionId != null) 'acp_session_id': acpSessionId,
        if (journalOffset > 0) 'journal_offset': journalOffset,
        if (modelId != null) 'model_id': modelId,
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
      lastReadAt: DateTime.tryParse(json['last_read_at'] as String? ?? ''),
      outboundQueue: _parseOutboundQueue(json['outbound_queue']),
      acpSessionId: json['acp_session_id'] as String?,
      journalOffset: (json['journal_offset'] as int?) ?? 0,
      modelId: json['model_id'] as String?,
    );
  }

  static List<ChatMessage> _parseOutboundQueue(Object? raw) {
    if (raw is! List) return const [];
    final out = <ChatMessage>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        out.add(ChatMessage.fromMap(Map<String, Object?>.from(item)));
      } catch (_) {}
    }
    return out;
  }

  factory AgentDockRecord.fromChat(
    Chat chat,
    Repo repo, {
    List<ChatMessage> outboundQueue = const [],
  }) {
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
      lastReadAt: chat.lastReadAt,
      outboundQueue: outboundQueue,
      acpSessionId: chat.acpSessionId,
      journalOffset: chat.journalOffset,
      modelId: chat.modelId,
    );
  }

  Chat toChat({required String repoId, int sortOrder = 0}) {
    return Chat(
      id: id,
      repoId: repoId,
      title: title,
      provider: AgentProviderX.fromId(provider),
      tmuxSession: tmuxSession,
      acpSessionId: acpSessionId,
      journalOffset: journalOffset,
      modelId: modelId,
      status: ChatStatus.values.firstWhere(
        (s) => s.name == status,
        orElse: () => ChatStatus.idle,
      ),
      sortOrder: sortOrder,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastReadAt: lastReadAt,
    );
  }

  /// Fold session handles from a host record into a local chat row.
  static Chat mergeSessionState(Chat local, AgentDockRecord remote) {
    var acpSessionId = local.acpSessionId;
    if (remote.acpSessionId != null &&
        (acpSessionId == null ||
            !local.updatedAt.isAfter(remote.updatedAt))) {
      acpSessionId = remote.acpSessionId;
    }
    var modelId = local.modelId;
    if (remote.modelId != null &&
        (modelId == null || !local.updatedAt.isAfter(remote.updatedAt))) {
      modelId = remote.modelId;
    }
    return local.copyWith(
      acpSessionId: acpSessionId,
      journalOffset: max(local.journalOffset, remote.journalOffset),
      modelId: modelId,
    );
  }
}

/// Sync agents + transcripts via `$HOME/.agentdock` on each SSH host.
class AgentDockService {
  AgentDockService(this._ssh, this._db);

  final SshService _ssh;
  final AppDatabase _db;

  final Map<String, Timer> _pushTimers = {};

  /// `~/.agentdock` per host — resolving it costs a round trip, so cache it.
  final Map<String, String> _rootCache = {};

  /// Lines of each chat's remote JSONL we have already written, so a push only
  /// sends what is new instead of rewriting the whole transcript every time.
  final Map<String, int> _pushedLines = {};

  /// Content fingerprint of what we last pushed, so an edit to an already-sent
  /// message is noticed even though the line count is unchanged.
  final Map<String, int> _pushedPrefixHash = {};

  static int _hashContents(Iterable<ChatMessage> messages) =>
      Object.hashAll(messages.map((m) => m.content));

  static const _marker = '===AGENTDOCK===';

  static String normalizePath(String path) => SshService.normalizeRemotePath(path);

  /// Debounced push of one chat's metadata + messages (after local writes).
  void schedulePushChat(String chatId) {
    _pushTimers[chatId]?.cancel();
    _pushTimers[chatId] = Timer(const Duration(seconds: 5), () {
      unawaited(pushChatById(chatId));
    });
  }

  /// Push metadata and any new transcript lines in a single round trip.
  Future<void> pushChatById(String chatId) async {
    try {
      final chat = await _db.getChat(chatId);
      if (chat == null) return;
      final repo = await _db.getRepo(chat.repoId);
      if (repo == null) return;
      final host = await _db.getHost(repo.hostId);
      if (host == null) return;
      final messages = await _db.listMessages(chatId);
      final queue = await _db.getOutboundQueue(chatId);

      final root = await _root(host);
      final record = AgentDockRecord.fromChat(chat, repo, outboundQueue: queue);
      final agentJson =
          const JsonEncoder.withIndent('  ').convert(record.toJson());
      final agentPath = '$root/agents/$chatId.json';
      final messagePath = '$root/messages/$chatId.jsonl';

      final pushed = _pushedLines[chatId] ?? 0;
      // A streaming turn is checkpointed in place, so a message we already
      // pushed can change without the count moving. Appending would leave the
      // host holding the truncated copy, so verify the prefix first.
      final prefixHash = _hashContents(messages.take(pushed));
      final canAppend = pushed > 0 &&
          pushed <= messages.length &&
          _pushedPrefixHash[chatId] == prefixHash;
      final slice = canAppend ? messages.sublist(pushed) : messages;

      final buf = StringBuffer();
      for (final m in slice) {
        buf.writeln(jsonEncode(m.toMap()));
      }

      final q = SshService.shellQuote;
      final commands = <String>[
        'mkdir -p ${q('$root/agents')} ${q('$root/messages')}',
        'printf %s ${q(base64Encode(utf8.encode(agentJson)))} | base64 -d > ${q(agentPath)}',
      ];
      if (buf.isNotEmpty) {
        final payload = q(base64Encode(utf8.encode(buf.toString())));
        // Verify the remote line count still matches our watermark before
        // appending; if anything else touched the file, rewrite it whole.
        commands.add(
          canAppend
              ? 'if [ "\$(wc -l < ${q(messagePath)} 2>/dev/null || echo 0)" = "$pushed" ]; then '
                  'printf %s $payload | base64 -d >> ${q(messagePath)}; '
                  'else printf %s ${q(base64Encode(utf8.encode(_encodeAll(messages))))} '
                  '| base64 -d > ${q(messagePath)}; fi'
              : 'printf %s $payload | base64 -d > ${q(messagePath)}',
        );
      }

      await _ssh.exec(host, 'sh -c ${q(commands.join('\n'))}');
      _pushedLines[chatId] = messages.length;
      _pushedPrefixHash[chatId] = _hashContents(messages);
    } catch (e) {
      SafeLog.d('agentdock pushChat failed', e);
      // Force a full rewrite next time; the remote state is now unknown.
      _pushedLines.remove(chatId);
      _pushedPrefixHash.remove(chatId);
    }
  }

  Future<void> pushAgent({
    required Host host,
    required Chat chat,
    required Repo repo,
  }) async {
    final root = await _root(host);
    final record = AgentDockRecord.fromChat(chat, repo);
    final payload = const JsonEncoder.withIndent('  ').convert(record.toJson());
    await _writeFile(host, '$root/agents/${chat.id}.json', payload);
  }

  Future<void> deleteAgent({
    required Host host,
    required String chatId,
  }) async {
    final root = await _root(host);
    _pushedLines.remove(chatId);
    await _ssh.exec(
      host,
      'rm -f ${SshService.shellQuote('$root/agents/$chatId.json')} '
      '${SshService.shellQuote('$root/messages/$chatId.jsonl')}',
    );
  }

  Future<void> pushMessages({
    required Host host,
    required String chatId,
    required List<ChatMessage> messages,
  }) async {
    final root = await _root(host);
    await _writeFile(host, '$root/messages/$chatId.jsonl', _encodeAll(messages));
    _pushedLines[chatId] = messages.length;
  }

  /// Read every agent record for [host] in one round trip.
  Future<List<AgentDockRecord>> pullAgents(Host host) async {
    final root = await _root(host);
    final q = SshService.shellQuote;
    final script = 'for f in ${q('$root/agents')}/*.json; do '
        '[ -f "\$f" ] || continue; '
        'echo ${q(_marker)}; '
        'cat "\$f"; '
        'done';
    final raw = await _ssh.exec(host, 'sh -c ${q(script)}');

    final out = <AgentDockRecord>[];
    for (final chunk in raw.split(_marker)) {
      final trimmed = chunk.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          out.add(AgentDockRecord.fromJson(Map<String, dynamic>.from(decoded)));
        }
      } catch (e) {
        SafeLog.d('agentdock agent record parse failed', e);
      }
    }
    return out;
  }

  Future<List<ChatMessage>> pullMessages(Host host, String chatId) async {
    final root = await _root(host);
    final path = SshService.shellQuote('$root/messages/$chatId.jsonl');
    final raw = await _ssh.exec(host, 'cat $path 2>/dev/null || true');
    final messages = <ChatMessage>[];
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map) {
          messages.add(ChatMessage.fromMap(Map<String, Object?>.from(decoded)));
        }
      } catch (e) {
        SafeLog.d('agentdock message line parse failed', e);
      }
    }
    return messages;
  }

  static String _encodeAll(List<ChatMessage> messages) {
    final buf = StringBuffer();
    for (final m in messages) {
      buf.writeln(jsonEncode(m.toMap()));
    }
    return buf.toString();
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
          AgentDockRecord.mergeSessionState(
            local.copyWith(
              title: record.title,
              status: ChatStatus.values.firstWhere(
                (s) => s.name == record.status,
                orElse: () => local.status,
              ),
              updatedAt: record.updatedAt,
            ),
            record,
          ),
        );
        merged++;
      } else {
        // Local is newer for title/status, but session handles may have been
        // pushed by another device without bumping our updatedAt.
        final withSession = AgentDockRecord.mergeSessionState(local, record);
        if (withSession.acpSessionId != local.acpSessionId ||
            withSession.journalOffset != local.journalOffset ||
            withSession.modelId != local.modelId) {
          await _db.upsertChat(withSession);
          merged++;
        }
      }
      // Read state is its own axis: another device may have read the chat
      // without being the newest writer of the agent record itself.
      if (record.lastReadAt != null) {
        await _db.markChatRead(record.id, at: record.lastReadAt);
      }
      await _db.setOutboundQueue(record.id, record.outboundQueue);
      try {
        await syncChatMessages(host: host, chatId: record.id);
      } catch (e) {
        SafeLog.d('agentdock message sync ${record.id} failed', e);
      }
    }
    return merged;
  }

  /// Fold the remote transcript for [chatId] into the local one.
  ///
  /// Union by message id rather than picking a winner: the phone may hold
  /// messages written offline that the host has never seen, and the host may
  /// hold messages produced by an agent that ran while the phone was away.
  /// Both belong in the transcript.
  Future<bool> syncChatMessages({
    required Host host,
    required String chatId,
  }) async {
    final remote = await pullMessages(host, chatId)
        .timeout(const Duration(seconds: 12));
    if (remote.isEmpty) return false;
    final changed = await _db.mergeMessages(chatId, remote);
    if (changed > 0) {
      // Remote gained lines we did not have, so our append watermark is stale.
      _pushedLines.remove(chatId);
    }
    return changed > 0;
  }

  /// Pull one agent record from the host and merge session handles locally.
  ///
  /// Called before connecting on a second device so it resumes the same ACP
  /// conversation the first device opened, not a blank session.
  Future<bool> syncChatRecord({
    required Host host,
    required String chatId,
  }) async {
    final record = await pullAgentRecord(host, chatId)
        .timeout(const Duration(seconds: 8));
    if (record == null) return false;
    final local = await _db.getChat(chatId);
    if (local == null) return false;
    final merged = AgentDockRecord.mergeSessionState(local, record);
    if (merged.acpSessionId == local.acpSessionId &&
        merged.journalOffset == local.journalOffset &&
        merged.modelId == local.modelId) {
      return false;
    }
    await _db.upsertChat(merged);
    return true;
  }

  Future<AgentDockRecord?> pullAgentRecord(Host host, String chatId) async {
    final root = await _root(host);
    final path = SshService.shellQuote('$root/agents/$chatId.json');
    final raw = await _ssh.exec(host, 'cat $path 2>/dev/null || true');
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return AgentDockRecord.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      SafeLog.d('agentdock agent record parse failed', e);
    }
    return null;
  }

  /// Push pending chat writes immediately — used when the app backgrounds so
  /// another device can pull the latest transcript from the host.
  Future<void> flushPendingPushes() async {
    for (final timer in _pushTimers.values) {
      timer.cancel();
    }
    _pushTimers.clear();
    final chats = await _db.listAllChats();
    for (final chat in chats) {
      try {
        await pushChatById(chat.id);
      } catch (e) {
        SafeLog.d('agentdock flush push ${chat.id} failed', e);
      }
    }
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

  Future<String> _root(Host host) async {
    final cached = _rootCache[host.id];
    if (cached != null) return cached;
    final home = await _ssh.remoteHomeDirectory(host);
    final root = '${home == '/' ? '' : home}/.agentdock';
    await _ssh.exec(
      host,
      'mkdir -p ${SshService.shellQuote('$root/agents')} '
      '${SshService.shellQuote('$root/messages')}',
    );
    _rootCache[host.id] = root;
    return root;
  }

  Future<void> _writeFile(Host host, String path, String contents) async {
    final b64 = base64Encode(utf8.encode(contents));
    await _ssh.exec(
      host,
      'printf %s ${SshService.shellQuote(b64)} | base64 -d > ${SshService.shellQuote(path)}',
    );
  }

  void dispose() {
    for (final t in _pushTimers.values) {
      t.cancel();
    }
    _pushTimers.clear();
  }
}
