import 'package:uuid/uuid.dart';

import '../data/local/app_database.dart';
import '../data/models/chat.dart';
import '../data/models/host.dart';
import '../data/models/repo.dart';
import '../data/secure/safe_log.dart';
import 'adsm_client.dart';
import 'agent_runtime_host.dart';
import 'agentdock_service.dart';

/// Branch a chat into a second agent that starts with the same conversation.
///
/// The fork is a new chat on the same repo, agent and model, holding a copy of
/// the source's durable transcript — but deliberately no ACP session id. It
/// opens its own session and rebuilds context from that transcript on its
/// first prompt, so the two agents share a past and nothing else: neither can
/// see the other's later turns, and the source keeps running untouched.
///
/// The copy happens on the host, which already holds the transcript, so
/// forking a year-long chat uploads nothing.
class ChatForkService {
  ChatForkService({
    required AdsmBridgePool pool,
    required AppDatabase db,
    required AgentDockService dock,
  }) : _pool = pool,
       _db = db,
       _dock = dock;

  final AdsmBridgePool _pool;
  final AppDatabase _db;
  final AgentDockService _dock;

  /// `Fix login` → `Fix login (fork)`, then `(fork 2)`, `(fork 3)`, … so a
  /// chat forked repeatedly stays readable in the list.
  static String forkTitle(String source, Set<String> taken) {
    final base = source.trim().isEmpty ? 'Agent' : source.trim();
    final stripped = base.replaceFirst(RegExp(r'\s*\(fork(?: \d+)?\)$'), '');
    var candidate = '$stripped (fork)';
    var n = 2;
    while (taken.contains(candidate)) {
      candidate = '$stripped (fork $n)';
      n++;
    }
    return candidate;
  }

  /// Fork [source] into a new chat and return it.
  ///
  /// [throughMessageId] forks the conversation up to and including that
  /// message, leaving later turns behind — branching from a point in the
  /// middle rather than from the end.
  Future<Chat> fork({
    required Host host,
    required Repo repo,
    required Chat source,
    String? throughMessageId,
  }) async {
    // The host copies what it has, so flush anything this device has not
    // pushed yet — otherwise the fork loses the newest turns. A live chat's
    // transcript is already owned by the host, and this is a no-op for it.
    await _dock.pushChatById(source.id);

    final chatId = const Uuid().v4();
    final client = await _pool.acquire(host);
    try {
      await client.request('chats.fork', {
        'fromChatId': source.id,
        'chatId': chatId,
        if (throughMessageId != null) 'throughMessageId': throughMessageId,
      }, timeout: const Duration(seconds: 90));
    } finally {
      await _pool.releaseClient(host.id, client);
    }

    final now = DateTime.now();
    final titles = (await _db.listChats(repo.id)).map((c) => c.title).toSet();
    final chat = Chat(
      id: chatId,
      repoId: source.repoId,
      title: forkTitle(source.title, titles),
      provider: source.provider,
      // Created lazily on first connect; recorded now so the list can show it.
      tmuxSession: AgentRuntimeHost.sessionNameForChat(chatId),
      // Same model, so the fork answers the way the source did.
      modelId: source.modelId,
      status: ChatStatus.idle,
      sortOrder: await _db.nextChatSortOrder(source.repoId),
      // You just made it — none of the copied history is unread.
      lastReadAt: now,
      titleUpdatedAt: now,
      createdAt: now,
      updatedAt: now,
    );
    await _db.upsertChat(chat);

    // Pull the copy back so the fork opens showing its inherited history. The
    // host minted the message ids, so both sides agree on them from the start.
    try {
      final rows = await _dock.pullMessages(host, chatId);
      if (rows.isNotEmpty) await _db.mergeMessages(chatId, rows);
    } catch (e) {
      // Not fatal: the fork and its transcript exist on the host, and the
      // agent reads its context from there, not from this device.
      SafeLog.d('pulling forked transcript failed', e);
    }

    // The daemon wrote a bare record (cwd, agent, model); give it the title
    // and repo so the fork looks right on your other devices too.
    await _dock.pushAgent(host: host, chat: chat, repo: repo);
    return chat;
  }
}
