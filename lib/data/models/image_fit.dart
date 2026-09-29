import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Shrink images the agent API would reject, on the device.
///
/// Mirrors ADSM `images.py`: over ~3.75 MB, a side past 8000 px, or a format
/// other than JPEG / PNG / GIF / WebP gets re-encoded as JPEG, longest side
/// ≤ 2000 px. Doing it here means any image the platform can decode works —
/// whatever its size, and whether or not the host has Pillow / sips / etc.
abstract final class ImageFit {
  /// Decoded bytes whose base64 stays under the 5 MB API limit.
  static const maxBytes = 3750000;
  static const maxEdge = 2000;
  static const hardMaxEdge = 8000;

  /// Mime sniffed from magic bytes, or null when not an agent-native format.
  static String? sniffMime(Uint8List raw) {
    bool at(int i, List<int> sig) {
      if (raw.length < i + sig.length) return false;
      for (var k = 0; k < sig.length; k++) {
        if (raw[i + k] != sig[k]) return false;
      }
      return true;
    }

    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return 'image/png';
    }
    if (at(0, const [0xFF, 0xD8])) return 'image/jpeg';
    if (at(0, 'GIF8'.codeUnits)) return 'image/gif';
    if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) {
      return 'image/webp';
    }
    return null;
  }

  /// [raw] as-is when the agent takes it, else a JPEG that fits.
  ///
  /// Returns null when the platform cannot decode the image; the caller can
  /// still send it and let the host try.
  static Future<({Uint8List bytes, String ext})?> fit(Uint8List raw) async {
    final mime = sniffMime(raw);
    final ext = switch (mime) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => null,
    };

    final ui.ImageDescriptor descriptor;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(raw);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } catch (_) {
      return null;
    }
    try {
      final w = descriptor.width;
      final h = descriptor.height;
      final longest = w > h ? w : h;
      if (ext != null && raw.length <= maxBytes && longest <= hardMaxEdge) {
        return (bytes: raw, ext: ext);
      }

      for (final (edge, quality) in const [
        (maxEdge, 85),
        (maxEdge, 70),
        (1400, 70),
        (1000, 60),
      ]) {
        final scale = longest > edge ? edge / longest : 1.0;
        final tw = (w * scale).round().clamp(1, edge);
        final th = (h * scale).round().clamp(1, edge);
        final codec = await descriptor.instantiateCodec(
          targetWidth: tw,
          targetHeight: th,
        );
        final frame = await codec.getNextFrame();
        codec.dispose();
        final image = frame.image;
        final rgba = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        final (iw, ih) = (image.width, image.height);
        image.dispose();
        if (rgba == null) return null;
        final pixels = rgba.buffer.asUint8List();
        final jpeg = await Isolate.run(
          () => encodeJpeg(pixels, iw, ih, quality),
        );
        if (jpeg.length <= maxBytes) return (bytes: jpeg, ext: 'jpg');
      }
      return null;
    } finally {
      descriptor.dispose();
    }
  }

  /// JPEG from straight RGBA [pixels] (transparent areas go white).
  static Uint8List encodeJpeg(Uint8List pixels, int w, int h, int quality) {
    final src = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: pixels.buffer,
      bytesOffset: pixels.offsetInBytes,
      numChannels: 4,
    );
    final flat = img.Image(width: w, height: h)
      ..clear(img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, src);
    return img.encodeJpg(flat, quality: quality);
  }
}
