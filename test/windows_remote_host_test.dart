import 'package:agentplantation/services/local_host_bootstrap.dart';
import 'package:agentplantation/services/ssh_service.dart';
import 'package:agentplantation/services/windows_local_agent.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Windows PC reached over SSH (Git Bash as the sshd shell), the way
/// another device sees a This PC install — often through a bastion.
void main() {
  group('isWindowsUname', () {
    test('Git Bash, MSYS2 and Cygwin are Windows', () {
      expect(SshService.isWindowsUname('MINGW64_NT-10.0-26200\n'), isTrue);
      expect(SshService.isWindowsUname('MSYS_NT-10.0-22631'), isTrue);
      expect(SshService.isWindowsUname('CYGWIN_NT-10.0'), isTrue);
    });

    test('Linux and macOS are not', () {
      expect(SshService.isWindowsUname('Linux'), isFalse);
      expect(SshService.isWindowsUname('Darwin\n'), isFalse);
      expect(SshService.isWindowsUname(''), isFalse);
    });
  });

  group('windowsPathFromMsys', () {
    test('a Git Bash drive path becomes a native one', () {
      expect(windowsPathFromMsys('/c/Users/jafer/Arts'), 'C:/Users/jafer/Arts');
      expect(windowsPathFromMsys('/d/work'), 'D:/work');
      expect(windowsPathFromMsys('/c'), 'C:/');
      expect(windowsPathFromMsys('/c/'), 'C:/');
    });

    test('anything else is left alone', () {
      expect(windowsPathFromMsys('C:/Users/jafer'), 'C:/Users/jafer');
      expect(windowsPathFromMsys('/home/jafer'), '/home/jafer');
      expect(windowsPathFromMsys('/cd/x'), '/cd/x');
      expect(windowsPathFromMsys('relative/c/x'), 'relative/c/x');
    });
  });

  group('versionFromStatus', () {
    test('reads the version out of `adsm status`', () {
      expect(
        WindowsLocalAgent.versionFromStatus(
          '{"id":1,"result":{"pid":19364,"workers":2,"seq":20182,'
          '"version":"0.7.4"}}\n',
        ),
        '0.7.4',
      );
    });

    test('a daemon that is not running has no version', () {
      expect(
        WindowsLocalAgent.versionFromStatus('ADSM not running (no socket)\n'),
        isNull,
      );
      expect(WindowsLocalAgent.versionFromStatus('{not json'), isNull);
    });
  });
}
