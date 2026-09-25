import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../services/file_kind.dart';
import 'message_body.dart';
import 'pdf_viewer_screen.dart';

/// Open a local file in the right in-app viewer.
///
/// PDFs go to [PdfViewerScreen]; Markdown, text/code and images go to
/// [FileViewerScreen]. Anything else has no viewer — callers should offer a
/// download instead (see [FileKindX.isViewable]).
Future<void> openLocalFile(
  BuildContext context, {
  required String filePath,
  required String title,
  VoidCallback? onDownload,
  VoidCallback? onShare,
}) {
  final kind = fileKindFor(title);
  if (kind == FileKind.pdf) {
    return PdfViewerScreen.open(
      context,
      filePath: filePath,
      title: title,
      onDownload: onDownload,
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => FileViewerScreen(
        filePath: filePath,
        title: title,
        onDownload: onDownload,
        onShare: onShare,
      ),
    ),
  );
}

/// Viewer for Markdown, plain text / code, and images.
///
/// Full-screen on phone; embeddable in the desktop right panel, like
/// [PdfViewerScreen].
class FileViewerScreen extends StatefulWidget {
  const FileViewerScreen({
    super.key,
    required this.filePath,
    required this.title,
    this.embedded = false,
    this.onBack,
    this.onDownload,
    this.onShare,
  });

  final String filePath;
  final String title;
  final bool embedded;
  final VoidCallback? onBack;
  final VoidCallback? onDownload;
  final VoidCallback? onShare;

  /// Text beyond this is shown truncated — a 50 MB log should not be parsed.
  static const int maxTextBytes = 256 * 1024;

  /// Markdown longer than this opens as source: rendering it builds a widget
  /// per block, which is what makes a long document crawl on a phone.
  static const int maxRenderedMarkdownBytes = 128 * 1024;

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  String? _content;
  String? _error;
  bool _truncated = false;
  bool _loading = true;

  /// Markdown only: show the source instead of the rendered document.
  bool _raw = false;

  /// Text only: soft-wrap long lines instead of scrolling sideways.
  bool _wrap = false;

  FileKind get _kind => fileKindFor(widget.title);

  @override
  void initState() {
    super.initState();
    if (_kind != FileKind.image) _load();
  }

  @override
  void didUpdateWidget(covariant FileViewerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _content = null;
      _error = null;
      _truncated = false;
      _loading = true;
      if (_kind != FileKind.image) {
        _load();
      } else {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'File missing';
        });
        return;
      }
      final length = await file.length();
      List<int> bytes;
      var truncated = false;
      if (length > FileViewerScreen.maxTextBytes) {
        final handle = await file.open();
        try {
          bytes = await handle.read(FileViewerScreen.maxTextBytes);
        } finally {
          await handle.close();
        }
        truncated = true;
      } else {
        bytes = await file.readAsBytes();
      }
      // Files from a remote box are not guaranteed valid UTF-8.
      final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
      if (!mounted) return;
      setState(() {
        _content = text;
        _truncated = truncated;
        _loading = false;
        if (_kind == FileKind.markdown &&
            bytes.length > FileViewerScreen.maxRenderedMarkdownBytes) {
          _raw = true;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read file: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actions = <Widget>[
      if (_kind == FileKind.markdown && _content != null)
        IconButton(
          tooltip: _raw ? 'Show formatted' : 'Show source',
          icon: Icon(_raw ? Icons.article_outlined : Icons.code),
          onPressed: () => setState(() => _raw = !_raw),
        ),
      if (_kind == FileKind.text && _content != null)
        IconButton(
          tooltip: _wrap ? 'Stop wrapping lines' : 'Wrap long lines',
          icon: Icon(_wrap ? Icons.wrap_text : Icons.notes),
          onPressed: () => setState(() => _wrap = !_wrap),
        ),
      if (widget.onShare != null)
        IconButton(
          tooltip: 'Share',
          icon: const Icon(Icons.ios_share),
          onPressed: widget.onShare,
        ),
      if (widget.onDownload != null)
        IconButton(
          tooltip: 'Download',
          icon: const Icon(Icons.download),
          onPressed: widget.onDownload,
        ),
    ];

    final body = _buildBody(context);

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to files',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack,
                ),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: actions,
      ),
      body: body,
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);

    if (_kind == FileKind.image) {
      return _ImageBody(filePath: widget.filePath);
    }
    if (_kind == FileKind.binary) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No preview for this file type — download it instead.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    final content = _content ?? '';
    if (content.trim().isEmpty) {
      return const Center(child: Text('Empty file'));
    }

    final banner = _truncated
        ? Material(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Showing the first '
                      '${FileViewerScreen.maxTextBytes ~/ 1024} KB — '
                      'download the file for all of it',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          )
        : null;

    final Widget view;
    if (_kind == FileKind.markdown && !_raw) {
      view = GptMarkdownTheme(
        gptThemeData: chatGptMarkdownTheme(theme),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          child: MessageBody(
            text: content,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ),
      );
    } else {
      view = _MonospaceBody(text: content, wrap: _wrap);
    }

    if (banner == null) return view;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [banner, Expanded(child: view)],
    );
  }
}

class _MonospaceBody extends StatelessWidget {
  const _MonospaceBody({required this.text, required this.wrap});

  final String text;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Menlo', 'Courier New'],
          height: 1.45,
        );
    final body = SelectionArea(
      child: Text(
        text,
        style: style,
        softWrap: wrap,
      ),
    );
    final padded = Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
      child: body,
    );
    if (wrap) {
      return SingleChildScrollView(child: padded);
    }
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: padded,
      ),
    );
  }
}

class _ImageBody extends StatelessWidget {
  const _ImageBody({required this.filePath});

  final String filePath;

  @override
  Widget build(BuildContext context) {
    if (!File(filePath).existsSync()) {
      return const Center(child: Text('File missing'));
    }
    return ColoredBox(
      color: const Color(0xFF1C1C1F),
      child: InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Image.file(
            File(filePath),
            errorBuilder: (context, error, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not decode image\n$error',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
