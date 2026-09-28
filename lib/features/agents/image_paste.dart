import 'dart:async';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

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
  final out = <PastedImage>[];
  for (final item in reader.items) {
    if (out.length >= max) break;
    final match = _imageFormats.where((f) => item.canProvide(f.$1)).firstOrNull;
    if (match == null) continue;
    final (format, ext) = match;
    if (item.canProvide(Formats.plainText) && !item.isSynthesized(format)) {
      continue;
    }
    final bytes = await _readFile(item, format);
    if (bytes == null || bytes.isEmpty) continue;
    out.add((bytes: bytes, name: 'pasted-${out.length + 1}.$ext'));
  }
  return out;
}

Future<Uint8List?> _readFile(ClipboardDataReader item, FileFormat format) {
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
