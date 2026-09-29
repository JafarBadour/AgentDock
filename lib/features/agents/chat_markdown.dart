import 'dart:isolate';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;

import '../../app/app_theme.dart';
import 'message_body.dart';

/// Markdown for chat bubbles, built for scrolling.
///
/// gpt_markdown re-ran a cascade of regexes per block on every first build
/// and emitted nested widgets per span; profiling a 950-message chat showed it
/// doubling the worst scroll frames. Here `package:markdown` (a linear parser)
/// produces an AST once per text — cached — and each block becomes a single
/// [Text.rich], so a row entering the viewport costs roughly its text layout.
class ChatMarkdown extends StatefulWidget {
  const ChatMarkdown({
    super.key,
    required this.text,
    this.style,
    this.dense = false,
    this.mentionTap,
  });

  final String text;
  final TextStyle? style;
  final bool dense;

  /// Tap handler for a project path (inline code or relative link), or null
  /// when [raw] is not a file mention. Null disables mention chips entirely.
  final VoidCallback? Function(String raw)? mentionTap;

  @override
  State<ChatMarkdown> createState() => _ChatMarkdownState();
}

class _ChatMarkdownState extends State<ChatMarkdown> {
  /// Recognizers live as long as the spans that hold them.
  final List<GestureRecognizer> _taps = [];

  void _disposeTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _disposeTaps();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _disposeTaps();
    final theme = Theme.of(context);
    final base =
        widget.style ?? theme.textTheme.bodyMedium?.copyWith(height: 1.45);
    final nodes = parseChatMarkdown(widget.text);
    final r = _Renderer(
      theme: theme,
      base: base ?? const TextStyle(),
      dense: widget.dense,
      mentionTap: widget.mentionTap,
      taps: _taps,
    );
    return r.column(r.blocks(nodes));
  }
}

final _parseCache = <String, List<md.Node>>{};

/// Enough for every message of a long chat plus its thinking folds.
const _parseCacheSize = 3000;

List<md.Node> _parse(String text) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
).parseLines(text.replaceAll('\r\n', '\n').split('\n'));

void _remember(String text, List<md.Node> nodes) {
  _parseCache[text] = nodes;
  if (_parseCache.length > _parseCacheSize) {
    _parseCache.remove(_parseCache.keys.first);
  }
}

/// Parse [text] (memoized, LRU — map literals keep insertion order) into
/// block nodes.
List<md.Node> parseChatMarkdown(String text) {
  final hit = _parseCache.remove(text);
  if (hit != null) return _parseCache[text] = hit;
  final nodes = _parse(text);
  _remember(text, nodes);
  return nodes;
}

/// Parse [texts] on a background isolate and fill the cache, so rows that
/// scroll in later only lay out text. AST nodes are plain objects, so the
/// result comes back via `Isolate.exit` without a copy.
Future<void> warmChatMarkdown(Iterable<String> texts) async {
  final todo = {
    for (final t in texts)
      if (t.isNotEmpty && !_parseCache.containsKey(t)) t,
  }.toList();
  if (todo.isEmpty) return;
  final parsed = await Isolate.run(() => [for (final t in todo) _parse(t)]);
  for (var i = 0; i < todo.length; i++) {
    _parseCache.putIfAbsent(todo[i], () => parsed[i]);
  }
  while (_parseCache.length > _parseCacheSize) {
    _parseCache.remove(_parseCache.keys.first);
  }
}

const _blockTags = {
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'blockquote', //
  'pre', 'hr', 'table', 'div', 'section', 'details',
};

const monoFamily = 'JetBrainsMono';
const monoPackage = 'gpt_markdown';

class _Renderer {
  _Renderer({
    required this.theme,
    required this.base,
    required this.dense,
    required this.mentionTap,
    required this.taps,
  });

  final ThemeData theme;
  final TextStyle base;
  final bool dense;
  final VoidCallback? Function(String raw)? mentionTap;
  final List<GestureRecognizer> taps;

  ColorScheme get scheme => theme.colorScheme;
  double get fontSize => base.fontSize ?? 14;

  /// Space between blocks — about one blank line, like the old renderer.
  double get gap => fontSize * (dense ? 0.6 : 0.8);

  Widget column(List<Widget> children) {
    if (children.length == 1) return children.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
  }

  /// Blocks for [nodes]; runs of inline nodes become one paragraph.
  List<Widget> blocks(List<md.Node>? nodes, {TextStyle? style}) {
    final out = <Widget>[];
    final pending = <md.Node>[];
    void flush() {
      if (pending.isEmpty) return;
      final spans = inlines(pending, style ?? base);
      pending.clear();
      if (spans.isEmpty) return;
      out.add(_paragraph(spans, style ?? base));
    }

    for (final n in nodes ?? const <md.Node>[]) {
      if (n is md.Element && _blockTags.contains(n.tag)) {
        flush();
        final w = block(n, style: style);
        if (w != null) out.add(w);
      } else {
        pending.add(n);
      }
    }
    flush();
    return out;
  }

