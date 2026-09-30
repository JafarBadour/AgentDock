import 'dart:async';
import 'dart:io';

import 'package:agent_dock/data/local/app_database.dart';
import 'package:agent_dock/data/models/agent_provider.dart';
import 'package:agent_dock/data/models/chat.dart';
import 'package:agent_dock/data/models/host.dart';
import 'package:agent_dock/data/models/repo.dart';
import 'package:agent_dock/services/archon_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A stand-in for the ADSM bridge: records what the relay asked the host to
/// do, and lets a test push the events the daemon would have pushed.
class _FakeChannel implements ArchonRelayChannel {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _done = Completer<void>();
  final _waiters = <String, Completer<Map<String, dynamic>>>{};

  /// Every `request` made, in order.
  final calls = <(String, Map<String, dynamic>)>[];

  /// Per-method answers; a method with no handler answers `{}`.
  final handlers =
      <String, Future<Map<String, dynamic>> Function(Map<String, dynamic>)>{};

  bool open = true;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  bool get isOpen => open;

  @override
  Future<void> get done => _done.future;

  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 60),
  }) {
    calls.add((method, params));
    _waiters.remove(method)?.complete(params);
    final handler = handlers[method];
    return handler == null
        ? Future.value(<String, dynamic>{})
        : handler(params);
  }

  List<Map<String, dynamic>> paramsFor(String method) => [
    for (final c in calls)
      if (c.$1 == method) c.$2,
  ];

  /// The params of the next (or already made) [method] call.
  Future<Map<String, dynamic>> nextCall(String method) {
    final made = paramsFor(method);
    if (made.isNotEmpty) return Future.value(made.last);
    return (_waiters[method] ??= Completer<Map<String, dynamic>>()).future;
  }

  void push(Map<String, dynamic> event) => _events.add(event);

  void dispose() {
    if (!_done.isCompleted) _done.complete();
    _events.close();
  }
}

Map<String, dynamic> _request(
  String callId,
  String action, [
  Map<String, dynamic> payload = const {},
]) => {
  'chatId': '',
  'seq': 0,
  'kind': 'archon_request',
  'callId': callId,
  'action': action,
  'payload': payload,
};

Host _host(String id) => Host(
  id: id,
  alias: 'host-$id',
  hostname: '$id.example',
  username: 'me',
  createdAt: DateTime.utc(2026, 9, 30),
);

