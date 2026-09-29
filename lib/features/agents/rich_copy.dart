import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:super_clipboard/super_clipboard.dart';

import 'chat_markdown.dart';
import 'message_body.dart';

/// [SelectionArea] for a rendered markdown message whose Copy (Cmd/Ctrl+C
/// and the context menu) puts HTML for the selected part of [source] on the
/// clipboard next to the plain text — so pasting into Teams / Outlook keeps
/// bold, lists, tables, code and links instead of flattening them.
class RichCopySelectionArea extends StatefulWidget {
  const RichCopySelectionArea({
    super.key,
    required this.source,
    required this.child,
  });

  /// Markdown the child renders.
  final String source;
  final Widget child;

  @override
  State<RichCopySelectionArea> createState() => _RichCopySelectionAreaState();
}

class _RichCopySelectionAreaState extends State<RichCopySelectionArea> {
  String _selected = '';

  Future<void> _copy() async {
    final plain = _selected;
    if (plain.isEmpty) return;
    await copyRichText(
      html: selectionToHtml(widget.source, plain),
      plain: plain,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (_) => _copy(),
        ),
      },
      child: SelectionArea(
        onSelectionChanged: (content) => _selected = content?.plainText ?? '',
        contextMenuBuilder: (context, state) {
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: state.contextMenuAnchors,
            buttonItems: [
              for (final item in state.contextMenuButtonItems)
                if (item.type == ContextMenuButtonType.copy)
                  item.copyWith(
                    onPressed: () {
                      _copy();
                      state.hideToolbar();
                    },
                  )
                else
                  item,
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Put [html] and [plain] on the clipboard as one item; plain only when
/// [html] is null or rich clipboard access is unavailable.
Future<void> copyRichText({
  required String? html,
  required String plain,
}) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard != null && html != null && html.isNotEmpty) {
    try {
      final item = DataWriterItem()
        ..add(Formats.htmlText(html))
        ..add(Formats.plainText(plain));
      await clipboard.write([item]);
      return;
    } catch (_) {}
  }
  await Clipboard.setData(ClipboardData(text: plain));
}

/// HTML for the part of markdown [source] whose rendered text is [selected].
///
/// Matching ignores whitespace (the renderer's line breaks between blocks
/// never line up with the source). Null when the selection cannot be located —
/// callers then copy plain text only.
String? selectionToHtml(String source, String selected) {
  final nodes = parseChatMarkdown(source);
  final index = _LeafIndex()..walk(nodes);
  final range = index.locate(_squash(selected));
  if (range == null) return null;
  final clipped = [for (final n in nodes) ?_clip(n, range.$1, range.$2, index)];
  if (clipped.isEmpty) return null;
  return styleHtmlForTeams(md.renderToHtml(clipped));
}

final _ws = RegExp(r'\s');

String _squash(String s) => s.replaceAll(_ws, '');

/// Rendered text of a leaf node (what the chat shows for it).
String? _leafText(md.Node n) {
  if (n is md.Text) return n.text;
  if (n is md.Element) {
    switch (n.tag) {
      case 'img':
        return n.attributes['alt'] ?? '';
      case 'input':
        return n.attributes.containsKey('checked') ? '☑' : '☐';
      case 'br' || 'hr':
        return '';
    }
    if (n.children == null) return n.textContent;
  }
  if (n is! md.Element) return n.textContent;
  return null;
}

/// Leaf positions in the whitespace-free rendered text of a message.
class _LeafIndex {
  final buf = StringBuffer();
  final Map<md.Node, (int, int)> spans = Map.identity();

  void walk(List<md.Node>? nodes) {
    for (final n in nodes ?? const <md.Node>[]) {
      final text = _leafText(n);
      if (text != null) {
        final start = buf.length;
        buf.write(_squash(text));
        spans[n] = (start, buf.length);
      } else {
        walk((n as md.Element).children);
      }
    }
  }

  /// [start, end) of [needle] — whole, else its longest locatable head and
  /// tail (a link chip may render a label the source does not contain).
  (int, int)? locate(String needle) {
    if (needle.isEmpty) return null;
    final hay = buf.toString();
    final at = hay.indexOf(needle);
    if (at >= 0) return (at, at + needle.length);

    const minPart = 6;
    if (needle.length < minPart * 2) return null;
    int? start;
    var headLen = 0;
    for (var len = needle.length - 1; len >= minPart; len--) {
      final i = hay.indexOf(needle.substring(0, len));
      if (i >= 0) {
        start = i;
        headLen = len;
        break;
      }
    }
    if (start == null) return null;
    var end = start + headLen;
    for (var len = needle.length - 1; len >= minPart; len--) {
      final i = hay.lastIndexOf(needle.substring(needle.length - len));
      if (i >= start) {
        if (i + len > end) end = i + len;
        break;
      }
    }
    return (start, end);
  }
}

md.Node? _clip(md.Node n, int s, int e, _LeafIndex index) {
  final span = index.spans[n];
  if (span != null) {
    final (a, b) = span;
    if (n is md.Element) {
      // br / hr: keep only strictly inside the selection.
      if (a == b) return (a > s && a < e) ? md.Element.empty(n.tag) : null;
      if (b <= s || a >= e) return null;
      return _copyElement(
        n,
        n.children == null ? null : [md.Text(_esc(n.textContent))],
      );
    }
    if (b <= s || a >= e) return null;
    return md.Text(_esc(_slice(n.textContent, s - a, e - a)));
  }

  final el = n as md.Element;
  final children = el.children ?? const <md.Node>[];
  if (el.tag == 'tr') {
    // Keep every cell of a touched row so columns stay aligned.
    final cells = [for (final c in children) _clip(c, s, e, index)];
    if (cells.every((c) => c == null)) return null;
    return _copyElement(el, [
      for (var i = 0; i < children.length; i++)
        cells[i] ?? _copyElement(children[i] as md.Element, const <md.Node>[]),
    ]);
  }
  final kept = [for (final c in children) ?_clip(c, s, e, index)];
  if (kept.isEmpty) return null;
  return _copyElement(el, kept);
}

md.Element _copyElement(md.Element src, List<md.Node>? children) {
  final out = children == null
      ? md.Element.empty(src.tag)
      : md.Element(src.tag, children);
  src.attributes.forEach((k, v) => out.attributes[k] = _escAttr(v));
  return out;
}

/// [text] cut to the non-whitespace characters [from, to) of it.
String _slice(String text, int from, int to) {
  var seen = 0;
  var start = from <= 0 ? 0 : -1;
  var end = text.length;
  for (var i = 0; i < text.length; i++) {
    if (_ws.hasMatch(text[i])) continue;
    if (seen == from && start < 0) start = i;
    seen++;
    if (seen == to) {
      end = i + 1;
      break;
    }
  }
  return start < 0 ? '' : text.substring(start, end);
}

String _esc(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);
String _escAttr(String s) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(s);
