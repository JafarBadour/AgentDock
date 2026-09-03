import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Base64 image payload for ACP `session/prompt` content blocks.
class PromptImage {
  const PromptImage({
    required this.mimeType,
    required this.data,
  });

  final String mimeType;

  /// Raw base64 (no data-URI prefix).
  final String data;

  Map<String, dynamic> toAcpBlock() => {
        'type': 'image',
        'mimeType': mimeType,
        'data': data,
      };

  Map<String, dynamic> toWire() => {
        'mimeType': mimeType,
        'data': data,
      };
}

/// A chat-local image file referenced from a persisted user message.
class ChatImageRef {
  const ChatImageRef({
    required this.relativePath,
    required this.mimeType,
    this.absolutePath,
  });

  /// Path under the app documents directory.
  final String relativePath;
  final String mimeType;
  final String? absolutePath;

  static String mimeForName(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.heic' => 'image/heic',
      '.heif' => 'image/heif',
      '.jpg' || '.jpeg' => 'image/jpeg',
      _ => 'image/jpeg',
    };
  }
}

/// Encode/decode image markers in [ChatMessage.content] and build ACP blocks.
abstract final class ChatImageCodec {
  static final RegExp markerRe = RegExp(
    r'<!--agentdock-img:([^|>]+)\|([^>]+)-->\s*',
  );

  static const maxImagesPerPrompt = 5;
  static const maxBytesPerImage = 1536 * 1024; // ~1.5 MB — keeps SSH/ADSM snappy

  /// Build ACP `prompt` content blocks (images first, then text).
  static List<Map<String, dynamic>> buildAcpBlocks({
    required String text,
    List<PromptImage> images = const [],
  }) {
    final blocks = <Map<String, dynamic>>[
      for (final img in images) img.toAcpBlock(),
    ];
    if (text.isNotEmpty) {
      blocks.add({'type': 'text', 'text': text});
    }
    return blocks;
  }

  /// Persist a picked image under `chat_images/<chatId>/` and return a ref.
  static Future<ChatImageRef> storePickedFile({
    required String chatId,
    required String sourcePath,
    required String fileName,
    int? byteLength,
  }) async {
    final len = byteLength ?? await File(sourcePath).length();
    if (len > maxBytesPerImage) {
      throw StateError(
        'Image too large (${(len / (1024 * 1024)).toStringAsFixed(1)} MB). '
        'Max is ${maxBytesPerImage ~/ (1024 * 1024)} MB.',
      );
    }
    final docs = await getApplicationDocumentsDirectory();
    final mime = ChatImageRef.mimeForName(fileName);
    final ext = p.extension(fileName).isEmpty
        ? _extForMime(mime)
        : p.extension(fileName).toLowerCase();
    final relative = p.join(
      'chat_images',
      chatId,
      '${const Uuid().v4()}$ext',
    );
    final dest = File(p.join(docs.path, relative));
    await dest.parent.create(recursive: true);
    await File(sourcePath).copy(dest.path);
    return ChatImageRef(
      relativePath: relative.replaceAll('\\', '/'),
      mimeType: mime,
      absolutePath: dest.path,
    );
  }

  static String _extForMime(String mime) => switch (mime) {
        'image/png' => '.png',
        'image/gif' => '.gif',
        'image/webp' => '.webp',
        'image/heic' => '.heic',
        'image/heif' => '.heif',
        _ => '.jpg',
      };

  /// Prefix content with markers so images survive SQLite + the outbound queue.
  static String encodeMessage({
    required String text,
    required List<ChatImageRef> images,
  }) {
    if (images.isEmpty) return text;
    final buf = StringBuffer();
    for (final img in images) {
      buf.writeln(
        '<!--agentdock-img:${img.relativePath}|${img.mimeType}-->',
      );
    }
    if (text.isNotEmpty) buf.write(text);
    return buf.toString();
  }

  /// Strip image markers; return plain text + refs (absolute paths filled when possible).
  static Future<({String text, List<ChatImageRef> images})> parse(
    String content,
  ) async {
    final images = <ChatImageRef>[];
    final text = content.replaceAllMapped(markerRe, (m) {
      images.add(
        ChatImageRef(
          relativePath: m.group(1)!.trim(),
          mimeType: m.group(2)!.trim(),
        ),
      );
      return '';
    }).trim();

    if (images.isEmpty) {
      return (text: content, images: const <ChatImageRef>[]);
    }

    final docs = await getApplicationDocumentsDirectory();
    final resolved = [
      for (final img in images)
        ChatImageRef(
          relativePath: img.relativePath,
          mimeType: img.mimeType,
          absolutePath: p.join(docs.path, img.relativePath),
        ),
    ];
    return (text: text, images: resolved);
  }

  /// Text-only view for bubbles (markers removed). Sync — no path resolve.
  static String displayText(String content) {
    return content.replaceAll(markerRe, '').trim();
  }

  /// Relative paths embedded in [content] (for thumbnails without async).
  static List<ChatImageRef> listRefs(String content) {
    return [
      for (final m in markerRe.allMatches(content))
        ChatImageRef(
          relativePath: m.group(1)!.trim(),
          mimeType: m.group(2)!.trim(),
        ),
    ];
  }

  static Future<List<PromptImage>> loadPromptImages(
    List<ChatImageRef> refs,
  ) async {
    final docs = await getApplicationDocumentsDirectory();
    final out = <PromptImage>[];
    for (final ref in refs) {
      final path = ref.absolutePath ?? p.join(docs.path, ref.relativePath);
      final file = File(path);
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      if (bytes.length > maxBytesPerImage) {
        throw StateError('Stored image exceeds size limit: ${ref.relativePath}');
      }
      out.add(
        PromptImage(
          mimeType: ref.mimeType,
          data: base64Encode(bytes),
        ),
      );
    }
    return out;
  }

  static Future<({String text, List<PromptImage> images})> toPromptPayload(
    String content,
  ) async {
    final parsed = await parse(content);
    final images = await loadPromptImages(parsed.images);
    return (text: parsed.text, images: images);
  }
}
