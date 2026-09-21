import 'dart:async';
import 'dart:convert';

import 'package:agent_dock/services/adsm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AdsmClient NDJSON ingestion', () {
    test('lines split across chunks and batched chunks arrive in order',
        () async {
      final out = StreamController<List<int>>();
      final client = AdsmClient.overStreams(out.stream, const Stream.empty());
      final seen = <String>[];
      final sub = client.events.listen((e) => seen.add('${e['n']}'));

      String ev(int n) =>
          '${jsonEncode({'method': 'event', 'params': {'n': n}})}\n';
      final joined = ev(1) + ev(2) + ev(3);
      // Split the first line mid-JSON, then send several lines in one chunk.
      out.add(utf8.encode(joined.substring(0, 10)));
      out.add(utf8.encode(joined.substring(10)));
      out.add(utf8.encode(ev(4) + ev(5) + ev(6) + ev(7) + ev(8) + ev(9)));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, ['1', '2', '3', '4', '5', '6', '7', '8', '9']);
      await sub.cancel();
      await out.close();
    });

    test('heavy tool line decodes off-thread with payloads flattened',
        () async {
      final out = StreamController<List<int>>();
      final client = AdsmClient.overStreams(out.stream, const Stream.empty());
      final events = <Map<String, dynamic>>[];
      final sub = client.events.listen(events.add);

      final big = List.generate(4000, (i) => {'line': i, 'text': 'x' * 8});
      final heavy = jsonEncode({
        'method': 'event',
        'params': {
          'type': 'tool',
          'tool': {
            'toolCallId': 't1',
            'title': 'Bash',
            'rawOutput': big,
            'rawInput': 'already a string',
          },
        },
      });
      expect(heavy.length, greaterThan(24 * 1024));
      final small = jsonEncode({'method': 'event', 'params': {'after': true}});
      out.add(utf8.encode('$heavy\n$small\n'));
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(events, hasLength(2));
      final tool = events.first['tool'] as Map;
      // Blob stringified in the worker; strings pass through untouched.
      expect(tool['rawOutput'], isA<String>());
      expect(tool['rawOutput'], startsWith('[{"line":0'));
      expect(tool['rawInput'], 'already a string');
      // Ordering preserved across the async decode.
      expect(events.last['after'], isTrue);
      await sub.cancel();
      await out.close();
    });
  });
}
