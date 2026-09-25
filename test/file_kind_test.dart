import 'package:agent_dock/services/file_kind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fileKindFor', () {
    test('classifies by extension', () {
      expect(fileKindFor('README.md'), FileKind.markdown);
      expect(fileKindFor('docs/guide.markdown'), FileKind.markdown);
      expect(fileKindFor('report.pdf'), FileKind.pdf);
      expect(fileKindFor('lib/main.dart'), FileKind.text);
      expect(fileKindFor('pubspec.yaml'), FileKind.text);
      expect(fileKindFor('screenshot.PNG'), FileKind.image);
      expect(fileKindFor('app-release.apk'), FileKind.binary);
    });

    test('knows extensionless text files', () {
      expect(fileKindFor('Dockerfile'), FileKind.text);
      expect(fileKindFor('project/Makefile'), FileKind.text);
      expect(fileKindFor('LICENSE'), FileKind.text);
      expect(fileKindFor('.gitignore'), FileKind.text);
    });

    test('only viewable kinds can be shown in app', () {
      expect(FileKind.markdown.isViewable, isTrue);
      expect(FileKind.pdf.isViewable, isTrue);
      expect(FileKind.text.isViewable, isTrue);
      expect(FileKind.image.isViewable, isTrue);
      expect(FileKind.binary.isViewable, isFalse);
    });
  });

  group('parseFileMention', () {
    String? path(String raw) => parseFileMention(raw)?.path;

    test('accepts paths agents actually write', () {
      expect(path('lib/main.dart'), 'lib/main.dart');
      expect(path('README.md'), 'README.md');
      expect(path('/home/jafar/Arts/AgentDock/pubspec.yaml'),
          '/home/jafar/Arts/AgentDock/pubspec.yaml');
      expect(path('./scripts/build.sh'), 'scripts/build.sh');
      expect(path('~/notes.md'), '~/notes.md');
      expect(path('Dockerfile'), 'Dockerfile');
    });

    test('strips decoration and prose punctuation', () {
      expect(path('`lib/main.dart`'), 'lib/main.dart');
      expect(path('(docs/plan.md)'), 'docs/plan.md');
      expect(path('"report.pdf"'), 'report.pdf');
      expect(path('see lib/main.dart.'.split(' ').last), 'lib/main.dart');
      expect(path('**notes.md**'), 'notes.md');
    });

    test('keeps the line number out of the path', () {
      final m = parseFileMention('lib/features/agents/chat_screen.dart:1505');
      expect(m?.path, 'lib/features/agents/chat_screen.dart');
      expect(m?.line, 1505);

      final col = parseFileMention('lib/main.dart:42:7');
      expect(col?.path, 'lib/main.dart');
      expect(col?.line, 42);

      final hash = parseFileMention('src/app.ts#L10-L20');
      expect(hash?.path, 'src/app.ts');
      expect(hash?.line, 10);
    });

    test('rejects things that only look like paths', () {
      expect(parseFileMention('flutter analyze'), isNull);
      expect(parseFileMention('--no-tree-shake-icons'), isNull);
      expect(parseFileMention('v1.2.3'), isNull);
      expect(parseFileMention('e.g.'), isNull);
      expect(parseFileMention('https://github.com/a/b.md'), isNull);
      expect(parseFileMention('lib/**/*.dart'), isNull);
      expect(parseFileMention('node_modules/'), isNull);
      expect(parseFileMention('FOO=bar.txt'), isNull);
      expect(parseFileMention('Chat::close'), isNull);
      expect(parseFileMention(''), isNull);
      expect(parseFileMention('some random sentence'), isNull);
    });

    test('exposes name and kind for the sheet', () {
      final m = parseFileMention('docs/design/plan.md')!;
      expect(m.name, 'plan.md');
      expect(m.kind, FileKind.markdown);
    });
  });
}
