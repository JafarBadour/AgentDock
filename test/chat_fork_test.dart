import 'package:agentplantation/services/chat_fork.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatForkService.forkTitle', () {
    test('marks a fork without touching the original name', () {
      expect(
        ChatForkService.forkTitle('Fix login', const {}),
        'Fix login (fork)',
      );
    });

    test('numbers repeat forks of the same chat', () {
      expect(
        ChatForkService.forkTitle('Fix login', {'Fix login (fork)'}),
        'Fix login (fork 2)',
      );
      expect(
        ChatForkService.forkTitle('Fix login', {
          'Fix login (fork)',
          'Fix login (fork 2)',
        }),
        'Fix login (fork 3)',
      );
    });

    test('forking a fork stays one level deep, not "(fork) (fork)"', () {
      expect(
        ChatForkService.forkTitle('Fix login (fork)', {'Fix login (fork)'}),
        'Fix login (fork 2)',
      );
      expect(
        ChatForkService.forkTitle('Fix login (fork 2)', {
          'Fix login (fork)',
          'Fix login (fork 2)',
        }),
        'Fix login (fork 3)',
      );
    });

    test('an unnamed chat still gets a usable title', () {
      expect(ChatForkService.forkTitle('   ', const {}), 'Agent (fork)');
    });

    test('trims the source name', () {
      expect(
        ChatForkService.forkTitle('  Fix login  ', const {}),
        'Fix login (fork)',
      );
    });

    test('a name merely containing "fork" is left alone', () {
      expect(
        ChatForkService.forkTitle('fork the repo', const {}),
        'fork the repo (fork)',
      );
    });
  });
}
