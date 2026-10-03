import 'dart:async';

import 'package:agentplantation/features/agents/image_paste.dart';
import 'package:flutter_test/flutter_test.dart';

/// A promised file the source app never materialises (browser, Photos, Mail)
/// leaves the platform callback uncalled. Before these bounds, that hung the
/// drop session and froze the whole app — no exception, no crash report.
void main() {
  test('a delivery that never arrives gives up instead of hanging', () async {
    final started = Completer<void>();
    final out = await awaitDelivery<int>(
      'never',
      (_) => started.complete(), // deliberately never completes `done`
      timeout: const Duration(milliseconds: 50),
    );
    expect(started.isCompleted, isTrue, reason: 'the read should have begun');
    expect(out, isNull);
  });

  test('a normal delivery is returned untouched', () async {
    final out = await awaitDelivery<int>('ok', (done) => done.complete(7));
    expect(out, 7);
  });

  test('a delivery arriving late still counts if inside the budget', () async {
    final out = await awaitDelivery<int>(
      'slow',
      (done) => Timer(const Duration(milliseconds: 20), () => done.complete(3)),
      timeout: const Duration(seconds: 5),
    );
    expect(out, 3);
  });

  test('null delivery (provider reported an error) is passed through', () async {
    final out = await awaitDelivery<int>('err', (done) => done.complete(null));
    expect(out, isNull);
  });

  test('a reader that throws on start does not escape', () async {
    final out = await awaitDelivery<int>(
      'throws',
      (_) => throw StateError('no reader'),
      timeout: const Duration(milliseconds: 50),
    );
    expect(out, isNull);
  });

  test('the timeout leaves room for a real image to transfer', () {
    // Small enough that a wedged drop frees the window quickly, long enough
    // that a large file off a slow disk still lands.
    expect(kImageReadTimeout.inSeconds, greaterThanOrEqualTo(10));
    expect(kImageReadTimeout.inSeconds, lessThanOrEqualTo(30));
  });
}
