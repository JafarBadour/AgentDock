import 'package:agent_dock/services/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ADSM channel closed sticky banner', () {
    test('Bad state: ADSM channel closed is transient', () {
      final err = StateError('ADSM channel closed');
      expect(err.toString(), contains('Bad state: ADSM channel closed'));
      expect(classifySshFailure(err), SshFailureKind.network);
      expect(isTransientBridgeError(err), isTrue);
      expect(
        isTransientBridgeErrorText('Bad state: ADSM channel closed'),
        isTrue,
      );
    });

    test('screen-local sticky copy would be cleared when live again', () {
      // Mirrors ChatScreen._bindRuntime: once reconnect succeeds (closed=false),
      // a prior transient _error must not keep painting the red banner.
      String? screenError = 'Bad state: ADSM channel closed';
      const runtimeClosed = false;
      const reconnecting = false;
      if (reconnecting || !runtimeClosed) {
        if (screenError != null && isTransientBridgeErrorText(screenError)) {
          screenError = null;
        }
      }
      expect(screenError, isNull);
    });

    test('fatal errors still stick when the session stays closed', () {
      String? screenError;
      const runtimeClosed = true;
      const reconnecting = false;
      const lastError =
          'Could not reconnect after 8 attempts. Tap Reconnect to try again — your chat history is kept.';
      if (reconnecting || !runtimeClosed) {
        if (screenError != null && isTransientBridgeErrorText(screenError)) {
          screenError = null;
        }
      } else if (!isTransientBridgeErrorText(lastError)) {
        screenError = lastError;
      }
      expect(screenError, lastError);
    });
  });
}
