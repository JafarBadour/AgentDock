import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/secure/safe_log.dart';
import '../../services/file_kind.dart';
import '../../services/remote_image_cache.dart';
import 'file_mention.dart';
import 'file_viewer_screen.dart';

/// Largest `data:` image decoded straight from the message text.
///
/// Inline base64 is the thing [stripInlineImages] exists to get rid of, so a
/// data URI is tolerated for something small an agent inlined on purpose and
/// refused above that — a real picture belongs in a file.
const int kMaxDataUriBytes = 512 * 1024;

/// How tall an inline image may be before it is scaled down to fit.
///
/// The transcript is a scrolling list whose frame budget is its text layout,
/// so a picture gets a bounded box rather than its natural height.
const double kChatImageMaxHeight = 320;

/// An image an agent referenced with `![alt](src)`, shown in the bubble.
///
/// `src` is whatever the agent wrote: a path on its own host (absolute, `~`,
/// or relative to the project root), or a small `data:` URI. Remote paths are
/// fetched once into [RemoteImageCache] and rendered from disk, so the bytes
/// never enter the transcript row.
///
/// `http(s)` sources are deliberately *not* fetched. Rendering one would turn
/// agent output into an outbound request from the user's device, which is both
/// a tracking vector and a way to make the app fetch something the user never
/// chose to load; those fall back to the alt text.
class ChatImage extends ConsumerStatefulWidget {
  const ChatImage({
    super.key,
    required this.src,
    required this.alt,
    this.style,
  });

  final String src;
  final String alt;

  /// Text style for the caption and fallbacks, so it matches the bubble.
  final TextStyle? style;

  @override
  ConsumerState<ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends ConsumerState<ChatImage> {
  /// Decoded `data:` payload, when the source was a data URI.
  Uint8List? _inline;

  String? _localPath;
  String? _remotePath;
  RemoteImageFailure? _failure;
  int? _bytes;
  bool _loading = true;

  /// The source the in-flight load belongs to, so a row that rebuilds with a
  /// new `src` does not adopt the previous image.
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(ChatImage old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src) _start();
  }

  void _start() {
    final src = widget.src;
    _loadedFor = src;
    _inline = null;
    _localPath = null;
    _remotePath = null;
    _failure = null;
    _bytes = null;

    final data = decodeDataUri(src);
    if (data != null) {
      _inline = data.bytes;
      _failure = data.failure;
      _bytes = data.bytes?.length ?? data.declaredBytes;
      _loading = false;
      return;
    }
    _loading = true;
    unawaited(_load(src));
  }

  Future<void> _load(String src) async {
    final scope = FileMentionScope.maybeOf(context);
    if (scope == null) {
      // No host to fetch from — the caller falls back to alt text.
      if (mounted && _loadedFor == src) {
        setState(() {
          _loading = false;
          _failure = RemoteImageFailure.missing;
        });
      }
      return;
    }
    final ssh = ref.read(sshServiceProvider);
    final cache = ref.read(remoteImageCacheProvider);
    try {
      final remote = await ssh.resolveAgentPath(
        scope.host,
        src,
        rootPath: scope.rootPath,
      );
      final result = await cache.resolve(scope.host, remote);
      if (!mounted || _loadedFor != src) return;
      setState(() {
        _remotePath = remote;
        _localPath = result.localPath;
        _failure = result.failure;
        _bytes = result.bytes;
        _loading = false;
      });
    } catch (e) {
      SafeLog.d('inline image load failed $src', e);
      if (!mounted || _loadedFor != src) return;
      setState(() {
        _failure = RemoteImageFailure.transferFailed;
        _loading = false;
      });
    }
  }

  String get _name {
    final src = widget.src;
    final slash = src.lastIndexOf('/');
    final name = slash >= 0 ? src.substring(slash + 1) : src;
    return name.isEmpty ? 'image' : name;
  }

  Future<void> _open() async {
    final path = _localPath;
    if (path == null) return;
    await openLocalFile(context, filePath: path, title: _name);
  }

