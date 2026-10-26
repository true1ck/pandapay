import 'dart:io';

import 'package:image/image.dart' as img;

/// Previews the generated notification branding on dark and light surfaces.
/// Run after gen_notification_icon.dart; optionally pass an output PNG path.
void main(List<String> args) {
  final res = Platform.script.resolve('../android/app/src/main/res/');
  img.Image read(String path) =>
      img.decodePng(File.fromUri(res.resolve(path)).readAsBytesSync())!;
  final logo = read('drawable-nodpi/ic_notification_logo.png');
  final strip = img.Image(width: 640, height: 320, numChannels: 4);
  for (final p in strip) {
    if (p.x < 320) {
      p.setRgba(0x10, 0x15, 0x1B, 255);
    } else {
      p.setRgba(0xFF, 0xFF, 0xFF, 255);
    }
  }
  for (final panelX in [0, 320]) {
    img.compositeImage(strip, logo, dstX: panelX + 64, dstY: 12);
    for (final (density, size, x) in [
      ('mdpi', 24, 36),
      ('xhdpi', 48, 104),
      ('xxxhdpi', 96, 188),
    ]) {
      final tinted = read('drawable-$density/ic_notification.png');
      for (final p in tinted) {
        p.setRgba(0xFF, 0xFF, 0xFF, p.a);
      }
      img.compositeImage(
        strip,
        tinted,
        dstX: panelX + x,
        dstY: 248 - size ~/ 2,
      );
    }
  }
  final out = File(
    args.isNotEmpty
        ? args.single
        : '${Directory.systemTemp.path}/pandapay-notification-sample.png',
  );
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(img.encodePng(strip));
  stdout.writeln(out.path);
}
