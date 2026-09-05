import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';

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
    this.titleUpdatedAt,
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

  /// When [title] last changed. Independent of [updatedAt] so ADSM status
  /// patches cannot roll a rename back on catalog sync.
  final DateTime? titleUpdatedAt;

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
        if (titleUpdatedAt != null)
          'title_updated_at': titleUpdatedAt!.toIso8601String(),
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
      titleUpdatedAt:
          DateTime.tryParse(json['title_updated_at'] as String? ?? ''),
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
      titleUpdatedAt: chat.titleUpdatedAt,
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
      titleUpdatedAt: titleUpdatedAt ?? updatedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastReadAt: lastReadAt,
    );
  }

  /// Pick the newer title using [titleUpdatedAt], not [updatedAt].
  ///
  /// When neither side has a title clock (legacy host JSON), keep the local
  /// title so an ADSM `updated_at` bump cannot resurrect an old name.
  static String mergedTitle(Chat local, AgentDockRecord remote) {
    final lAt = local.titleUpdatedAt;
    final rAt = remote.titleUpdatedAt;
    if (rAt != null && (lAt == null || !lAt.isAfter(rAt))) {
      return remote.title;
    }
    return local.title;
  }

  static DateTime? mergedTitleUpdatedAt(Chat local, AgentDockRecord remote) {
    final lAt = local.titleUpdatedAt;
    final rAt = remote.titleUpdatedAt;
    if (rAt != null && (lAt == null || !lAt.isAfter(rAt))) {
      return rAt;
    }
    return lAt ?? rAt;
  }

  /// Apply the remote title when its title clock is ahead of local.
  static Chat mergeTitle(Chat local, AgentDockRecord remote) {
    final title = mergedTitle(local, remote);
    final titleAt = mergedTitleUpdatedAt(local, remote);
    if (title == local.title && titleAt == local.titleUpdatedAt) {
      return local;
    }
    return local.copyWith(title: title, titleUpdatedAt: titleAt);
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

  /// Called when a local chat is removed because the host says it was deleted.
  void Function(String chatId)? onChatRemoved;

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

  /// Push immediately — used after rename so other devices see the name before
  /// the next catalog sync, without waiting for the debounce.
  void pushChatNow(String chatId) {
    _pushTimers[chatId]?.cancel();
    _pushTimers.remove(chatId);
    unawaited(pushChatById(chatId));
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

      // Another device may have deleted this agent — honor the tombstone and
      // drop the local copy instead of resurrecting it on the host.
      if (await _isDeletedOnHost(host, chatId)) {
        await _db.deleteChat(chatId);
        _pushedLines.remove(chatId);
        _pushedPrefixHash.remove(chatId);
        onChatRemoved?.call(chatId);
        return;
      }

      final localMessages = await _db.listMessages(chatId);
      final queue = await _db.getOutboundQueue(chatId);

      final root = await _root(host);
      final record = AgentDockRecord.fromChat(chat, repo, outboundQueue: queue);
      final agentJson =
          const JsonEncoder.withIndent('  ').convert(record.toJson());
      final agentPath = '$root/agents/$chatId.json';
      final messagePath = '$root/messages/$chatId.jsonl';
      final q = SshService.shellQuote;

      final pushed = _pushedLines[chatId] ?? 0;
      // A streaming turn is checkpointed in place, so a message we already
      // pushed can change without the count moving. Appending would leave the
      // host holding the truncated copy, so verify the prefix first.
      final prefixHash = _hashContents(localMessages.take(pushed));
      final canAppend = pushed > 0 &&
          pushed <= localMessages.length &&
          _pushedPrefixHash[chatId] == prefixHash;

      // Full rewrite must union with the host file — ADSM may have appended
      // turns the phone has not pulled yet, and a blind overwrite would drop them.
      var messages = localMessages;
      if (!canAppend) {
        try {
          final remote = await pullMessages(host, chatId);
          if (remote.isNotEmpty) {
            messages = _unionMessages(remote, localMessages);
            if (messages.length != localMessages.length) {
              await _db.mergeMessages(chatId, remote);
            }
          }
        } catch (e) {
          SafeLog.d('agentdock merge remote before push failed', e);
        }
      }
      final slice = canAppend ? localMessages.sublist(pushed) : messages;

      final buf = StringBuffer();
      for (final m in slice) {
        buf.writeln(jsonEncode(m.toMap()));
      }

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
    final q = SshService.shellQuote;
    // Creating/updating clears any delete tombstone from another device.
    await _ssh.exec(
      host,
      'rm -f ${q('$root/deleted/${chat.id}.json')} && '
      'mkdir -p ${q('$root/agents')} && '
      'printf %s ${q(base64Encode(utf8.encode(payload)))} | base64 -d > '
      '${q('$root/agents/${chat.id}.json')}',
    );
  }

  Future<void> deleteAgent({
    required Host host,
    required String chatId,
  }) async {
    final root = await _root(host);
    _pushedLines.remove(chatId);
    _pushedPrefixHash.remove(chatId);
    final q = SshService.shellQuote;
    final tombstone = jsonEncode({
      'id': chatId,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    });
    final deleteRpc = jsonEncode({
      'id': 1,
      'method': 'agents.delete',
      'params': {'chatId': chatId},
    });
    // Tombstone first so another device cannot resurrect via push, then stop
    // any ADSM worker and remove the live record + transcript.
    await _ssh.exec(
      host,
      'mkdir -p ${q('$root/deleted')} ${q('$root/agents')} ${q('$root/messages')} && '
      'printf %s ${q(base64Encode(utf8.encode(tombstone)))} | base64 -d > '
      '${q('$root/deleted/$chatId.json')} && '
      'export PATH="\$HOME/.local/bin:\$PATH"; '
      'if command -v agentdock-adsm >/dev/null 2>&1; then '
      'printf %s ${q(deleteRpc)} | agentdock-adsm client >/dev/null 2>&1 || true; '
      'fi; '
      'rm -f ${q('$root/agents/$chatId.json')} '
      '${q('$root/messages/$chatId.jsonl')}',
    );
  }

  /// Agent ids tombstoned under `~/.agentdock/deleted/` (deleted on any device).
  Future<Set<String>> pullDeletedAgentIds(Host host) async {
    final root = await _root(host);
    final q = SshService.shellQuote;
    final script = 'for f in ${q('$root/deleted')}/*.json; do '
        '[ -f "\$f" ] || continue; '
        'echo ${q(_marker)}; '
        'cat "\$f"; '
        'done';
    final raw = await _ssh.exec(host, 'sh -c ${q(script)}');
    final out = <String>{};
    for (final chunk in raw.split(_marker)) {
      final trimmed = chunk.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final id = decoded['id']?.toString();
          if (id != null && id.isNotEmpty) out.add(id);
        }
      } catch (e) {
        SafeLog.d('agentdock deleted record parse failed', e);
      }
    }
    return out;
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

  /// Union by id (longer body wins), sorted by createdAt then id.
  static List<ChatMessage> _unionMessages(
    List<ChatMessage> a,
    List<ChatMessage> b,
  ) {
    final byId = <String, ChatMessage>{};
    for (final m in [...a, ...b]) {
      final prev = byId[m.id];
      if (prev == null || m.content.length >= prev.content.length) {
        byId[m.id] = m;
      }
    }
    final out = byId.values.toList()
      ..sort((x, y) {
        final c = x.createdAt.compareTo(y.createdAt);
        if (c != 0) return c;
        return x.id.compareTo(y.id);
      });
    return out;
  }

  /// Test seam for [_unionMessages].
  @visibleForTesting
  static List<ChatMessage> unionMessagesForTest(
    List<ChatMessage> a,
    List<ChatMessage> b,
  ) =>
      _unionMessages(a, b);

  /// Pull all agents for [host] into local DB (create repos by path as needed).
  ///
  /// Also removes local chats that were deleted on another device (tombstones
  /// under `~/.agentdock/deleted/`).
  Future<int> syncHostCatalog(Host host) async {
    final remote = await pullAgents(host).timeout(const Duration(seconds: 12));
    final deletedIds = await pullDeletedAgentIds(host)
        .timeout(const Duration(seconds: 8), onTimeout: () => <String>{});
    var merged = 0;
    final remoteIds = <String>{};
    for (final record in remote) {
      if (record.repoPath.isEmpty) continue;
      // Prefer deletion: a tombstone wins over a leftover/resurrected JSON.
      if (deletedIds.contains(record.id)) {
        unawaited(_reapResurrectedAgent(host, record.id));
        continue;
      }
      remoteIds.add(record.id);
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
            AgentDockRecord.mergeTitle(
              local.copyWith(
                status: ChatStatus.values.firstWhere(
                  (s) => s.name == record.status,
                  orElse: () => local.status,
                ),
                updatedAt: record.updatedAt,
              ),
              record,
            ),
            record,
          ),
        );
        merged++;
      } else {
        // Local is newer for status, but title / session handles may still
        // have been updated on another device.
        final withTitle = AgentDockRecord.mergeTitle(local, record);
        final withSession =
            AgentDockRecord.mergeSessionState(withTitle, record);
        if (withSession.title != local.title ||
            withSession.titleUpdatedAt != local.titleUpdatedAt ||
            withSession.acpSessionId != local.acpSessionId ||
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

    merged += await _pruneDeletedLocals(
      host: host,
      deletedIds: deletedIds,
      remoteIds: remoteIds,
    );
    return merged;
  }

  /// Drop local chats deleted remotely, and any leftover row whose host record
  /// is gone (with a short grace window for brand-new unpushed agents).
  Future<int> _pruneDeletedLocals({
    required Host host,
    required Set<String> deletedIds,
    required Set<String> remoteIds,
  }) async {
    final repos = await _db.listRepos(hostId: host.id);
    var pruned = 0;
    final now = DateTime.now();
    for (final repo in repos) {
      final chats = await _db.listChats(repo.id);
      for (final chat in chats) {
        final tombstoned = deletedIds.contains(chat.id);
        final missing = !remoteIds.contains(chat.id);
        if (!tombstoned && !missing) continue;
        if (!tombstoned && missing) {
          // Brand-new local create may not have landed on the host yet.
          final age = now.difference(chat.createdAt);
          if (age < const Duration(minutes: 2)) continue;
        }
        await _db.deleteChat(chat.id);
        _pushedLines.remove(chat.id);
        _pushedPrefixHash.remove(chat.id);
        onChatRemoved?.call(chat.id);
        pruned++;
      }
    }
    return pruned;
  }

  Future<bool> _isDeletedOnHost(Host host, String chatId) async {
    final root = await _root(host);
    final path = SshService.shellQuote('$root/deleted/$chatId.json');
    final raw = await _ssh.exec(host, 'test -f $path && echo YES || echo NO');
    return raw.trim() == 'YES';
  }

  /// Remove a host agent record that came back after a delete tombstone.
  Future<void> _reapResurrectedAgent(Host host, String chatId) async {
    try {
      final root = await _root(host);
      final q = SshService.shellQuote;
      await _ssh.exec(
        host,
        'rm -f ${q('$root/agents/$chatId.json')} '
        '${q('$root/messages/$chatId.jsonl')}',
      );
    } catch (e) {
      SafeLog.d('reap resurrected agent $chatId failed', e);
    }
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
  /// conversation the first device opened, not a blank session. Also picks up
  /// a rename that landed on the host from another device.
  Future<bool> syncChatRecord({
    required Host host,
    required String chatId,
  }) async {
    final record = await pullAgentRecord(host, chatId)
        .timeout(const Duration(seconds: 8));
    if (record == null) return false;
    final local = await _db.getChat(chatId);
    if (local == null) return false;
    final merged = AgentDockRecord.mergeSessionState(
      AgentDockRecord.mergeTitle(local, record),
      record,
    );
    if (merged.title == local.title &&
        merged.titleUpdatedAt == local.titleUpdatedAt &&
        merged.acpSessionId == local.acpSessionId &&
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
      '${SshService.shellQuote('$root/messages')} '
      '${SshService.shellQuote('$root/deleted')}',
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
