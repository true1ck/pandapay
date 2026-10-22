import 'package:image/image.dart' as img;
import 'dart:io';

// Generates white monochrome notification small-icons for a 24dp slot (see
// android/app/src/main/res/drawable-*/ic_notification.png). Android draws the
// status-bar icon from the drawable's alpha mask only, so the source art must
// survive as a single-color glyph.
//
// Source: assets/illustrations/panda_peek.png (transparent background, white
// face, black features). The panda reads through its negative-space features,
// so a flat recolor is not enough: we classify every dark component by its
// surroundings — components touching the outer background (ears, arms) become
// part of the filled silhouette, components fully enclosed by the face (eye
// patches, nose, smile) become transparent holes. Light islands fully enclosed
// by holes are folded into the holes.
void main() {
  final bytes = File('assets/illustrations/panda_peek.png').readAsBytesSync();
  final im = img.decodePng(bytes)!;

  final w = im.width;
  final h = im.height;
  final n = w * h;

  final opaque = List<bool>.filled(n, false);
  final dark = List<bool>.filled(n, false);
  for (final p in im) {
    final i = p.y * w + p.x;
    if (p.a >= 128) {
      opaque[i] = true;
      final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      if (lum < 128) dark[i] = true;
    }
  }

  // Outer background flood fill from all four corners over non-opaque pixels.
  final outerBg = List<bool>.filled(n, false);
  final floodQueue = <int>[];
  void pushBg(int x, int y) {
    final i = y * w + x;
    if (x < 0 || x >= w || y < 0 || y >= h) return;
    if (opaque[i] || outerBg[i]) return;
    outerBg[i] = true;
    floodQueue.add(i);
  }

  for (final x in [0, w - 1]) {
    for (final y in [0, h - 1]) {
      pushBg(x, y);
    }
  }
  while (floodQueue.isNotEmpty) {
    final i = floodQueue.removeLast();
    final x = i % w;
    final y = i ~/ w;
    if (x > 0) pushBg(x - 1, y);
    if (x < w - 1) pushBg(x + 1, y);
    if (y > 0) pushBg(x, y - 1);
    if (y < h - 1) pushBg(x, y + 1);
  }

  // Component labeling: 0 silhouette, 1 hole, 2 face, -2 flood-in-progress.
  final label = List<int>.filled(n, -1);
  final compQueue = <int>[];

  final silDark = List<bool>.filled(n, false);
  final holeDark = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    if (!dark[i] || label[i] != -1) continue;
    final seen = <int>[];
    var touchesBg = false;
    compQueue.add(i);
    label[i] = -2;
    while (compQueue.isNotEmpty) {
      final c = compQueue.removeLast();
      seen.add(c);
      final x = c % w;
      final y = c ~/ w;
      if (x > 0 && !opaque[c - 1]) touchesBg = true;
      if (x < w - 1 && !opaque[c + 1]) touchesBg = true;
      if (y > 0 && !opaque[c - w]) touchesBg = true;
      if (y < h - 1 && !opaque[c + w]) touchesBg = true;
      for (final next in [
        if (x > 0) c - 1,
        if (x < w - 1) c + 1,
        if (y > 0) c - w,
        if (y < h - 1) c + w,
      ]) {
        if (dark[next] && label[next] == -1) {
          label[next] = -2;
          compQueue.add(next);
        }
      }
    }
    if (touchesBg) {
      for (final c in seen) {
        silDark[c] = true;
      }
    } else {
      for (final c in seen) {
        holeDark[c] = true;
      }
    }
  }

  // Light regions: anything already proven part of the silhouette or touching
  // the outer background is face; islands fully enclosed by holes fold into
  // the holes.
  final holeLight = List<bool>.filled(n, false);
  final faceLight = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    if (!opaque[i] || dark[i] || label[i] != -1) continue;
    // Flood the light component; classify from what it borders.
    final seen = <int>[];
    var bordersSil = false;
    var bordersOuter = false;

    compQueue.add(i);
    label[i] = -2;
    while (compQueue.isNotEmpty) {
      final c = compQueue.removeLast();
      seen.add(c);
      final x = c % w;
      final y = c ~/ w;
      for (final next in [
        if (x > 0) c - 1,
        if (x < w - 1) c + 1,
        if (y > 0) c - w,
        if (y < h - 1) c + w,
      ]) {
        if (outerBg[next]) bordersOuter = true;
        if (silDark[next]) bordersSil = true;

        if (opaque[next] && !dark[next] && label[next] == -1) {
          label[next] = -2;
          compQueue.add(next);
        }
      }
    }
    final isFace = bordersOuter || bordersSil;
    for (final c in seen) {
      if (isFace) {
        faceLight[c] = true;
        label[c] = 2;
      } else {
        holeLight[c] = true;
        label[c] = 1;
      }
    }
  }

  // Glyph = filled silhouette (ears/arms) + face; enclosed dark features and
  // their enclosed light islands stay transparent.
  var minX = -1;
  var minY = -1;
  var maxX = -1;
  var maxY = -1;
  for (var i = 0; i < n; i++) {
    if (!(silDark[i] || faceLight[i])) continue;
    final x = i % w;
    final y = i ~/ w;
    if (minX < 0 || x < minX) minX = x;
    if (maxX < x) maxX = x;
    if (minY < 0 || y < minY) minY = y;
    if (maxY < y) maxY = y;
  }
  final gw = maxX - minX + 1;
  final gh = maxY - minY + 1;
  final master = img.Image(width: gw, height: gh, numChannels: 4);
  for (final p in im) {
    final x = p.x;
    final y = p.y;
    if (x < minX || x > maxX || y < minY || y > maxY) continue;
    if (p.a < 128) continue;
    final i = y * w + x;
    if (silDark[i] || faceLight[i]) {
      master.setPixelRgba(x - minX, y - minY, 255, 255, 255, p.a);
    }
  }

  // Density buckets for a 24dp notification icon; glyph fills 80% of the
  // square canvas, centered, for a little breathing room.
  const root = 'android/app/src/main/res';
  final canvasSizes = {
    'mdpi': 24,
    'hdpi': 36,
    'xhdpi': 48,
    'xxhdpi': 72,
    'xxxhdpi': 96,
  };
  for (final entry in canvasSizes.entries) {
    final dir = Directory('$root/drawable-${entry.key}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final png = _renderCentered(master, entry.value);
    File(
      '${dir.path}/ic_notification.png',
    ).writeAsBytesSync(img.encodePng(png));
    stderr.writeln('${dir.path}/ic_notification.png');
  }

  final preview = _renderCentered(master, 192);
  final bg = img.Image(width: 192, height: 192, numChannels: 4);
  img.fillRect(
    bg,
    x1: 0,
    y1: 0,
    x2: 191,
    y2: 191,
    color: img.ColorRgba8(0x2B, 0x31, 0x3A, 255),
  );
  img.compositeImage(bg, preview, blend: img.BlendMode.alpha);
  final out = File(
    r'C:\Users\sujay\AppData\Local\Temp\opencode\icn_preview.png',
  );
  out.writeAsBytesSync(img.encodePng(bg));
  stderr.writeln(out.path);
}

img.Image _renderCentered(img.Image master, int size) {
  const fill = 0.80;
  final scaledW = (size * fill).toInt();
  final scaledH = ((size * fill) * master.height / master.width).toInt();
  final scaled = img.copyResize(
    master,
    width: scaledW,
    height: scaledH,
    interpolation: img.Interpolation.cubic,
  );
  final canvas = img.Image(width: size, height: size, numChannels: 4);
  img.compositeImage(
    canvas,
    scaled,
    dstX: (size - scaledW) ~/ 2,
    dstY: (size - scaledH) ~/ 2,
  );
  return canvas;
}