  /// Hand a too-large or failed image to the existing mention sheet, which can
  /// download or share it even when the app will not preview it.
  Future<void> _openSheet() async {
    final scope = FileMentionScope.maybeOf(context);
    final remote = _remotePath;
    if (scope == null || remote == null) return;
    final mention = parseFileMention(remote);
    if (mention == null) return;
    await showFileMentionSheet(
      context,
      host: scope.host,
      rootPath: scope.rootPath,
      mention: mention,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? Theme.of(context).textTheme.bodyMedium;

    if (_loading) return _Placeholder(label: _name, style: style);

    final inline = _inline;
    final path = _localPath;
    if (inline != null) {
      return _frame(
        Image.memory(inline, fit: BoxFit.contain, errorBuilder: _broken),
        onTap: null,
      );
    }
    if (path != null) {
      return _frame(
        Image.file(File(path), fit: BoxFit.contain, errorBuilder: _broken),
        onTap: _open,
      );
    }
    return _Unavailable(
      label: _name,
      alt: widget.alt,
      failure: _failure,
      bytes: _bytes,
      style: style,
      onTap: _remotePath == null ? null : _openSheet,
    );
  }

  Widget _broken(BuildContext context, Object error, StackTrace? _) =>
      _Unavailable(
        label: _name,
        alt: widget.alt,
        failure: RemoteImageFailure.transferFailed,
        bytes: _bytes,
        style: widget.style ?? Theme.of(context).textTheme.bodyMedium,
        onTap: _remotePath == null ? null : _openSheet,
      );

  Widget _frame(Widget image, {VoidCallback? onTap}) {
    final caption = widget.alt.trim();
    final framed = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: kChatImageMaxHeight),
        child: image,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: onTap == null
              ? framed
              : InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(10),
                  child: framed,
                ),
        ),
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            caption,
            style: (widget.style ?? const TextStyle()).copyWith(
              fontSize: ((widget.style?.fontSize ?? 14) * 0.85),
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.label, this.style});

  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the agent pointed at, when the picture itself cannot be shown.
class _Unavailable extends StatelessWidget {
  const _Unavailable({
    required this.label,
    required this.alt,
    required this.failure,
    required this.bytes,
    required this.style,
    this.onTap,
  });

  final String label;
  final String alt;
  final RemoteImageFailure? failure;
  final int? bytes;
  final TextStyle? style;
  final VoidCallback? onTap;

  String get _reason => switch (failure) {
    RemoteImageFailure.tooLarge =>
      bytes == null ? 'too large to preview' : '${_mb(bytes!)} — too large',
    RemoteImageFailure.missing => 'not found on the host',
    RemoteImageFailure.transferFailed => 'could not be loaded',
    null => 'could not be loaded',
  };

  static String _mb(int b) => b < 1024 * 1024
      ? '${(b / 1024).toStringAsFixed(0)} KB'
      : '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_not_supported_outlined, size: 15,
              color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '${alt.trim().isEmpty ? label : alt.trim()} · $_reason',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: (style ?? const TextStyle()).copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return Align(alignment: Alignment.centerLeft, child: body);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: body,
      ),
    );
  }
}

/// A decoded `data:` image, or why it was refused.
class DataUriImage {
  const DataUriImage.bytes(this.bytes)
    : failure = null,
      declaredBytes = null;
  const DataUriImage.refused(this.failure, this.declaredBytes) : bytes = null;

  final Uint8List? bytes;
  final RemoteImageFailure? failure;
  final int? declaredBytes;
}

/// Decode `data:image/png;base64,…`, or null when [src] is not a data URI.
///
/// Returns a refusal rather than bytes past [kMaxDataUriBytes] — a big picture
/// pasted into the message text is exactly what balloons a transcript.
DataUriImage? decodeDataUri(String src) {
  if (!src.startsWith('data:')) return null;
  final comma = src.indexOf(',');
  if (comma < 0) return null;
  final header = src.substring(5, comma);
  if (!header.contains('base64')) return null;
  if (!header.startsWith('image/')) return null;
  final payload = src.substring(comma + 1);
  // 4 base64 chars per 3 bytes — check before decoding, not after.
  final approx = payload.length * 3 ~/ 4;
  if (approx > kMaxDataUriBytes) {
    return DataUriImage.refused(RemoteImageFailure.tooLarge, approx);
  }
  try {
    return DataUriImage.bytes(base64Decode(payload));
  } catch (_) {
    return const DataUriImage.refused(
      RemoteImageFailure.transferFailed,
      null,
    );
  }
}

/// True when [src] is something [ChatImage] can actually show, so the markdown
/// renderer can fall back to alt text instead of planting a dead box.
bool canShowChatImage(String src) {
  final trimmed = src.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith('data:')) return decodeDataUri(trimmed) != null;
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('//')) {
    return false;
  }
  return fileKindFor(trimmed) == FileKind.image;
}
