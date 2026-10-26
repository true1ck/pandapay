import 'package:image/image.dart' as img;
import 'dart:io';

void main() {
  final app = 'C:/Users/sujay/CKProjects/PandaPay/app';
  final glyph = img.decodePng(
    File('$app/android/app/src/main/res/drawable-xxxhdpi/ic_notification.png')
        .readAsBytesSync())!;

  // Simulate how Android tint paints the small icon with the notification
  // accent color (#FFFFFF), keeping the alpha mask.
  final tinted = glyph.clone();
  for (final p in tinted) {
    if (p.a == 0) continue;
    p.setRgba(0xFF, 0xFF, 0xFF, p.a);
  }

  final big = img.copyResize(tinted, width: 96, height: 96);
  final panelSize = 320;
  final stripW = panelSize * 2;
  final strip = img.Image(
    width: stripW,
    height: panelSize,
    numChannels: 4,
  );
  // Left panel: dark notification shade. Right panel: light shade.
  for (final p in strip) {
    final darkSide = p.x < panelSize;
    if (darkSide) {
      p.setRgba(0x10, 0x15, 0x1B, 255);
    } else {
      p.setRgba(0xFF, 0xFF, 0xFF, 255);
    }
  }
  for (final panelX in [panelSize ~/ 2 - 48, panelSize ~/ 2 + 48]) {
    img.compositeImage(strip, big, dstX: panelX, dstY: (panelSize - 96) ~/ 2);
  }

  final out =
      File(r'C:\Users\sujay\AppData\Local\Temp\opencode\notification_sample.png');
  out.writeAsBytesSync(img.encodePng(strip));
  stderr.writeln(out.path);
}
