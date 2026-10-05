import 'dart:async';
import 'dart:collection';

import 'package:uuid/uuid.dart';

import '../data/local/app_database.dart';
import '../data/models/agent_provider.dart';
import '../data/models/archon_chat.dart';
import '../data/models/chat.dart';
import '../data/models/host.dart';
import '../data/models/repo.dart';
import '../data/secure/safe_log.dart';
import 'adsm_client.dart';

/// The slice of [AdsmClient] the relay uses.
///
/// Named as an interface so the routing rules can be exercised without an SSH
/// bridge, a daemon or a device — everything below this line is pure logic.
abstract class ArchonRelayChannel {
  Stream<Map<String, dynamic>> get events;

  bool get isOpen;

  /// Completes when the channel ends (triggers a reconnect).
  Future<void> get done;

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 60),
  });
}

/// Borrow a channel to [host]. Paired with an [ArchonChannelClose].
typedef ArchonChannelOpen = Future<ArchonRelayChannel> Function(Host host);

/// Give back a channel from [ArchonChannelOpen].
typedef ArchonChannelClose =
    Future<void> Function(Host host, ArchonRelayChannel channel);

/// Start [chat]'s worker on [host] (normally `ChatConnectCoordinator.ensure`).
///
/// Injected rather than reached for: starting a worker needs the provider API
/// key from `SecureStore`, which is a file read this service must not own.
typedef ArchonPrepareChat = Future<void> Function(Host host, Chat chat);

/// This app acting as Archon's route to the user's other hosts.
///
/// Archon manages agents everywhere but runs on one host, and it has no SSH
/// credentials for the others — those are the user's and live here. So the app
/// volunteers as the route: it subscribes to Archon's host with
/// `session.subscribe {relay: true}`, and the daemon hands it the calls Archon
/// cannot make itself. Each arrives as an `archon_request` event and is
/// answered with `archon.reply`.
///
/// The daemon gives up on a call after 60s, so every request is answered —
/// with an error if that is all there is to say. A relay that goes quiet looks
/// to Archon exactly like a phone in a tunnel, and it stops trusting the route.
class ArchonRelayService {
  ArchonRelayService({
    required AppDatabase db,
    required Future<Host?> Function() archonHost,
    required ArchonChannelOpen open,
    ArchonChannelClose? close,
    ArchonPrepareChat? prepareChat,
    Duration retryDelay = const Duration(seconds: 5),
    Duration actionBudget = const Duration(seconds: 45),
  }) : _db = db,
       _archonHost = archonHost,
       _open = open,
       _close = close,
       _prepareChat = prepareChat,
       _retryDelay = retryDelay,
       _actionBudget = actionBudget;

  /// The relay over the shared per-host SSH bridges — how the app wires it.
  factory ArchonRelayService.overBridgePool({
    required AdsmBridgePool pool,
    required AppDatabase db,
    required Future<Host?> Function() archonHost,
    ArchonPrepareChat? prepareChat,
  }) => ArchonRelayService(
    db: db,
    archonHost: archonHost,
    open: (host) async => _AdsmRelayChannel(await pool.acquire(host)),
    close: (host, channel) async {
      if (channel is _AdsmRelayChannel) {
        await pool.releaseClient(host.id, channel.client);
      }
    },
    prepareChat: prepareChat,
  );

  final AppDatabase _db;

  /// Where Archon lives right now — re-read on [refreshHost] because Archon
  /// can be moved to another host while the app is open.
  final Future<Host?> Function() _archonHost;

  final ArchonChannelOpen _open;
  final ArchonChannelClose? _close;
  final ArchonPrepareChat? _prepareChat;
  final Duration _retryDelay;

  _RelayLink? _link;
  bool _running = false;
  Completer<void> _subscribed = Completer<void>();

  /// Answered call ids, oldest first. Kept so a call redelivered after a
  /// reconnect is not performed (and paid for) a second time.
  final Set<String> _answered = {};
  final Queue<String> _answeredOrder = Queue<String>();
  static const _answeredMemory = 256;

  /// Every action must finish inside the daemon's 60s patience, with room for
  /// the reply to travel back — a late answer is worth less than a fast "no".
  final Duration _actionBudget;

