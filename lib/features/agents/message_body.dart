import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:super_clipboard/super_clipboard.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_theme.dart';

/// A recognised link inside a chat message.
enum RichLinkKind { githubPr, githubIssue, jira, generic }

class RichLink {
  const RichLink({
    required this.kind,
    required this.url,
    required this.label,
    this.detail,
  });

  final RichLinkKind kind;
  final String url;
  final String label;
  final String? detail;
}

/// One segment of a message: plain text or a structured link.
sealed class MessageSegment {
  const MessageSegment();
}

class TextSegment extends MessageSegment {
  const TextSegment(this.text);
  final String text;
}

class LinkSegment extends MessageSegment {
  const LinkSegment(this.link);
  final RichLink link;
}

final _mdLink = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');
final _bareUrl = RegExp(
  r'https?://[^\s<>\)\]]+',
  caseSensitive: false,
);
final _githubPr = RegExp(
  r'^https?://(?:www\.)?github\.com/([^/]+)/([^/]+)/pull/(\d+)',
  caseSensitive: false,
);
final _githubIssue = RegExp(
  r'^https?://(?:www\.)?github\.com/([^/]+)/([^/]+)/issues/(\d+)',
  caseSensitive: false,
);
final _jiraBrowse = RegExp(
  r'^https?://([^/]+)/browse/([A-Z][A-Z0-9]+-\d+)',
  caseSensitive: false,
);
final _jiraTicketInPath = RegExp(
  r'/([A-Z][A-Z0-9]+-\d+)(?:[/?#]|$)',
);

/// Split [source] into text and link segments, preferring markdown links.
List<MessageSegment> parseMessageSegments(String source) {
  if (source.isEmpty) return const [];

  final hits = <({int start, int end, RichLink link})>[];

  for (final m in _mdLink.allMatches(source)) {
    final label = m.group(1)!.trim();
    final url = _cleanUrl(m.group(2)!);
    hits.add((start: m.start, end: m.end, link: classifyLink(url, label)));
  }

  for (final m in _bareUrl.allMatches(source)) {
    // Skip URLs already covered by a markdown link.
    final overlaps = hits.any((h) => m.start < h.end && m.end > h.start);
    if (overlaps) continue;
    final url = _cleanUrl(m.group(0)!);
    hits.add((start: m.start, end: m.end, link: classifyLink(url, null)));
  }

  hits.sort((a, b) => a.start.compareTo(b.start));

  final segments = <MessageSegment>[];
  var cursor = 0;
  for (final hit in hits) {
    if (hit.start < cursor) continue;
    if (hit.start > cursor) {
      segments.add(TextSegment(source.substring(cursor, hit.start)));
    }
    segments.add(LinkSegment(hit.link));
    cursor = hit.end;
  }
  if (cursor < source.length) {
    segments.add(TextSegment(source.substring(cursor)));
  }
  return segments;
}

RichLink classifyLink(String url, String? markdownLabel) {
  final pr = _githubPr.firstMatch(url);
  if (pr != null) {
    final owner = pr.group(1)!;
    final repo = pr.group(2)!;
    final n = pr.group(3)!;
    final short = '$repo#$n';
    final label = (markdownLabel != null &&
            markdownLabel.isNotEmpty &&
            markdownLabel != url)
        ? markdownLabel
        : short;
    return RichLink(
      kind: RichLinkKind.githubPr,
      url: url,
      label: label,
      detail: '$owner/$repo',
    );
  }

  final issue = _githubIssue.firstMatch(url);
  if (issue != null) {
    final owner = issue.group(1)!;
    final repo = issue.group(2)!;
    final n = issue.group(3)!;
    final short = '$repo#$n';
    final label = (markdownLabel != null &&
            markdownLabel.isNotEmpty &&
            markdownLabel != url)
        ? markdownLabel
        : short;
    return RichLink(
      kind: RichLinkKind.githubIssue,
      url: url,
      label: label,
      detail: '$owner/$repo',
    );
  }

  final jira = _jiraBrowse.firstMatch(url);
  if (jira != null) {
    final key = jira.group(2)!.toUpperCase();
    final label = (markdownLabel != null &&
            markdownLabel.isNotEmpty &&
            markdownLabel != url)
        ? markdownLabel
        : key;
    return RichLink(
      kind: RichLinkKind.jira,
      url: url,
      label: label,
      detail: key,
    );
  }

  // Atlassian URLs that are not /browse/KEY but still carry a ticket id.
  if (url.contains('atlassian.net')) {
    final key = _jiraTicketInPath.firstMatch(url)?.group(1)?.toUpperCase();
    if (key != null) {
      final label = (markdownLabel != null &&
              markdownLabel.isNotEmpty &&
              markdownLabel != url)
          ? markdownLabel
          : key;
      return RichLink(
        kind: RichLinkKind.jira,
        url: url,
        label: label,
        detail: key,
      );
    }
  }

  final label = (markdownLabel != null && markdownLabel.isNotEmpty)
      ? markdownLabel
      : _shortUrl(url);
  return RichLink(kind: RichLinkKind.generic, url: url, label: label);
}

