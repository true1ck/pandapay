import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';

/// Draws [data] as a QR code PNG: black modules on white with the standard
/// four-module quiet zone, large enough for another app's scanner to read.
///
/// Scan-to-pay shares this into the UPI app the user picked, so the UPI app
/// reads it like a QR saved in the gallery. Pure Dart, runs in a few
/// milliseconds for a UPI payload.
Uint8List renderUpiQrPng(String data, {int moduleSize = 10, int quietModules = 4}) {
  final code = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
  final qr = QrImage(code);
  final side = (qr.moduleCount + quietModules * 2) * moduleSize;
  final canvas = img.Image(width: side, height: side);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  final black = img.ColorRgb8(0, 0, 0);
  for (var row = 0; row < qr.moduleCount; row++) {
    for (var col = 0; col < qr.moduleCount; col++) {
      if (!qr.isDark(row, col)) continue;
      final x = (col + quietModules) * moduleSize;
      final y = (row + quietModules) * moduleSize;
      img.fillRect(
        canvas,
        x1: x,
        y1: y,
        x2: x + moduleSize - 1,
        y2: y + moduleSize - 1,
        color: black,
      );
    }
  }
  return Uint8List.fromList(img.encodePng(canvas));
}