  /// One unreachable host must not eat the whole `agents` budget.
  static const _perHostTimeout = Duration(seconds: 12);

  bool get running => _running;

  /// True while the route is live and Archon can actually be served.
  bool get isSubscribed => _link?.channel?.isOpen ?? false;

  /// Completes once the relay subscription is established (again after
  /// [stop]). Lets callers — and tests — wait for a usable route.
  Future<void> get subscribed => _subscribed.future;

  /// Volunteer as Archon's route. Returns without waiting for the handshake:
  /// the link retries on its own, and the app must not stall on a dead host.
  Future<void> start() async {
    _running = true;
    await refreshHost();
  }

  Future<void> stop() async {
    _running = false;
    final link = _link;
    _link = null;
    await link?.close();
    if (_subscribed.isCompleted) _subscribed = Completer<void>();
  }

  /// Point the route at the host Archon currently runs on.
  ///
  /// Archon moving hosts is a normal operation, and the old host's daemon has
  /// no Archon to relay for — so the subscription follows rather than lingers.
  Future<void> refreshHost() async {
    if (!_running) return;
    Host? host;
    try {
      host = await _archonHost();
    } catch (e) {
      SafeLog.d('archon relay host lookup failed', e);
      return;
    }
    if (!_running) return;
    final current = _link;
    if (current != null && current.host.id == host?.id) return;
    _link = null;
    await current?.close();
    if (host == null || !_running) return;
    if (_subscribed.isCompleted) _subscribed = Completer<void>();
    _link = _RelayLink(this, host)..run();
  }

  void _onSubscribed() {
    if (!_subscribed.isCompleted) _subscribed.complete();
  }

  /// One relayed call. Claimed before it runs, so a duplicate delivery is
  /// dropped instead of prompting an agent twice.
  Future<void> _onEvent(_RelayLink link, Map<String, dynamic> params) async {
    if (params['kind']?.toString() != 'archon_request') return;
    final callId = params['callId']?.toString() ?? '';
    // Without a call id there is no one to answer; the daemon never sends one.
    if (callId.isEmpty || !_claim(callId)) return;
    final action = params['action']?.toString() ?? '';
    final raw = params['payload'];
    final payload = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};

