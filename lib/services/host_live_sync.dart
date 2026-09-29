import 'dart:async';

import '../data/local/app_database.dart';
import '../data/models/chat_message.dart';
import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import 'adsm_client.dart';
import 'agentdock_service.dart';

/// Keeps every chat current on this device while the app is open — the way a
/// messenger keeps its chat list live, not just the conversation on screen.
///
/// One `digest` subscription per host (riding the shared [AdsmBridgePool]
/// bridge) carries new messages, turn ends, status and catalog changes for
/// every chat on that host — never the token stream. Chats with an open
/// runtime handle their own events; for the rest this stores the message or
/// pulls the finished reply, and re-syncs the host catalog when a chat is
/// created, renamed, read or deleted on another device.
class HostLiveSync {
  HostLiveSync({
    required AdsmBridgePool pool,
    required AppDatabase db,
    required AgentDockService dock,
    this.prepareHost,
    required this.isChatLive,
    required this.onMessages,
    required this.onCatalogChanged,
  }) : _pool = pool,
       _db = db,
       _dock = dock;

  final AdsmBridgePool _pool;
  final AppDatabase _db;
  final AgentDockService _dock;

  /// Runs before each connect attempt (e.g. upgrade a stale local daemon).
  final Future<void> Function(Host host)? prepareHost;

  /// True when [chatId] has an open runtime that applies its own events.
  final bool Function(String chatId) isChatLive;

  /// Messages were stored for [chatId] (refresh unread badges / previews).
  final void Function(String chatId) onMessages;

  /// The chat list changed shape (new / renamed / deleted chats).
  final void Function() onCatalogChanged;

  final Map<String, _HostLink> _links = {};
  bool _running = false;

  /// Bytes of transcript tail pulled after a turn ends elsewhere.
  static const _tailBytes = 256 * 1024;

  bool get running => _running;

  /// Open (or refresh) links to every host that has chats on this device.
  Future<void> start() async {
    _running = true;
    await refreshHosts();
  }

  /// Close every link (app went to the background).
  Future<void> stop() async {
    _running = false;
    final links = _links.values.toList();
    _links.clear();
    for (final link in links) {
      await link.close();
    }
  }

  /// Match the set of links to the hosts that currently own chats.
  Future<void> refreshHosts() async {
    if (!_running) return;
    final hostIds = <String>{};
    try {
      final chats = await _db.listAllChats();
      final repoIds = {for (final c in chats) c.repoId};
      for (final repo in await _db.listRepos()) {
        if (repoIds.contains(repo.id)) hostIds.add(repo.hostId);
      }
    } catch (e) {
      SafeLog.d('live sync host scan failed', e);
      return;
    }
    for (final id in _links.keys.toList()) {
      if (!hostIds.contains(id)) await _links.remove(id)?.close();
    }
    var first = true;
    for (final id in hostIds) {
      if (_links.containsKey(id)) continue;
      final host = await _db.getHost(id);
      if (host == null || !_running || _links.containsKey(id)) continue;
      // Stagger SSH handshakes — they run on the UI isolate.
      if (!first) await Future<void>.delayed(const Duration(milliseconds: 400));
      first = false;
      if (!_running || _links.containsKey(id)) continue;
      _links[id] = _HostLink(this, host)..run();
    }
  }

  /// Tell the other devices on [host] that [chatId]'s record changed.
  Future<void> notifyChatChanged(Host host, String chatId) async {
    final client = _links[host.id]?.client;
    if (client == null || !client.isOpen) return;
    try {
      await client.request('chats.notify', {
        'chatId': chatId,
        'change': 'updated',
      }, timeout: const Duration(seconds: 8));
    } catch (e) {
      // Hosts before ADSM 0.6.0 lack the method; they catch up on refresh.
      SafeLog.d('chats.notify failed', e);
    }
  }