  Widget _paragraph(List<InlineSpan> spans, TextStyle style) =>
      Text.rich(TextSpan(children: spans, style: style));

  Widget? block(md.Element e, {TextStyle? style}) {
    final s = style ?? base;
    switch (e.tag) {
      case 'p':
        final spans = inlines(e.children, s);
        return spans.isEmpty ? null : _paragraph(spans, s);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final h = _headingStyle(e.tag);
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _paragraph(inlines(e.children, h), h),
        );
      case 'ul' || 'ol':
        return _list(e, s);
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: scheme.primary.withValues(alpha: 0.45),
                width: 3,
              ),
            ),
          ),
          child: column(blocks(e.children, style: s)),
        );
      case 'pre':
        return _codeBlock(e);
      case 'hr':
        return Divider(height: gap, color: scheme.outlineVariant);
      case 'table':
        return _table(e, s);
      default:
        return column(blocks(e.children, style: s));
    }
  }

  TextStyle _headingStyle(String tag) {
    final t = theme.textTheme;
    final h = switch (tag) {
      'h1' => t.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.25),
      'h2' => t.titleMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
      'h3' => t.titleSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.3),
      'h4' => t.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      _ => t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    };
    return base.merge(h).copyWith(color: base.color);
  }

  Widget _list(md.Element list, TextStyle s) {
    final ordered = list.tag == 'ol';
    var n = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = <Widget>[];
    for (final child in list.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') continue;
      final marker = ordered ? '${n++}.' : '•';
      items.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: ordered ? fontSize * 1.8 : fontSize * 1.2,
              // Not selectable: a copied selection carries the list as HTML.
              child: SelectionContainer.disabled(child: Text(marker, style: s)),
            ),
            Expanded(child: column(blocks(child.children, style: s))),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: gap * 0.35),
          items[i],
        ],
      ],
    );
  }

  TextStyle get _mono => TextStyle(
    fontFamily: monoFamily,
    package: monoPackage,
    fontSize: dense ? 12 : 13,
    height: 1.4,
    color: base.color,
  );

  Widget _codeBlock(md.Element pre) {
    final codeEl = pre.children?.whereType<md.Element>().firstOrNull;
    final code = (codeEl ?? pre).textContent.replaceFirst(RegExp(r'\n$'), '');
    final lang = (codeEl?.attributes['class'] ?? '').replaceFirst(
      'language-',
      '',
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.chatInlineCodeBg,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: SelectionContainer.disabled(
                    child: Text(
                      lang,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                _CopyCodeButton(code: code),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(
              dense ? 10 : 12,
              0,
              dense ? 10 : 12,
              dense ? 10 : 12,
            ),
            child: Text(code, style: _mono, softWrap: false),
          ),
        ],
      ),
    );
  }

  Widget _table(md.Element table, TextStyle s) {
    // Rows as (isHeader, cells), padded to one column count.
    final rows = <(bool, List<md.Element>)>[];
    for (final section in table.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      for (final tr in section.children ?? const <md.Node>[]) {
        if (tr is! md.Element || tr.tag != 'tr') continue;
        rows.add((
          section.tag == 'thead',
          [
            for (final c in tr.children ?? const <md.Node>[])
              if (c is md.Element && (c.tag == 'th' || c.tag == 'td')) c,
          ],
        ));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.fold<int>(
      0,
      (m, r) => r.$2.length > m ? r.$2.length : m,
    );

    // Column widths from the longest cell text — no IntrinsicColumnWidth,
    // whose extra intrinsic layout of every cell cost ~6 ms per table while
    // scrolling. Long cells wrap at 320 px.
    final padH = dense ? 8.0 : 10.0;
    final charW = fontSize * 0.56;
    final widths = <int, TableColumnWidth>{};
    for (var c = 0; c < columns; c++) {
      var longest = 1;
      for (final (_, cells) in rows) {
        if (c < cells.length) {
          final len = cells[c].textContent.length;
          if (len > longest) longest = len;
        }
      }
      widths[c] = FixedColumnWidth(
        (longest * charW + padH * 2 + 2).clamp(48.0, 320.0),
      );
    }

    final headStyle = s.merge(
      theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: s.color,
      ),
    );
    final cellPad = EdgeInsets.symmetric(
      horizontal: padH,
      vertical: dense ? 4 : 6,
    );
    var stripe = false;
    final tableRows = <TableRow>[];
    for (final (header, cells) in rows) {
      final style = header ? headStyle : s;
      tableRows.add(
        TableRow(
          decoration: BoxDecoration(
            color: header
                ? scheme.surfaceContainerHigh
                : stripe
                ? scheme.onSurface.withValues(alpha: 0.04)
                : null,
          ),
          children: [
            for (var c = 0; c < columns; c++)
              c >= cells.length
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: cellPad,
                      child: Text.rich(
                        TextSpan(
                          children: inlines(cells[c].children, style),
                          style: style,
                        ),
                        textAlign: switch (cells[c].attributes['align']) {
                          'center' => TextAlign.center,
                          'right' => TextAlign.right,
                          _ => TextAlign.left,
                        },
                      ),
                    ),
          ],
        ),
      );
      if (!header) stripe = !stripe;
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        columnWidths: widths,
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        border: TableBorder.all(
          color: scheme.outlineVariant,
          width: 0.5,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        children: tableRows,
      ),
    );
  }

  /// Inline spans for [nodes] under [style].
  List<InlineSpan> inlines(List<md.Node>? nodes, TextStyle style) {
    final out = <InlineSpan>[];
    for (final n in nodes ?? const <md.Node>[]) {
      _inline(n, style, out);
    }
    return out;
  }

  void _inline(md.Node n, TextStyle style, List<InlineSpan> out) {
    if (n is md.Text) {
      out.add(TextSpan(text: n.text));
      return;
    }
    if (n is! md.Element) {
      out.add(TextSpan(text: n.textContent));
      return;
    }
    switch (n.tag) {
      case 'strong':
        _styled(n, style.copyWith(fontWeight: FontWeight.w700), out);
      case 'em':
        _styled(n, style.copyWith(fontStyle: FontStyle.italic), out);
      case 'del':
        _styled(n, style.copyWith(decoration: TextDecoration.lineThrough), out);
      case 'code':
        out.add(_inlineCode(n.textContent, style));
      case 'a':
        out.add(_link(n, style));
      case 'br':
        out.add(const TextSpan(text: '\n'));
      case 'img':
        final alt = n.attributes['alt'] ?? '';
        if (alt.isNotEmpty) {
          out.add(
            TextSpan(
              text: alt,
              style: style.copyWith(fontStyle: FontStyle.italic),
            ),
          );
        }
      case 'input':
        final checked = n.attributes.containsKey('checked');
        out.add(TextSpan(text: checked ? '☑ ' : '☐ '));
      default:
        _styled(n, style, out);
    }
  }

  void _styled(md.Element e, TextStyle style, List<InlineSpan> out) {
    out.add(TextSpan(style: style, children: inlines(e.children, style)));
  }

  InlineSpan _inlineCode(String code, TextStyle style) {
    final onTap = mentionTap?.call(code);
    final mono = style.copyWith(
      fontFamily: monoFamily,
      package: monoPackage,
      fontSize: (style.fontSize ?? fontSize) * 0.88,
      backgroundColor: AppColors.chatInlineCodeBg,
    );
    if (onTap == null) return TextSpan(text: code, style: mono);
    final tap = TapGestureRecognizer()..onTap = onTap;
    taps.add(tap);
    return TextSpan(
      text: code,
      style: mono.copyWith(color: scheme.primary),
      recognizer: tap,
      mouseCursor: SystemMouseCursors.click,
      semanticsLabel: 'File $code',
    );
  }

  InlineSpan _link(md.Element a, TextStyle style) {
    final url = (a.attributes['href'] ?? '').trim();
    final label = a.textContent.trim();
    if (url.isEmpty) return TextSpan(text: label);
    if (!url.contains('://')) {
      final onTap = mentionTap?.call(url);
      if (onTap != null) {
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: FileMentionChip(
            label: label.isEmpty ? url : label,
            dense: dense,
            onTap: onTap,
          ),
        );
      }
    }
    final link = classifyLink(url, label.isEmpty ? null : label);
    if (link.kind != RichLinkKind.generic) {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: LinkChip(link: link, dense: dense),
        ),
      );
    }
    final tap = TapGestureRecognizer()..onTap = () => openRichLink(url);
    taps.add(tap);
    return TextSpan(
      style: style.copyWith(color: scheme.primary),
      recognizer: tap,
      mouseCursor: SystemMouseCursors.click,
      children: inlines(a.children, style.copyWith(color: scheme.primary)),
    );
  }
}

class _CopyCodeButton extends StatelessWidget {
  const _CopyCodeButton({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Copy code',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      iconSize: 14,
      onPressed: () => Clipboard.setData(ClipboardData(text: code)),
      icon: Icon(
        Icons.copy_rounded,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
