import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/features/agents/chat_image.dart';
import 'package:agentplantation/features/agents/chat_markdown.dart';
import 'package:agentplantation/services/remote_image_cache.dart';
import 'package:agentplantation/services/ssh_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smallest valid PNG, so `Image.memory` has something real to decode.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

Host _host(String id) => Host(
  id: id,
  alias: 'h',
  hostname: 'h',
  username: 'u',
  port: 22,
  createdAt: DateTime(2026),
);

void main() {
  group('canShowChatImage', () {
    test('accepts an image path the agent can write', () {
      expect(canShowChatImage('/home/u/charts/latency.png'), isTrue);
      expect(canShowChatImage('out/plot.JPG'), isTrue);
      expect(canShowChatImage('~/shot.webp'), isTrue);
    });

    test('refuses a path that is not an image', () {
      expect(canShowChatImage('lib/main.dart'), isFalse);
      expect(canShowChatImage('notes'), isFalse);
      expect(canShowChatImage(''), isFalse);
    });

    test('refuses http sources rather than fetching them', () {
      // Rendering one would turn agent output into an outbound request from
      // the user's device — a tracking vector they never opted into.
      expect(canShowChatImage('http://example.com/a.png'), isFalse);
      expect(canShowChatImage('https://example.com/a.png'), isFalse);
      expect(canShowChatImage('//example.com/a.png'), isFalse);
    });

    test('accepts a small data uri and refuses a large one', () {
      final small = 'data:image/png;base64,${base64Encode(_png)}';
      expect(canShowChatImage(small), isTrue);
      // Still "shows" — as a refusal row rather than silently nothing.
      final big = 'data:image/png;base64,${'A' * (kMaxDataUriBytes * 2)}';
      expect(canShowChatImage(big), isTrue);
      expect(decodeDataUri(big)!.failure, RemoteImageFailure.tooLarge);
      expect(decodeDataUri(big)!.bytes, isNull);
    });

    test('refuses a non-image or non-base64 data uri', () {
      expect(canShowChatImage('data:text/plain;base64,aGk='), isFalse);
      expect(canShowChatImage('data:image/png,notbase64'), isFalse);
    });
  });

  group('markdown rendering', () {
    testWidgets('an image on its own line becomes a picture', (tester) async {
      final seen = <(String, String)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatMarkdown(
              text: '![latency](out/plot.png)',
              imageBuilder: (src, alt) {
                seen.add((src, alt));
                return const SizedBox(key: Key('pic'), width: 10, height: 10);
              },
            ),
          ),
        ),
      );
      expect(seen, [('out/plot.png', 'latency')]);
      expect(find.byKey(const Key('pic')), findsOneWidget);
    });

    testWidgets('text around the image is kept, in order', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatMarkdown(
              text: 'before ![a](x.png) after',
              imageBuilder: (_, _) =>
                  const SizedBox(key: Key('pic'), width: 10, height: 10),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('pic')), findsOneWidget);
      expect(find.textContaining('before'), findsOneWidget);
      expect(find.textContaining('after'), findsOneWidget);
    });

    testWidgets('a builder that declines leaves the alt text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatMarkdown(
              text: '![a chart](https://example.com/a.png)',
              imageBuilder: (_, _) => null,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('pic')), findsNothing);
      expect(find.textContaining('a chart'), findsOneWidget);
    });

    testWidgets('no builder keeps the old alt-text behaviour', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ChatMarkdown(text: '![a chart](x.png)')),
        ),
      );
      expect(find.textContaining('a chart'), findsOneWidget);
    });

    testWidgets('several images in one paragraph all render', (tester) async {
      var built = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatMarkdown(
              text: '![a](1.png)\n![b](2.png)',
              imageBuilder: (_, _) {
                built++;
                return const SizedBox(width: 10, height: 10);
              },
            ),
          ),
        ),
      );
      expect(built, 2);
    });
  });

  group('RemoteImageCache', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('imgcache'));
    tearDown(() => tmp.deleteSync(recursive: true));

    RemoteImageCache build({
      required RemoteStat stat,
      required RemoteDownload download,
    }) => RemoteImageCache(
      stat: stat,
      download: download,
      cacheRoot: () async => tmp,
    );

    RemoteStat statOf({int? size, DateTime? modified}) =>
        (host, path) async => RemoteFileEntry(
          name: 'plot.png',
          isDirectory: false,
          size: size,
          modifiedAt: modified,
        );

    RemoteDownload writes(Uint8List bytes, {List<String>? calls}) =>
        (host, remotePath, localPath, {int? totalBytes}) async {
          calls?.add(remotePath);
          await File(localPath).writeAsBytes(bytes);
          return bytes.length;
        };

    test('fetches once, then serves the cached copy', () async {
      final calls = <String>[];
      final cache = build(
        stat: statOf(size: _png.length, modified: DateTime(2026, 1, 1)),
        download: writes(_png, calls: calls),
      );
      final a = await cache.resolve(_host('h1'), '/out/plot.png');
      final b = await cache.resolve(_host('h1'), '/out/plot.png');
      expect(a.isReady, isTrue);
      expect(b.localPath, a.localPath);
      expect(calls, hasLength(1));
    });

    test('a regenerated chart is re-fetched, not served stale', () async {
      // Same path, new mtime — the agent re-ran the plot.
      final calls = <String>[];
      var cache = build(
        stat: statOf(size: _png.length, modified: DateTime(2026, 1, 1)),
        download: writes(_png, calls: calls),
      );
      final first = await cache.resolve(_host('h1'), '/out/plot.png');
      cache = build(
        stat: statOf(size: _png.length, modified: DateTime(2026, 2, 2)),
        download: writes(_png, calls: calls),
      );
      final second = await cache.resolve(_host('h1'), '/out/plot.png');
      expect(calls, hasLength(2));
      expect(second.localPath, isNot(first.localPath));
    });

    test('the same path on two hosts does not collide', () async {
      final cache = build(
        stat: statOf(size: _png.length, modified: DateTime(2026, 1, 1)),
        download: writes(_png),
      );
      final a = await cache.resolve(_host('h1'), '/out/plot.png');
      final b = await cache.resolve(_host('h2'), '/out/plot.png');
      expect(a.localPath, isNot(b.localPath));
    });

    test('concurrent requests for one image share a single transfer', () async {
      final calls = <String>[];
      final cache = build(
        stat: statOf(size: _png.length, modified: DateTime(2026, 1, 1)),
        download: writes(_png, calls: calls),
      );
      final results = await Future.wait([
        for (var i = 0; i < 6; i++)
          cache.resolve(_host('h1'), '/out/plot.png'),
      ]);
      expect(calls, hasLength(1));
      expect(results.map((r) => r.localPath).toSet(), hasLength(1));
    });

    test('refuses an image past the cap without transferring it', () async {
      final calls = <String>[];
      final cache = build(
        stat: statOf(
          size: RemoteImageCache.maxBytes + 1,
          modified: DateTime(2026),
        ),
        download: writes(_png, calls: calls),
      );
      final r = await cache.resolve(_host('h1'), '/out/huge.png');
      expect(r.isReady, isFalse);
      expect(r.failure, RemoteImageFailure.tooLarge);
      expect(r.bytes, RemoteImageCache.maxBytes + 1);
      expect(calls, isEmpty, reason: 'must not pull it down to find out');
    });

    test('a missing file reports missing', () async {
      final cache = build(
        stat: (host, path) async => null,
        download: writes(_png),
      );
      final r = await cache.resolve(_host('h1'), '/out/gone.png');
      expect(r.failure, RemoteImageFailure.missing);
    });

    test('a directory is not an image', () async {
      final cache = build(
        stat: (host, path) async =>
            const RemoteFileEntry(name: 'out', isDirectory: true),
        download: writes(_png),
      );
      final r = await cache.resolve(_host('h1'), '/out');
      expect(r.failure, RemoteImageFailure.missing);
    });

    test('a failed transfer reports it and leaves no part file', () async {
      final cache = build(
        stat: statOf(size: 10, modified: DateTime(2026)),
        download: (host, remotePath, localPath, {int? totalBytes}) async =>
            throw const SocketException('channel closed'),
      );
      final r = await cache.resolve(_host('h1'), '/out/plot.png');
      expect(r.failure, RemoteImageFailure.transferFailed);
      // The half-written file must not be left behind to be served later as
      // a truncated image. It lives in the cache's own subdirectory.
      final dir = Directory('${tmp.path}/agentdock_chat_images');
      expect(dir.existsSync(), isTrue, reason: 'cache dir should exist');
      expect(
        dir.listSync().whereType<File>().map((f) => f.path).toList(),
        isEmpty,
      );
    });

    test('a transfer that writes nothing is a failure, not an empty image',
        () async {
      final cache = build(
        stat: statOf(size: 10, modified: DateTime(2026)),
        download: (host, remotePath, localPath, {int? totalBytes}) async {
          await File(localPath).writeAsBytes(const []);
          return 0;
        },
      );
      final r = await cache.resolve(_host('h1'), '/out/plot.png');
      expect(r.failure, RemoteImageFailure.transferFailed);
    });

    test('a stat that throws is not fatal', () async {
      final cache = build(
        stat: (host, path) async => throw const SocketException('down'),
        download: writes(_png),
      );
      final r = await cache.resolve(_host('h1'), '/out/plot.png');
      expect(r.failure, RemoteImageFailure.missing);
    });

    test('keeps the extension so the viewer still sees a png', () async {
      final cache = build(
        stat: statOf(size: _png.length, modified: DateTime(2026)),
        download: writes(_png),
      );
      final r = await cache.resolve(_host('h1'), '/out/plot.png');
      expect(r.localPath, endsWith('.png'));
    });

    test('a rebuilding row does not re-stat the host', () async {
      // Scrolling recreates rows; each one must not cost an SSH round-trip.
      var stats = 0;
      final cache = build(
        stat: (host, path) async {
          stats++;
          return RemoteFileEntry(
            name: 'plot.png',
            isDirectory: false,
            size: _png.length,
            modifiedAt: DateTime(2026),
          );
        },
        download: writes(_png),
      );
      for (var i = 0; i < 5; i++) {
        await cache.resolve(_host('h1'), '/out/plot.png');
      }
      expect(stats, 1);
    });

    test('past the recheck window it looks again', () async {
      var stats = 0;
      var clock = DateTime(2026, 1, 1, 12);
      final cache = build(
        stat: (host, path) async {
          stats++;
          return RemoteFileEntry(
            name: 'plot.png',
            isDirectory: false,
            size: _png.length,
            modifiedAt: DateTime(2026),
          );
        },
        download: writes(_png),
      );
      cache.debugSetClock(() => clock);
      await cache.resolve(_host('h1'), '/out/plot.png');
      clock = clock.add(RemoteImageCache.recheckAfter * 2);
      await cache.resolve(_host('h1'), '/out/plot.png');
      expect(stats, 2);
    });

    test('a memo whose file was cleared is not served', () async {
      final cache = build(
        stat: statOf(size: _png.length, modified: DateTime(2026)),
        download: writes(_png),
      );
      final first = await cache.resolve(_host('h1'), '/out/plot.png');
      // The OS may clear the temp directory under us.
      File(first.localPath!).deleteSync();
      final second = await cache.resolve(_host('h1'), '/out/plot.png');
      expect(second.isReady, isTrue);
      expect(File(second.localPath!).existsSync(), isTrue);
    });

    test('a path with no usable extension still caches', () async {
      final cache = build(
        stat: statOf(size: _png.length, modified: DateTime(2026)),
        download: writes(_png),
      );
      final r = await cache.resolve(_host('h1'), '/out/plot');
      expect(r.isReady, isTrue);
    });
  });
}
