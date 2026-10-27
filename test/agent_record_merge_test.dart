import 'dart:convert';
import 'dart:io';

import 'package:agentplantation/services/agentdock_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The command that writes `~/.agentdock/agents/<id>.json` is run on the host,
/// so the thing worth testing is the shell itself — run it and look at the
/// file it leaves behind.
Future<Map<String, Object?>> runWrite(
  Directory dir,
  String chatId,
  Map<String, Object?> record,
) async {
  final agents = '${dir.path}/agents';
  final path = '$agents/$chatId.json';
  final cmd = agentRecordWriteCommand(
    dir: agents,
    path: path,
    json: const JsonEncoder.withIndent('  ').convert(record),
  );
  final r = await Process.run('sh', ['-c', cmd]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return Map<String, Object?>.from(
    jsonDecode(File(path).readAsStringSync()) as Map,
  );
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('agentrec'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('writes a new record verbatim', () async {
    final out = await runWrite(tmp, 'c1', {
      'id': 'c1',
      'title': 'Work',
      'provider': 'claude',
    });
    expect(out['title'], 'Work');
    expect(out['provider'], 'claude');
  });

  test('a catalog push keeps the launch fields it does not carry', () async {
    // What `agents.ensure` recorded: how to start this agent.
    await runWrite(tmp, 'c2', {
      'id': 'c2',
      'provider': 'claude',
      'cwd': '/home/u/Arts',
      'binary': '/home/u/.local/bin/claude-code-acp',
      'permission_ask': false,
    });

    // What the catalog push carries: no cwd, no binary. Truncating here is
    // what left the worker exec'ing the empty string, so that every later
    // prompt answered "FIFO not attached" and the chat looked disconnected.
    final out = await runWrite(tmp, 'c2', {
      'id': 'c2',
      'title': 'Work[ColibriVDI]',
      'provider': 'claude',
      'repo_path': '/home/u/Arts',
      'status': 'running',
    });

    expect(out['cwd'], '/home/u/Arts');
    expect(out['binary'], '/home/u/.local/bin/claude-code-acp');
    expect(out['permission_ask'], false);
    expect(out['title'], 'Work[ColibriVDI]');
    expect(out['status'], 'running');
  });

  test('the pushed value wins where both sides have the key', () async {
    await runWrite(tmp, 'c3', {'id': 'c3', 'title': 'old', 'status': 'idle'});
    final out = await runWrite(tmp, 'c3', {
      'id': 'c3',
      'title': 'new',
      'status': 'running',
    });
    expect(out['title'], 'new');
    expect(out['status'], 'running');
  });

  test('an unreadable record is replaced, not left to block the push', () async {
    Directory('${tmp.path}/agents').createSync(recursive: true);
    File('${tmp.path}/agents/c4.json').writeAsStringSync('{not json');
    final out = await runWrite(tmp, 'c4', {'id': 'c4', 'title': 'fresh'});
    expect(out['title'], 'fresh');
  });

  test('leaves no temp file behind', () async {
    await runWrite(tmp, 'c5', {'id': 'c5'});
    expect(File('${tmp.path}/agents/c5.json.new').existsSync(), isFalse);
  });
}
