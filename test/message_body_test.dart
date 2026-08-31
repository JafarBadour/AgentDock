import 'package:agent_dock/features/agents/message_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageBody', () {
    testWidgets('renders markdown tables and emphasis', (tester) async {
      const md = '''
| Name | Status |
|------|--------|
| Alpha | ok |
| Beta | pending |

This is **bold** and `code`.
''';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageBody(text: md),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Alpha'), findsWidgets);
      expect(find.textContaining('Status'), findsWidgets);
      expect(find.textContaining('pending'), findsWidgets);
      // Emphasis / inline code land in RichText spans — assert the body painted.
      expect(find.byType(MessageBody), findsOneWidget);
    });
  });

  group('parseMessageSegments', () {
    test('turns a GitHub PR markdown link into a chip segment', () {
      const src =
          'See [rubi-admin#406](https://github.com/colibri/rubi-admin/pull/406) please';
      final parts = parseMessageSegments(src);
      expect(parts, hasLength(3));
      expect(parts[0], isA<TextSegment>());
      final link = (parts[1] as LinkSegment).link;
      expect(link.kind, RichLinkKind.githubPr);
      expect(link.label, 'rubi-admin#406');
      expect(link.url, contains('/pull/406'));
      expect((parts[2] as TextSegment).text, ' please');
    });

    test('classifies bare Jira browse URLs', () {
      const src =
          'Ticket https://colibrigroup.atlassian.net/browse/AG-4085 landed';
      final parts = parseMessageSegments(src);
      final link = parts.whereType<LinkSegment>().single.link;
      expect(link.kind, RichLinkKind.jira);
      expect(link.label, 'AG-4085');
      expect(link.detail, 'AG-4085');
    });

    test('classifies GitHub issues', () {
      final link = classifyLink(
        'https://github.com/acme/widgets/issues/12',
        null,
      );
      expect(link.kind, RichLinkKind.githubIssue);
      expect(link.label, 'widgets#12');
    });

    test('prefers the markdown label when it is meaningful', () {
      final link = classifyLink(
        'https://github.com/acme/widgets/pull/9',
        'Fix the login redirect',
      );
      expect(link.kind, RichLinkKind.githubPr);
      expect(link.label, 'Fix the login redirect');
    });
  });

  group('toTeamsFriendlyCopy', () {
    test('rewrites markdown links to Label <url>', () {
      const src =
          'Approved [rubi-admin#406](https://github.com/colibri/rubi-admin/pull/406) '
          'and [AG-4085](https://colibrigroup.atlassian.net/browse/AG-4085).';
      final out = toTeamsFriendlyCopy(src);
      expect(out, contains('rubi-admin#406 <https://github.com/colibri/rubi-admin/pull/406>'));
      expect(out, contains('AG-4085 <https://colibrigroup.atlassian.net/browse/AG-4085>'));
      expect(out, isNot(contains('](')));
    });

    test('leaves bare URLs alone so Teams can unfurl them', () {
      const src = 'See https://github.com/acme/x/pull/1';
      expect(toTeamsFriendlyCopy(src), src);
    });
  });

  group('toTeamsHtml', () {
    test('renders tables and links as HTML', () {
      const src = '''
| PR | Status |
|----|--------|
| [rubi-admin#406](https://github.com/colibri/rubi-admin/pull/406) | merged |

**Done**
''';
      final html = toTeamsHtml(src);
      expect(html, contains('<table'));
      expect(html, contains('<th'));
      expect(html, contains('<td'));
      expect(html, contains('href="https://github.com/colibri/rubi-admin/pull/406"'));
      expect(html, contains('<strong>Done</strong>'));
    });

    test('keeps emphasis as HTML tags', () {
      expect(toTeamsHtml('**Done**'), contains('<strong>Done</strong>'));
    });
  });
}
