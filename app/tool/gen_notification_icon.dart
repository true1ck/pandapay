import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Generates both notification icons from the same mark used by the app.
/// Run from app/ with `dart run tool/gen_notification_icon.dart`.
///
/// Android tints the small icon using only its alpha channel. Preserve the
/// logo's dark panda features, cards, and wallet outline as a white mask; its
/// light areas become negative space. The large icon keeps the original art
/// and colors. Do not substitute one of the onboarding panda illustrations.
void main() {
  final source = img.decodePng(
    File.fromUri(
      Platform.script.resolve('../assets/logo/pandapay_mark.png'),
    ).readAsBytesSync(),
  )!;
  final mask = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 4,
  );
  for (final p in source) {
    final luminance = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    // A short transition preserves anti-aliasing around the original artwork
    // without turning the light wallet fill into a solid, unreadable block.
    final coverage = ((155 - luminance) / 20).clamp(0.0, 1.0);
    mask.setPixelRgba(p.x, p.y, 255, 255, 255, (p.a * coverage).round());
  }

  final glyph = _cropVisible(mask);
  final res = Directory.fromUri(
    Platform.script.resolve('../android/app/src/main/res/'),
  );
  const canvasSizes = {
    'mdpi': 24,
    'hdpi': 36,
    'xhdpi': 48,
    'xxhdpi': 72,
    'xxxhdpi': 96,
  };
  for (final entry in canvasSizes.entries) {
    // A 22dp mark centered inside Android's 24dp notification icon slot.
    final icon = _renderCentered(glyph, entry.value, fill: 22 / 24);
    for (final p in icon) {
      p.setRgba(255, 255, 255, p.a);
    }
    _writePng('${res.path}/drawable-${entry.key}/ic_notification.png', icon);
  }

  // A local drawable works offline and avoids per-notification image fetching.
  _writePng(
    '${res.path}/drawable-nodpi/ic_notification_logo.png',
    _renderCentered(_cropVisible(source), 192, fill: 0.96),
  );
}

img.Image _cropVisible(img.Image image) {
  var minX = image.width;
  var minY = image.height;
  var maxX = -1;
  var maxY = -1;
  for (final p in image) {
    if (p.a == 0) continue;
    minX = math.min(minX, p.x);
    minY = math.min(minY, p.y);
    maxX = math.max(maxX, p.x);
    maxY = math.max(maxY, p.y);
  }
  if (maxX < 0) throw StateError('The app logo has no visible pixels.');
  return img.copyCrop(
    image,
    x: minX,
    y: minY,
    width: maxX - minX + 1,
    height: maxY - minY + 1,
  );
}

img.Image _renderCentered(img.Image image, int size, {required double fill}) {
  final scale = size * fill / math.max(image.width, image.height);
  final scaled = img.copyResize(
    image,
    width: (image.width * scale).round(),
    height: (image.height * scale).round(),
    interpolation: img.Interpolation.average,
  );
  final canvas = img.Image(width: size, height: size, numChannels: 4);
  img.compositeImage(
    canvas,
    scaled,
    dstX: (size - scaled.width) ~/ 2,
    dstY: (size - scaled.height) ~/ 2,
  );
  return canvas;
}

void _writePng(String path, img.Image image) {
  final out = File(path);
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(img.encodePng(image));
  stdout.writeln(out.path);
}