Chat _chat(String id, String repoId) => Chat(
  id: id,
  repoId: repoId,
  title: 'chat $id',
  provider: AgentProvider.claude,
  createdAt: DateTime.utc(2026, 9, 30),
  updatedAt: DateTime.utc(2026, 9, 30),
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late Map<String, _FakeChannel> channels;
  late _FakeChannel archonChannel;
  late List<(Host, Chat)> prepared;

  /// Hosts a and b, each with one repo and one chat; only a is reachable
  /// unless a test adds b to [channels].
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('archon-relay');
    addTearDown(() => dir.delete(recursive: true));
    db = AppDatabase(overridePath: p.join(dir.path, 'relay.db'));
    for (final id in ['a', 'b']) {
      await db.upsertHost(_host(id));
      await db.upsertRepo(
        Repo(
          id: 'repo-$id',
          hostId: id,
          name: 'repo $id',
          remotePath: '/srv/$id',
          createdAt: DateTime.utc(2026, 9, 30),
        ),
      );
      await db.upsertChat(_chat('chat-$id', 'repo-$id'));
    }
    archonChannel = _FakeChannel();
    channels = {'a': archonChannel};
    prepared = [];
    addTearDown(() {
      for (final c in channels.values) {
        c.dispose();
      }
    });
  });

  Future<ArchonRelayService> startRelay({
    Duration actionBudget = const Duration(seconds: 45),
    bool withPrepare = true,
  }) async {
    final service = ArchonRelayService(
      db: db,
      archonHost: () async => _host('a'),
      open: (host) async {
        final channel = channels[host.id];
        if (channel == null) throw StateError('no route to ${host.alias}');
        return channel;
      },
      prepareChat: withPrepare
          ? (host, chat) async => prepared.add((host, chat))
          : null,
      actionBudget: actionBudget,
    );
    addTearDown(service.stop);
    await service.start();
    await service.subscribed.timeout(const Duration(seconds: 5));
    return service;
  }

  /// The single reply the relay sent, failing if it sent none.
  Future<Map<String, dynamic>> reply() => archonChannel
      .nextCall('archon.reply')
      .timeout(const Duration(seconds: 5));

  test('volunteers as a route rather than a chat subscriber', () async {
    await startRelay();
    expect(archonChannel.paramsFor('session.subscribe'), [
      {'relay': true},
    ]);
  });

  test('answers a relayed call', () async {
    await startRelay();
    archonChannel.push(_request('relay-1', 'routes'));

    final answer = await reply();
    expect(answer['callId'], 'relay-1');
    expect(answer['ok'], isTrue);
    final hosts = (answer['result'] as Map)['hosts'] as List;
    expect(hosts.map((h) => (h as Map)['hostId']), containsAll(['a', 'b']));
  });

  test(
    'refuses an unknown action instead of leaving Archon to time out',
    () async {
      await startRelay();
      archonChannel.push(_request('relay-7', 'teleport'));

      final answer = await reply();
      expect(answer['callId'], 'relay-7');
      expect(answer['ok'], isFalse);
      expect(answer['error'], 'unknown_action');
      expect(answer['message'], contains('teleport'));
    },
  );

  test('ignores events that are not relayed calls', () async {
    await startRelay();
    archonChannel.push({'chatId': 'chat-a', 'seq': 1, 'kind': 'status'});
    archonChannel.push({'method': 'closed'});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(archonChannel.paramsFor('archon.reply'), isEmpty);
  });

  test('one unreachable host does not sink the agent list', () async {
    // Only host a answers; b is not in [channels], so opening it throws.
    archonChannel.handlers['agents.list'] = (_) async => {
      'agents': [
        {'chatId': 'chat-a', 'status': 'running', 'cwd': '/srv/a/live'},
        {'chatId': 'stray', 'status': 'idle'},
      ],
    };
    await startRelay();
    archonChannel.push(_request('relay-2', 'agents'));

    final answer = await reply();
    expect(answer['ok'], isTrue, reason: 'b being down is not a failed call');
    final result = answer['result'] as Map;
    final agents = (result['agents'] as List).cast<Map>();
    final byChat = {for (final a in agents) a['chatId']: a};

    expect(byChat['chat-a']!['live'], isTrue);
    expect(byChat['chat-a']!['status'], 'running');
    expect(byChat['chat-a']!['cwd'], '/srv/a/live');
    // Known to the app, unreachable right now: still an agent Archon can see.
    expect(byChat['chat-b']!['hostId'], 'b');
    expect(byChat['chat-b']!['live'], isFalse);
    // Running on the host but never seen by this app.
    expect(byChat['stray']!['knownToApp'], isFalse);

    final unreachable = (result['unreachable'] as List).cast<Map>();
    expect(unreachable.map((u) => u['hostId']), ['b']);
  });

  test('answers within its budget when a host stops responding', () async {
    // A host that accepts the call and never answers is the worst case: the
    // relay must give up first, or Archon's own timeout fires with nothing.
    archonChannel.handlers['agents.list'] = (_) =>
        Completer<Map<String, dynamic>>().future;
    await startRelay(actionBudget: const Duration(milliseconds: 80));
    archonChannel.push(_request('relay-3', 'agents'));

    final answer = await reply();
    expect(answer['ok'], isFalse);
    expect(answer['error'], 'timeout');
  });

  test('answers a call exactly once even if it is delivered twice', () async {
    await startRelay();
    archonChannel.push(_request('relay-4', 'routes'));
    archonChannel.push(_request('relay-4', 'routes'));
    await reply();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(archonChannel.paramsFor('archon.reply').length, 1);
  });

  test('sends a prompt to the named host', () async {
    final hostB = _FakeChannel();
    channels['b'] = hostB;
    await startRelay();
    archonChannel.push(
      _request('relay-5', 'prompt', {
        'hostId': 'b',
        'chatId': 'chat-b',
        'text': 'ship it',
      }),
    );

    final sent = await hostB
        .nextCall('session.prompt')
        .timeout(const Duration(seconds: 5));
    expect(sent['chatId'], 'chat-b');
    expect(sent['text'], 'ship it');
    // Carries an id so every device stores the prompt as one message.
    expect(sent['userMessageId'], isNotEmpty);

    final answer = await reply();
    expect(answer['ok'], isTrue);
    expect((answer['result'] as Map)['delivered'], isTrue);
    expect((answer['result'] as Map)['hostId'], 'b');
    expect(archonChannel.paramsFor('session.prompt'), isEmpty);
  });

  test('starts a worker that is not running, then delivers once', () async {
    final hostB = _FakeChannel();
    channels['b'] = hostB;
    var attempts = 0;
    hostB.handlers['session.prompt'] = (_) async {
      if (++attempts == 1) {
        throw StateError('unknown chatId — call agents.ensure first');
      }
      return {'accepted': true};
    };
    await startRelay();
    archonChannel.push(
      _request('relay-6', 'prompt', {
        'hostId': 'b',
        'chatId': 'chat-b',
        'text': 'wake up',
      }),
    );

    final answer = await reply();
    expect(answer['ok'], isTrue);
    expect(attempts, 2);
    expect(prepared.map((e) => (e.$1.id, e.$2.id)), [('b', 'chat-b')]);
  });

  test('reports a prompt that cannot be delivered', () async {
    // b has no route at all, and nothing must be invented on its behalf.
    await startRelay();
    archonChannel.push(
      _request('relay-8', 'prompt', {
        'hostId': 'b',
        'chatId': 'chat-b',
        'text': 'hello',
      }),
    );

    final answer = await reply();
    expect(answer['ok'], isFalse);
    expect(answer['error'], 'failed');
    expect(answer['message'], contains('host-b'));
    expect(prepared, isEmpty);
  });

  test('refuses a prompt for a host it has never seen', () async {
    await startRelay();
    archonChannel.push(
      _request('relay-9', 'prompt', {
        'hostId': 'zz',
        'chatId': 'nobody',
        'text': 'hello',
      }),
    );

    final answer = await reply();
    expect(answer['ok'], isFalse);
    expect(answer['error'], 'unknown_host');
  });

  test('routes a prompt by the chat when the hostId is wrong', () async {
    final hostB = _FakeChannel();
    channels['b'] = hostB;
    await startRelay();
    archonChannel.push(
      _request('relay-10', 'prompt', {
        'hostId': '',
        'chatId': 'chat-b',
        'text': 'ship it',
      }),
    );

    await hostB.nextCall('session.prompt').timeout(const Duration(seconds: 5));
    expect((await reply())['ok'], isTrue);
  });

  test('refuses an empty prompt', () async {
    await startRelay();
    archonChannel.push(
      _request('relay-11', 'prompt', {
        'hostId': 'a',
        'chatId': 'chat-a',
        'text': '   ',
      }),
    );

    final answer = await reply();
    expect(answer['error'], 'bad_request');
    expect(archonChannel.paramsFor('session.prompt'), isEmpty);
  });

  test('refuses to let Archon prompt itself', () async {
    await startRelay();
    archonChannel.push(
      _request('relay-12', 'prompt', {
        'hostId': 'a',
        'chatId': 'archon',
        'text': 'do it again',
      }),
    );

    final answer = await reply();
    expect(answer['error'], 'refused');
    expect(archonChannel.paramsFor('session.prompt'), isEmpty);
  });

  test('stops listening once the route is given up', () async {
    final service = await startRelay();
    await service.stop();
    archonChannel.push(_request('relay-13', 'routes'));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(service.running, isFalse);
    expect(archonChannel.paramsFor('archon.reply'), isEmpty);
  });
}