  Future<void> _onEvent(_HostLink link, Map<String, dynamic> params) async {
    final chatId = params['chatId']?.toString() ?? '';
    if (chatId.isEmpty) return;
    final kind = params['kind']?.toString() ?? '';
    if (kind == 'chat_changed') {
      link.scheduleCatalogSync();
      return;
    }
    if (await _db.getChat(chatId) == null) {
      // A chat this device has never seen — created on another device.
      link.scheduleCatalogSync();
      return;
    }
    if (isChatLive(chatId)) {
      if (kind == 'user_message' || kind == 'turn_complete') {
        onMessages(chatId);
      }
      return;
    }
    switch (kind) {
      case 'user_message':
        final m = adsmUserMessage(params);
        if (m == null) return;
        await _db.mergeMessages(chatId, [m]);
        onMessages(chatId);
      case 'turn_complete':
        link.schedulePull(chatId);
      case 'status':
        final st = params['status']?.toString();
        if (st == 'idle' || st == 'error') link.schedulePull(chatId);
    }
  }

  Future<void> _pullTail(AdsmClient client, String chatId) async {
    if (isChatLive(chatId)) return;
    final result = await client.request('transcript.pull', {
      'chatId': chatId,
      'maxBytes': _tailBytes,
    }, timeout: const Duration(seconds: 30));
    final raw = result['messages'];
    if (raw is! List) return;
    final messages = <ChatMessage>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        messages.add(ChatMessage.fromMap(Map<String, Object?>.from(item)));
      } catch (_) {}
    }
    if (messages.isEmpty || isChatLive(chatId)) return;
    if (await _db.mergeMessages(chatId, messages) > 0) onMessages(chatId);
  }
}

/// The digest subscription to one host, reconnecting with backoff.
class _HostLink {
  _HostLink(this.owner, this.host);

  final HostLiveSync owner;
  final Host host;

  AdsmClient? client;
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _closed = false;
  Completer<void>? _wake;
  Timer? _catalogTimer;
  final Map<String, Timer> _pullTimers = {};

  Future<void> run() async {
    var backoff = const Duration(seconds: 5);
    while (!_closed) {
      AdsmClient? c;
      try {
        await owner.prepareHost?.call(host);
        if (_closed) return;
        c = await owner._pool.acquire(host);
        if (_closed) {
          await owner._pool.releaseClient(host.id, c);
          return;
        }
        client = c;
        _sub = c.events.listen((params) {
          if (params['method'] == 'closed') return;
          unawaited(
            owner._onEvent(this, params).catchError((Object e) {
              SafeLog.d('live sync event failed ${host.alias}', e);
            }),
          );
        });
        await c.request('session.subscribe', {'digest': true});
        // Anything missed while disconnected: new chats and records.
        scheduleCatalogSync(delay: Duration.zero);
        backoff = const Duration(seconds: 5);
        await Future.any([c.done, _sleep(null)]);
      } catch (e) {
        SafeLog.d('live sync ${host.alias} unavailable', e);
      }
      await _sub?.cancel();
      _sub = null;
      client = null;
      if (c != null) await owner._pool.releaseClient(host.id, c);
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

  void scheduleCatalogSync({Duration delay = const Duration(seconds: 1)}) {
    _catalogTimer?.cancel();
    _catalogTimer = Timer(delay, () async {
      if (_closed) return;
      try {
        await owner._dock.syncHostCatalog(host, probes: false);
        // Read markers and titles can change without a "merged" row.
        owner.onCatalogChanged();
      } catch (e) {
        SafeLog.d('live catalog sync ${host.alias} failed', e);
      }
    });
  }

  /// Pull [chatId]'s transcript tail once its turn has settled.
  void schedulePull(String chatId) {
    _pullTimers.remove(chatId)?.cancel();
    _pullTimers[chatId] = Timer(const Duration(milliseconds: 800), () async {
      _pullTimers.remove(chatId);
      final c = client;
      if (_closed || c == null || !c.isOpen) return;
      try {
        await owner._pullTail(c, chatId);
      } catch (e) {
        SafeLog.d('live pull $chatId failed', e);
      }
    });
  }

  Future<void> close() async {
    _closed = true;
    _catalogTimer?.cancel();
    for (final t in _pullTimers.values) {
      t.cancel();
    }
    _pullTimers.clear();
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }
}
