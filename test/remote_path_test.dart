import 'package:agentplantation/data/models/remote_path.dart';
import 'package:agentplantation/services/local_host_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeRemotePath', () {
    test('keeps POSIX paths rooted at /', () {
      expect(normalizeRemotePath(''), '/');
      expect(normalizeRemotePath('/'), '/');
      expect(normalizeRemotePath('/home/me/'), '/home/me');
      expect(normalizeRemotePath('home/me'), '/home/me');
    });

    test('keeps Windows drive paths instead of prefixing /', () {
      expect(normalizeRemotePath(r'C:\Users\jafer'), 'C:/Users/jafer');
      expect(normalizeRemotePath('C:/Users/jafer/'), 'C:/Users/jafer');
      expect(normalizeRemotePath('/C:/Users/jafer'), 'C:/Users/jafer');
      expect(normalizeRemotePath('c:'), 'C:/');
      expect(normalizeRemotePath(r'C:\'), 'C:/');
      expect(normalizeRemotePath(r'D:\a\\b'), 'D:/a/b');
    });

    test('is idempotent', () {
      for (final p in ['/a/b', 'C:/Users', 'C:/']) {
        expect(normalizeRemotePath(normalizeRemotePath(p)), p);
      }
    });
  });

  test('parent, join, basename and roots on both shapes', () {
    expect(parentRemotePath('/home/me'), '/home');
    expect(parentRemotePath('/home'), '/');
    expect(parentRemotePath('/'), isNull);
    expect(parentRemotePath('C:/Users/jafer'), 'C:/Users');
    expect(parentRemotePath('C:/Users'), 'C:/');
    expect(parentRemotePath('C:/'), isNull);

    expect(joinRemotePath('/', 'etc'), '/etc');
    expect(joinRemotePath('/home', 'me'), '/home/me');
    expect(joinRemotePath('C:/', 'Users'), 'C:/Users');
    expect(joinRemotePath('C:/Users', 'jafer'), 'C:/Users/jafer');

    expect(remoteBasename('/'), 'root');
    expect(remoteBasename('C:/'), 'root');
    expect(remoteBasename(r'C:\Users\jafer\Arts'), 'Arts');
    expect(remoteBasename('/home/me/proj/'), 'proj');
  });

  test('isUnderRemoteRoot and isAbsoluteRemotePath', () {
    expect(isUnderRemoteRoot('C:/', 'C:/Users/x'), isTrue);
    expect(isUnderRemoteRoot('C:/Users', 'C:/Users/x'), isTrue);
    expect(isUnderRemoteRoot('C:/Users', 'C:/UsersX'), isFalse);
    expect(isUnderRemoteRoot('/home/me', '/home/me/a'), isTrue);
    expect(isAbsoluteRemotePath('C:/x'), isTrue);
    expect(isAbsoluteRemotePath(r'd:\x'), isTrue);
    expect(isAbsoluteRemotePath('/x'), isTrue);
    expect(isAbsoluteRemotePath('src/main.dart'), isFalse);
  });

  test('isLocalFolderPathForThisOs rejects the other OS shape', () {
    expect(
      isLocalFolderPathForThisOs('/Users/me/Arts', windows: true),
      isFalse,
    );
    expect(isLocalFolderPathForThisOs('C:/Users/me', windows: true), isTrue);
    expect(
      isLocalFolderPathForThisOs('/Users/me/Arts', windows: false),
      isTrue,
    );
    expect(isLocalFolderPathForThisOs('C:/Users/me', windows: false), isFalse);
  });
}
