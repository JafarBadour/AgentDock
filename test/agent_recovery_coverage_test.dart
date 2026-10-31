import 'dart:io';

import 'package:agentplantation/services/agent_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every `RuntimeError("…")` the daemon can hand back to the app.
///
/// Read out of the host's own source rather than copied, so the list cannot
/// drift. The daemon encodes these as plain error text, so the app recognises
/// them by message — and an unclassified one is rethrown to the UI as a dead
/// chat. That has now happened twice: "FIFO not attached" and then
/// "ACP session not ready", which is why this test exists instead of a third
/// round of adding one string.
Iterable<String> hostErrorStrings() sync* {
  final plain = RegExp(r'RuntimeError\(\s*"([^"]+)"');
  final formatted = RegExp(r'RuntimeError\(\s*f"([^"]+)"');
  for (final name in [
    'worker.py',
    'daemon.py',
    'scheduler.py',
    'winproc.py',
  ]) {
    final file = File('host/adsm/$name');
    if (!file.existsSync()) continue;
    final src = file.readAsStringSync();
    for (final m in plain.allMatches(src)) {
      yield m.group(1)!;
    }
    for (final m in formatted.allMatches(src)) {
      yield m.group(1)!;
    }
  }
}

void main() {
  test('the host cannot raise an error the app has not classified', () {
    final seen = hostErrorStrings().toSet();
    expect(seen, isNotEmpty, reason: 'no host errors found — regex drifted?');

    final unclassified = <String>[];
    for (final raw in seen) {
      final text = raw.toLowerCase();
      final recoverable = agentNeedsReensure(raw);
      final known = kNotATransportFailure.any(text.contains);
      if (!recoverable && !known) unclassified.add(raw);
    }

    expect(
      unclassified,
      isEmpty,
      reason:
          'The host can raise these, and the app does not know what they '
          'mean:\n  ${unclassified.join('\n  ')}\n\n'
          'Each must go in exactly one list in agent_recovery.dart: '
          'kNeedsEnsureMarkers if an agents.ensure fixes it (the worker '
          'cannot be reached), or kNotATransportFailure if it is a real '
          'refusal the user should see. Leaving it out means the chat looks '
          'disconnected and only forcing a new session clears it.',
    );
  });

  test('the resume failures are recoverable', () {
    // The exact text `prompt()` wraps a failed resume in. Forcing a new
    // session mints an id through ensure, which is why that worked around it.
    expect(
      agentNeedsReensure('ACP session not ready: no session id'),
      isTrue,
    );
    expect(agentNeedsReensure('ACP session not ready'), isTrue);
    expect(agentNeedsReensure('agent FIFO recycled'), isTrue);
    expect(agentNeedsReensure('could not open FIFO /tmp/x.fifo'), isTrue);
    expect(
      agentNeedsReensure('FIFO not attached: reopen this chat'),
      isTrue,
    );
    expect(
      agentNeedsReensure('unknown chatId — call agents.ensure first'),
      isTrue,
    );
  });

  test('a real refusal does not trigger a reconnect', () {
    // Reconnecting here would cancel the turn the agent is working on.
    expect(
      agentNeedsReensure(
        'agent is already running a turn — wait for it to finish',
      ),
      isFalse,
    );
    expect(agentNeedsReensure('unknown schedule id'), isFalse);
    expect(agentNeedsReensure('empty prompt'), isFalse);
    expect(agentNeedsReensure(null), isFalse);
    expect(agentNeedsReensure(''), isFalse);
  });

  test('matching is case-insensitive, as the host writes mixed case', () {
    expect(agentNeedsReensure('agent FIFO recycled'), isTrue);
    expect(agentNeedsReensure('AGENT FIFO RECYCLED'), isTrue);
  });

  test('the two lists do not overlap', () {
    for (final marker in kNeedsEnsureMarkers) {
      expect(
        kNotATransportFailure.any(marker.contains),
        isFalse,
        reason: '"$marker" is in both lists',
      );
    }
  });
}
