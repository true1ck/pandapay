import 'portable_backup/app_private_temporary_storage.dart';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

import 'receipt_ocr.dart' show readingOrderLines;
import 'spending_screenshot_parser.dart';

Uint8List? _prepareImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  final longest = math.max(image.width, image.height);
  final target = longest < 1800 ? 1800 : math.min(longest, 3200);
  image = img.copyResize(
    image,
    width: (image.width * target / longest).round(),
  );
  return img.encodeJpg(img.grayscale(image), quality: 95);
}

/// Reads selected spending screenshots locally using the same on-device ML
/// Kit engine already used by the card scanner.
class SpendingScreenshotOcr {
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  Future<String> recognize(String path) async {
    final result = await _recognizer.processImage(
      InputImage.fromFilePath(path),
    );
    final text = readingOrderLines(result).join('\n');
    if (parseSpendingScreenshotText(text).transactions.isNotEmpty) return text;
    // Retry small, rotated or low-contrast photos without altering the source.
    final bytes = await compute(_prepareImage, await File(path).readAsBytes());
    if (bytes == null) return text;
    final workspace = await AppPrivateTemporaryStorage.create();
    try {
      final file = workspace.file('prepared.jpg');
      await file.writeAsBytes(bytes);
      final retry = readingOrderLines(
        await _recognizer.processImage(InputImage.fromFilePath(file.path)),
      ).join('\n');
      return parseSpendingScreenshotText(retry).transactions.isNotEmpty
          ? retry
          : text;
    } finally {
      try {
        await workspace.cleanup();
      } catch (_) {
        /* Best-effort cleanup. */
      }
    }
  }

  Future<void> dispose() => _recognizer.close();
}