/// Clipboard text that pastes cleanly into Microsoft Teams.
///
/// Teams auto-unfurls bare URLs and treats `Label <url>` as a labelled link.
/// Raw markdown `[Label](url)` often stays as plain text in Teams chat.
String toTeamsFriendlyCopy(String source) {
  return source.replaceAllMapped(_mdLink, (m) {
    final label = m.group(1)!.trim();
    final url = _cleanUrl(m.group(2)!);
    if (label.isEmpty || label == url) return url;
    return '$label <$url>';
  });
}

/// Render [source] markdown as HTML that pastes richly into Teams / Outlook.
///
/// Tables, bold, lists, code, and links survive the paste; plain markdown
/// usually does not.
String toTeamsHtml(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return '';

  final body = md.markdownToHtml(
    trimmed,
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: true,
  );

  // Light table styling so Teams keeps a readable grid after paste.
  return body
      .replaceAll(
        '<table>',
        '<table style="border-collapse:collapse;border:1px solid #c8c8c8;">',
      )
      .replaceAll(
        '<th>',
        '<th style="border:1px solid #c8c8c8;padding:6px 10px;background:#f3f2f1;text-align:left;">',
      )
      .replaceAll(
        '<td>',
        '<td style="border:1px solid #c8c8c8;padding:6px 10px;">',
      );
}

String _cleanUrl(String raw) {
  var url = raw.trim();
  // Trailing punctuation that often sticks to bare URLs in prose.
  while (url.isNotEmpty && '.,;:!?)]}>"\''.contains(url[url.length - 1])) {
    // Keep ')' if it balances an opening '(' inside the URL path/query.
    if (url.endsWith(')')) {
      final opens = '('.allMatches(url).length;
      final closes = ')'.allMatches(url).length;
      if (opens >= closes) break;
    }
    url = url.substring(0, url.length - 1);
  }
  return url;
}

String _shortUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return url.length <= 48 ? url : '${url.substring(0, 47)}…';
  }
  final host = uri.host.replaceFirst(RegExp(r'^www\.'), '');
  final path = uri.path;
  final shown = path.isEmpty || path == '/' ? host : '$host$path';
  return shown.length <= 48 ? shown : '${shown.substring(0, 47)}…';
}

Future<void> copyMessageForTeams(
  BuildContext context,
  String source,
) async {
  await Clipboard.setData(ClipboardData(text: toTeamsFriendlyCopy(source)));
}

/// Copy rendered HTML (+ plain fallback) so Teams paste keeps tables and links.
Future<void> copyMessageHtmlForTeams(
  BuildContext context,
  String source,
) async {
  final html = toTeamsHtml(source);
  final plain = toTeamsFriendlyCopy(source);

  final clipboard = SystemClipboard.instance;
  if (clipboard != null && html.isNotEmpty) {
    final item = DataWriterItem();
    item.add(Formats.htmlText(html));
    item.add(Formats.plainText(plain));
    await clipboard.write([item]);
  } else {
    await Clipboard.setData(ClipboardData(text: html.isEmpty ? plain : html));
  }
}