    Object? result;
    var ok = true;
    String? error;
    String? message;
    try {
      result = await _perform(action, payload).timeout(_actionBudget);
    } on _RelayRefusal catch (r) {
      ok = false;
      error = r.error;
      message = r.message;
    } on TimeoutException {
      ok = false;
      error = 'timeout';
      message = 'The app could not finish "$action" in time.';
    } catch (e) {
      SafeLog.d('archon relay "$action" failed', e);
      ok = false;
      error = 'failed';
      message = SafeLog.redact('$e');
    }
    await link.reply(
      callId,
      ok: ok,
      result: result,
      error: error,
      message: message,
    );
  }

  /// False when [callId] was already taken on — see [_answered].
  bool _claim(String callId) {
    if (!_answered.add(callId)) return false;
    _answeredOrder.add(callId);
    while (_answeredOrder.length > _answeredMemory) {
      _answered.remove(_answeredOrder.removeFirst());
    }
    return true;
  }

  Future<Object?> _perform(String action, Map<String, dynamic> payload) {
    switch (action) {
      case 'routes':
        return _routes();
      case 'agents':
        return _agents();
      case 'read':
        return _read(payload);
      case 'prompt':
        return _prompt(payload);
      default:
        // An older app meeting a newer Archon. Saying so beats timing out:
        // Archon can pick another way round instead of waiting a minute.
        throw _RelayRefusal(
          'unknown_action',
          'This app cannot do "$action". '
          'It can do: routes, agents, read, prompt.',
        );
    }
  }

  /// What this route can reach, so Archon knows a host exists before it asks.
  Future<Object?> _routes() async {
    final hosts = await _db.listHosts();
    return {
      'hosts': [
        for (final h in hosts)
          {'hostId': h.id, 'host': h.displayLabel, 'endpoint': h.endpointLabel},
      ],
    };
  }

  /// Every agent on every host this app can see.
  ///
  /// Built from the app's own catalog and enriched with each host's live
  /// `agents.list`, rather than from the hosts alone: an idle chat that no
  /// daemon has a worker for is still an agent Archon can send work to, and a
  /// host that is asleep should cost Archon a stale status, not the answer.
  Future<Object?> _agents() async {
    final hosts = await _db.listHosts();
    final repos = {for (final r in await _db.listRepos()) r.id: r};
    final chats = await _db.listAllChats();

    final agents = <Map<String, Object?>>[];
    final unreachable = <Map<String, Object?>>[];
    for (final host in hosts) {
      var live = <String, Map<String, dynamic>>{};
      try {
        live = await _liveAgents(host);
      } catch (e) {
        SafeLog.d('archon relay agents ${host.alias} unreachable', e);
        unreachable.add({
          'hostId': host.id,
          'host': host.displayLabel,
          'error': SafeLog.redact('$e'),
        });
      }
      for (final chat in chats) {
        final repo = repos[chat.repoId];
        if (repo == null || repo.hostId != host.id) continue;
        agents.add(_agentEntry(host, chat, repo, live.remove(chat.id)));
      }
      // Started on the host itself, or on a device this one has not synced
      // with — Archon can still reach it, so it belongs in the list.
      for (final entry in live.entries) {
        agents.add({
          'hostId': host.id,
          'host': host.displayLabel,
          'chatId': entry.key,
          'title': entry.value['cwd']?.toString(),
          'cwd': entry.value['cwd']?.toString(),
          'provider': entry.value['provider']?.toString(),
          'status': entry.value['status']?.toString() ?? 'unknown',
          'live': true,
          'knownToApp': false,
        });
      }
    }
    return {'agents': agents, 'unreachable': unreachable};
  }

  Map<String, Object?> _agentEntry(
    Host host,
    Chat chat,
    Repo repo,
    Map<String, dynamic>? live,
  ) => {
    'hostId': host.id,
    'host': host.displayLabel,
    'chatId': chat.id,
    'title': chat.title,
    'cwd': live?['cwd']?.toString() ?? repo.remotePath,
    'repo': repo.name,
    'provider': live?['provider']?.toString() ?? chat.provider.id,
    // A cached status is flagged as such: the host may have moved on since.
    'status': live?['status']?.toString() ?? chat.status.name,
    'live': live != null,
    'knownToApp': true,
    if (live?['lastError'] != null) 'lastError': live?['lastError'].toString(),
    'updatedAt': chat.updatedAt.toIso8601String(),
    'isArchon': chat.id == kArchonChatId,
  };

  /// Live worker snapshots on [host], keyed by chat id.
  Future<Map<String, Map<String, dynamic>>> _liveAgents(Host host) async {
    final channel = await _open(host).timeout(_perHostTimeout);
    try {
      final result = await channel.request(
        'agents.list',
        {},
        timeout: _perHostTimeout,
      );
      final raw = result['agents'];
      final out = <String, Map<String, dynamic>>{};
      if (raw is! List) return out;
      for (final item in raw) {
        if (item is! Map) continue;
        final snap = Map<String, dynamic>.from(item);
        final id = snap['chatId']?.toString() ?? '';
        if (id.isNotEmpty) out[id] = snap;
      }
      return out;
    } finally {
      await _release(host, channel);
    }
  }

  /// Give an agent on another host work.
  Future<Object?> _prompt(Map<String, dynamic> payload) async {
    final hostId = payload['hostId']?.toString() ?? '';
    final chatId = payload['chatId']?.toString() ?? '';
    final text = payload['text']?.toString() ?? '';
    if (chatId.isEmpty || text.trim().isEmpty) {
      throw const _RelayRefusal(
        'bad_request',
        'A prompt needs a chatId and some text.',
      );
    }
    if (chatId == kArchonChatId) {
      // Archon relaying a prompt to itself is a loop that bills every lap.
      throw const _RelayRefusal(
        'refused',
        'That is Archon\'s own chat — it cannot prompt itself.',
      );
    }

    final chat = await _db.getChat(chatId);
    final host = await _hostFor(hostId, chat);
    if (host == null) {
      throw _RelayRefusal(
        'unknown_host',
        hostId.isEmpty
            ? 'No hostId given, and this app does not know chat $chatId.'
            : 'This app has no host "$hostId".',
      );
    }

    // Every device derives the message from this id, so the prompt Archon
    // sends is one row everywhere rather than one per device that sees it.
    final target = host;
    final messageId = const Uuid().v4();
    final createdAt = DateTime.now().toUtc().toIso8601String();
    Future<void> send() async {
      final channel = await _open(target).timeout(_perHostTimeout);
      try {
        await channel.request('session.prompt', {
          'chatId': chatId,
          'text': text,
          'userMessageId': messageId,
          'userCreatedAt': createdAt,
        }, timeout: const Duration(seconds: 30));
      } finally {
        await _release(target, channel);
      }
    }

    try {
      await send();
    } catch (e) {
      final prepare = _prepareChat;
      if (chat == null || prepare == null || !_needsWorker(e)) rethrow;
      // The host has no worker for this chat — usual for an agent nobody has
      // opened since the daemon restarted. Start it and deliver once.
      await prepare(target, chat);
      await send();
    }
    return {
      'hostId': target.id,
      'host': target.displayLabel,
      'chatId': chatId,
      'messageId': messageId,
      'delivered': true,
    };
  }

  /// The host a chat actually lives on.
  ///
  /// Archon may know the chat but guess the host id wrong; the chat's own repo
  /// is authoritative and saves a pointless round trip.
  Future<Host?> _hostFor(String hostId, Chat? chat) async {
    final named = hostId.isEmpty ? null : await _db.getHost(hostId);
    if (named != null) return named;
    if (chat == null) return null;
    final repo = await _db.getRepo(chat.repoId);
    return repo == null ? null : await _db.getHost(repo.hostId);
  }

  /// An agent's recent transcript, from whichever host it lives on.
  ///
  /// Archon could already send a remote agent work but had no way to see what
  /// came back, so taking a chat over meant prompting into the dark — `archon
  /// read` only ever asked the daemon Archon itself runs on, which holds
  /// nothing for a chat on another host.
  ///
  /// The live pull wins; the app's own synced copy is the fallback, so a host
  /// that is asleep costs staleness rather than the whole answer. `source`
  /// always says which one it got: acting on a stale transcript is a different
  /// risk from acting on a live one, and Archon should be able to tell.
  Future<Object?> _read(Map<String, dynamic> payload) async {
    final chatId = payload['chatId']?.toString() ?? '';
    if (chatId.isEmpty) {
      throw const _RelayRefusal('bad_request', 'A read needs a chatId.');
    }
    final limit = (int.tryParse('${payload['limit'] ?? ''}') ?? 40).clamp(
      1,
      400,
    );

    final chat = await _db.getChat(chatId);
    final host = await _hostFor(payload['hostId']?.toString() ?? '', chat);
    if (host == null) {
      throw _RelayRefusal(
        'unknown_host',
        'This app does not know which host chat $chatId lives on.',
      );
    }

    Map<String, Object?> envelope(String source, int count) => {
      'hostId': host.id,
      'host': host.displayLabel,
      'chatId': chatId,
      'title': chat?.title,
      'source': source,
      'count': count,
    };

    String? stale;
    try {
      final channel = await _open(host).timeout(_perHostTimeout);
      try {
        final result = await channel.request('transcript.pull', {
          'chatId': chatId,
          'limit': limit,
        }, timeout: _perHostTimeout);
        final messages = _transcriptRows(result['messages']);
        if (messages.isNotEmpty) {
          return {...envelope('host', messages.length), 'messages': messages};
        }
        // Reaching the host and finding nothing is a real answer about the
        // host, not a failure — but the app may still hold the history, so
        // it is worth looking before reporting an empty chat.
        stale = 'the host has no stored transcript for that chat';
      } finally {
        await _release(host, channel);
      }
    } catch (e) {
      SafeLog.d('archon relay read ${host.alias} live pull failed', e);
      stale = SafeLog.redact('$e');
    }

    final local = await _db.listRecentMessages(chatId, limit: limit);
    return {
      ...envelope('app', local.length),
      'staleBecause': stale,
      'messages': [
        for (final m in local)
          {
            'id': m.id,
            'role': m.role.name,
            'text': m.content,
            'createdAt': m.createdAt.toUtc().toIso8601String(),
          },
      ],
    };
  }

  /// Normalise a host transcript into the shape Archon reads, so a live pull
  /// and the app's own copy are indistinguishable to whatever consumes them.
  List<Map<String, Object?>> _transcriptRows(Object? raw) {
    if (raw is! List) return const [];
    final out = <Map<String, Object?>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final row = Map<String, dynamic>.from(item);
      out.add({
        'id': row['id']?.toString(),
        'role': row['role']?.toString(),
        'text': (row['content'] ?? row['text'])?.toString(),
        'createdAt': (row['createdAt'] ?? row['created_at'])?.toString(),
      });
    }
    return out;
  }

  /// True when the host refused because no worker exists for the chat yet.
  bool _needsWorker(Object error) {
    final text = '$error'.toLowerCase();
    return text.contains('unknown chatid') || text.contains('agents.ensure');
  }

  Future<void> _release(Host host, ArchonRelayChannel channel) async {
    final close = _close;
    if (close == null) return;
    try {
      await close(host, channel);
    } catch (e) {
      SafeLog.d('archon relay release ${host.alias} failed', e);
    }
  }
}

