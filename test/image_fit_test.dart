import 'dart:math';
import 'dart:typed_data';

import 'package:agent_dock/data/models/image_fit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _noisePng(int w, int h) {
  final rnd = Random(1);
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    p
      ..r = rnd.nextInt(256)
      ..g = rnd.nextInt(256)
      ..b = rnd.nextInt(256);
  }
  return img.encodePng(im, level: 1);
}

void main() {
  testWidgets('small PNG passes through unchanged', (tester) async {
    final png = _noisePng(64, 48);
    final out = await tester.runAsync(() => ImageFit.fit(png));
    expect(out!.ext, 'png');
    expect(identical(out.bytes, png), isTrue);
  });

  testWidgets('oversized PNG becomes a JPEG under the API limit', (
    tester,
  ) async {
    final png = _noisePng(3000, 2000);
    expect(png.length, greaterThan(ImageFit.maxBytes));
    final out = await tester.runAsync(() => ImageFit.fit(png));
    expect(out!.ext, 'jpg');
    expect(out.bytes.length, lessThanOrEqualTo(ImageFit.maxBytes));
    final decoded = img.decodeJpg(out.bytes)!;
    expect(max(decoded.width, decoded.height), lessThanOrEqualTo(2000));
    expect(decoded.width / decoded.height, closeTo(1.5, 0.01));
  });

  testWidgets('undecodable bytes return null', (tester) async {
    final out = await tester.runAsync(
      () => ImageFit.fit(Uint8List.fromList(List.filled(100, 7))),
    );
    expect(out, isNull);
  });
}