Future<void> openRichLink(String url) async {
  var raw = url.trim();
  if (!raw.contains('://')) raw = 'https://$raw';
  final uri = Uri.tryParse(raw);
  if (uri == null) return;
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) await launchUrl(uri, mode: LaunchMode.platformDefault);
  } catch (_) {}
}

/// Renders a chat message as Markdown (tables, code, lists, …)
/// with GitHub / Jira chips for recognised links.
class MessageBody extends StatelessWidget {
  const MessageBody({
    super.key,
    required this.text,
    this.style,
    this.dense = false,
  });

  final String text;
  final TextStyle? style;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = style ?? theme.textTheme.bodyMedium?.copyWith(height: 1.45);

    if (text.isEmpty) {
      return Text('…', style: base);
    }

    final mdTheme = GptMarkdownThemeData(
      brightness: theme.brightness,
      h1: theme.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      h2: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      h3: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      h4: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      h5: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      h6: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      autoAddDividerLineAfterH1: false,
      linkColor: scheme.primary,
      linkHoverColor: scheme.primary,
      hrLineColor: scheme.outlineVariant,
    );

    return Theme(
      data: theme.copyWith(
        extensions: <ThemeExtension<dynamic>>[mdTheme],
      ),
      child: GptMarkdown(
        text,
        style: base,
        onLinkTap: (url, _) => openRichLink(url),
        onCodeCopy: (code) {
          Clipboard.setData(ClipboardData(text: code));
        },
        linkBuilder: (context, span, url, _) {
          final label = span is TextSpan ? span.toPlainText() : '';
          final link = classifyLink(
            url,
            label.trim().isEmpty ? null : label.trim(),
          );
          if (link.kind == RichLinkKind.generic) {
            return Text.rich(span);
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: _LinkChip(link: link, dense: dense),
          );
        },
        styleSheet: GptMarkdownStyleSheet(
          table: TableStyle(
            borderColor: scheme.outlineVariant,
            borderWidth: 0.5,
            borderRadius: const Radius.circular(8),
            headerBackground: scheme.surfaceContainerHigh,
            headerTextStyle: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            rowStripeColor: scheme.onSurface.withValues(alpha: 0.04),
            cellPadding: EdgeInsets.symmetric(
              horizontal: dense ? 8 : 10,
              vertical: dense ? 4 : 6,
            ),
          ),
          codeBlock: CodeBlockStyle(
            backgroundColor: AppColors.chatInlineCodeBg,
            borderColor: scheme.outlineVariant.withValues(alpha: 0.35),
            borderWidth: 0.5,
            borderRadius: const Radius.circular(8),
            padding: EdgeInsets.all(dense ? 10 : 12),
            fontSize: dense ? 12 : 13,
          ),
          heading: const HeadingStyle(
            showDivider: false,
            padding: EdgeInsets.only(top: 4, bottom: 2),
          ),
          blockQuote: BlockQuoteStyle(
            barColor: scheme.primary.withValues(alpha: 0.45),
            barWidth: 3,
          ),
        ),
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.link, this.dense = false});

  final RichLink link;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color bg, Color fg, IconData icon) = switch (link.kind) {
      RichLinkKind.githubPr => (
          const Color(0xFF238636).withValues(alpha: 0.18),
          const Color(0xFF3FB950),
          Icons.merge_type_rounded,
        ),
      RichLinkKind.githubIssue => (
          const Color(0xFF1F6FEB).withValues(alpha: 0.18),
          const Color(0xFF58A6FF),
          Icons.error_outline_rounded,
        ),
      RichLinkKind.jira => (
          const Color(0xFF0052CC).withValues(alpha: 0.18),
          const Color(0xFF4C9AFF),
          Icons.confirmation_number_outlined,
        ),
      RichLinkKind.generic => (
          theme.colorScheme.primary.withValues(alpha: 0.12),
          theme.colorScheme.primary,
          Icons.link_rounded,
        ),
    };

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => openRichLink(link.url),
        onLongPress: () => copyMessageForTeams(
          context,
          '${link.label} <${link.url}>',
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 6 : 8,
            vertical: dense ? 2 : 4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: dense ? 12 : 14, color: fg),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  link.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: dense ? 11 : 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