/// A call this app will not or cannot make, phrased for Archon to read.
class _RelayRefusal implements Exception {
  const _RelayRefusal(this.error, this.message);

  final String error;
  final String message;

  @override
  String toString() => '$error: $message';
}

/// The relay subscription to Archon's host, reconnecting with backoff.
class _RelayLink {
  _RelayLink(this.owner, this.host);

  final ArchonRelayService owner;
  final Host host;

  ArchonRelayChannel? channel;
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _closed = false;
  Completer<void>? _wake;

  Future<void> run() async {
    var backoff = owner._retryDelay;
    while (!_closed) {
      ArchonRelayChannel? c;
      try {
        c = await owner._open(host);
        if (_closed) {
          await owner._release(host, c);
          return;
        }
        channel = c;
        _sub = c.events.listen((params) {
          if (params['method'] == 'closed') return;
          unawaited(
            owner._onEvent(this, params).catchError((Object e) {
              SafeLog.d('archon relay event failed ${host.alias}', e);
            }),
          );
        });
        await c.request('session.subscribe', {'relay': true});
        owner._onSubscribed();
        backoff = owner._retryDelay;
        await Future.any([c.done, _sleep(null)]);
      } catch (e) {
        SafeLog.d('archon relay ${host.alias} unavailable', e);
      }
      await _sub?.cancel();
      _sub = null;
      channel = null;
      if (c != null) await owner._release(host, c);
      if (_closed) return;
      await _sleep(backoff);
      final next = backoff * 2;
      backoff = next > const Duration(minutes: 5)
          ? const Duration(minutes: 5)
          : next;
    }
  }

