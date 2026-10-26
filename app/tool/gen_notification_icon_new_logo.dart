import 'dart:io';

import 'package:image/image.dart' as img;

/// Generates Android small-icon density assets from the supplied black/white
/// PandaPay logo. Black artwork becomes the alpha mask; white background is
/// transparent because Android tints small notification icons as one color.
void main() {
  final source = img.decodeImage(
    File('assets/illustrations/panda_notification_source.png').readAsBytesSync(),
  )!;
  final gray = img.grayscale(source);
  final alpha = img.Image(width: source.width, height: source.height, numChannels: 4);
  for (final p in gray) {
    final darkness = 255 - p.r;
    final a = darkness < 24 ? 0 : darkness > 220 ? 255 : darkness;
    alpha.setPixelRgba(p.x, p.y, 255, 255, 255, a);
  }
  final bbox = alpha.getBoundingBox();
  final master = img.copyCrop(alpha, x: bbox.left, y: bbox.top, width: bbox.width, height: bbox.height);
  const sizes = {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96};
  for (final entry in sizes.entries) {
    final canvas = _center(master, entry.value);
    final dir = Directory('android/app/src/main/res/drawable-${entry.key}');
    dir.createSync(recursive: true);
    File('${dir.path}/ic_notification.png').writeAsBytesSync(img.encodePng(canvas));
  }
}

img.Image _center(img.Image master, int size) {
  final side = (size * .80).round();
  final scaled = img.copyResize(master, width: side, height: (side * master.height / master.width).round(), interpolation: img.Interpolation.cubic);
  final canvas = img.Image(width: size, height: size, numChannels: 4);
  img.compositeImage(canvas, scaled, dstX: (size - scaled.width) ~/ 2, dstY: (size - scaled.height) ~/ 2);
  return canvas;
}
