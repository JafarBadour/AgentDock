import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../data/secure/safe_log.dart';

/// Image bytes pulled off the clipboard or a keyboard (GIF / sticker) insert.
typedef PastedImage = ({Uint8List bytes, String name});

/// Preferred first: formats the agent takes as-is, then ones the host converts.
const _imageFormats = <(SimpleFileFormat, String)>[
  (Formats.png, 'png'),
  (Formats.jpeg, 'jpg'),
  (Formats.gif, 'gif'),
  (Formats.webp, 'webp'),
  (Formats.heic, 'heic'),
  (Formats.heif, 'heif'),
  (Formats.tiff, 'tiff'),
];

/// MIME types accepted from Android keyboard content insertion.
const kInsertableImageMimeTypes = <String>[
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/heic',
  'image/heif',
];

String extForImageMime(String mime) => switch (mime.toLowerCase()) {
  'image/png' => 'png',
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  'image/heic' => 'heic',
  'image/heif' => 'heif',
  _ => 'jpg',
};

/// Images on the system clipboard, one per clipboard item (at most [max]).
///
/// An item that also carries plain text — Word / Excel put a rendered PNG
/// next to the copied text — counts as text, unless the image is a copied
/// image *file* (Finder / Explorer), which the user clearly meant to attach.
Future<List<PastedImage>> readClipboardImages({int max = 5}) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null || max <= 0) return const [];
  final ClipboardReader reader;
  try {
    reader = await clipboard.read();
  } catch (e) {
    SafeLog.d('clipboard read failed', e);
    return const [];
  }
  return _readImages(reader.items, max: max, prefix: 'pasted', skipText: true);
}

/// Images from a drag-and-drop session (image data or image files).
Future<List<PastedImage>> readDroppedImages(
  Iterable<DataReader> readers, {
  int max = 5,
}) => _readImages(readers, max: max, prefix: 'dropped', skipText: false);

/// Image file extensions accepted from a copied / dropped file of a format
/// the platform does not expose as image data. The device or host converts.
const _imageFileExts = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'heif', 'tif', 'tiff', //
  'bmp', 'avif',
};

Future<List<PastedImage>> _readImages(
  Iterable<DataReader> items, {
  required int max,
  required String prefix,
  required bool skipText,
}) async {
  final out = <PastedImage>[];
  for (final item in items) {
    if (out.length >= max) break;
    final match = _imageFormats.where((f) => item.canProvide(f.$1)).firstOrNull;
    if (match != null) {
      final (format, ext) = match;
      if (skipText &&
          item.canProvide(Formats.plainText) &&
          !item.isSynthesized(format)) {
        continue;
      }
      final bytes = await _readFile(item, format);
      if (bytes != null && bytes.isNotEmpty) {
        out.add((bytes: bytes, name: '$prefix-${out.length + 1}.$ext'));
        continue;
      }
    }
    final file = await _readImageFileUri(item);
    if (file != null) out.add(file);
  }
  return out;
}

/// A copied / dropped image file by path, for formats with no image flavor.
Future<PastedImage?> _readImageFileUri(DataReader item) async {
  if (!item.canProvide(Formats.fileUri)) return null;
  try {
    final got = Completer<Uri?>();
    final progress = item.getValue<Uri>(
      Formats.fileUri,
      (v) async {
        if (!got.isCompleted) got.complete(v);
      },
      onError: (_) {
        if (!got.isCompleted) got.complete(null);
      },
    );
    if (progress == null) return null;
    final uri = await got.future;
    if (uri == null || !uri.isScheme('file')) return null;
    final path = uri.toFilePath();
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    if (!_imageFileExts.contains(ext)) return null;
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return null;
    return (bytes: bytes, name: path.split(RegExp(r'[\\/]')).last);
  } catch (e) {
    SafeLog.d('image file read failed', e);
    return null;
  }
}

Future<Uint8List?> _readFile(DataReader item, FileFormat format) {
  final done = Completer<Uint8List?>();
  void fail(Object e) {
    SafeLog.d('clipboard image read failed', e);
    if (!done.isCompleted) done.complete(null);
  }

  final progress = item.getFile(format, (file) async {
    try {
      final bytes = await file.readAll();
      if (!done.isCompleted) done.complete(bytes);
    } catch (e) {
      fail(e);
    }
  }, onError: fail);
  if (progress == null && !done.isCompleted) done.complete(null);
  return done.future;
}

/// Accepts images dragged onto [child] (Finder / Explorer / browsers /
/// other apps) and hands them to [onImages], with a highlight while hovering.
class ImageDropRegion extends StatefulWidget {
  const ImageDropRegion({
    super.key,
    required this.onImages,
    required this.child,
    this.max = 5,
  });

  final Future<void> Function(List<PastedImage> images) onImages;
  final Widget child;
  final int max;

  @override
  State<ImageDropRegion> createState() => _ImageDropRegionState();
}

class _ImageDropRegionState extends State<ImageDropRegion> {
  bool _over = false;

  static final _formats = <DataFormat>[
    for (final (f, _) in _imageFormats) f,
    Formats.fileUri,
  ];

  void _setOver(bool v) {
    if (_over != v && mounted) setState(() => _over = v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropRegion(
      formats: _formats,
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        final ok = event.session.allowedOperations.contains(DropOperation.copy);
        _setOver(ok);
        return ok ? DropOperation.copy : DropOperation.none;
      },
      onDropLeave: (_) => _setOver(false),
      onDropEnded: (_) => _setOver(false),
      onPerformDrop: (event) async {
        _setOver(false);
        final messenger = ScaffoldMessenger.maybeOf(context);
        final readers = [
          for (final item in event.session.items)
            if (item.dataReader != null) item.dataReader!,
        ];
        final images = await readDroppedImages(readers, max: widget.max);
        if (images.isEmpty) {
          messenger?.showSnackBar(
            const SnackBar(content: Text('Only images can be dropped here')),
          );
          return;
        }
        await widget.onImages(images);
      },
      child: Stack(
        children: [
          widget.child,
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    border: Border.all(color: scheme.primary, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_outlined,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        const Text('Drop images to attach'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