  /// Wait [d] (or until [close]); null waits only for [close].
  Future<void> _sleep(Duration? d) {
    final wake = _wake = Completer<void>();
    Timer? t;
    if (d != null) {
      t = Timer(d, () {
        if (!wake.isCompleted) wake.complete();
      });
    }
    return wake.future.whenComplete(() => t?.cancel());
  }

  Future<void> reply(
    String callId, {
    required bool ok,
    Object? result,
    String? error,
    String? message,
  }) async {
    final c = channel;
    // The route died mid-call. The daemon's own timeout covers this, and
    // nothing here can reach Archon any more.
    if (c == null || !c.isOpen) return;
    try {
      await c.request('archon.reply', {
        'callId': callId,
        'ok': ok,
        'result': ?result,
        'error': ?error,
        'message': ?message,
      }, timeout: const Duration(seconds: 20));
    } catch (e) {
      SafeLog.d('archon reply $callId failed', e);
    }
  }

  Future<void> close() async {
    _closed = true;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    await _sub?.cancel();
    _sub = null;
  }
}

/// The real channel: a borrowed [AdsmClient] on the shared bridge.
class _AdsmRelayChannel implements ArchonRelayChannel {
  _AdsmRelayChannel(this.client);

  final AdsmClient client;

  @override
  Stream<Map<String, dynamic>> get events => client.events;

  @override
  bool get isOpen => client.isOpen;

  @override
  Future<void> get done => client.done;

  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 60),
  }) => client.request(method, params, timeout: timeout);
}
