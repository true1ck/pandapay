import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pandapay/data/upi_qr_image.dart';

void main() {
  const payload = 'upi://pay?pa=paytmqr60fkly@ptys&pn=Paytm&am=180.00&cu=INR';

  test('draws a square black-on-white PNG with a quiet zone', () {
    final png = renderUpiQrPng(payload);
    final image = img.decodePng(png)!;

    expect(image.width, image.height);
    // 10px modules: a whole number of modules, quiet zone included.
    expect(image.width % 10, 0);
    // The four-module quiet zone is white on every corner.
    for (final (x, y) in [
      (0, 0),
      (image.width - 1, 0),
      (0, image.height - 1),
      (image.width - 1, image.height - 1),
    ]) {
      final p = image.getPixel(x, y);
      expect([p.r, p.g, p.b], [255, 255, 255]);
    }
    // The first finder pattern's corner module (just inside the quiet zone) is black.
    final dark = image.getPixel(41, 41);
    expect([dark.r, dark.g, dark.b], [0, 0, 0]);
  });

  test('a longer payload makes a bigger code', () {
    final small = img.decodePng(renderUpiQrPng('upi://pay?pa=a@b'))!;
    final big = img.decodePng(renderUpiQrPng('$payload&tn=${'x' * 200}'))!;
    expect(big.width, greaterThan(small.width));
  });
}
