import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

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
    final text = _readingOrder(result);
    if (parseSpendingScreenshotText(text).transactions.isNotEmpty) return text;
    // Retry small, rotated or low-contrast photos without altering the source.
    final bytes = await compute(_prepareImage, await File(path).readAsBytes());
    if (bytes == null) return text;
    final directory = await Directory.systemTemp.createTemp(
      'pandapay-image-ocr-',
    );
    try {
      final file = File('${directory.path}/prepared.jpg');
      await file.writeAsBytes(bytes);
      final retry = _readingOrder(
        await _recognizer.processImage(InputImage.fromFilePath(file.path)),
      );
      return parseSpendingScreenshotText(retry).transactions.isNotEmpty
          ? retry
          : text;
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        /* Best-effort cleanup. */
      }
    }
  }

  Future<void> dispose() => _recognizer.close();
}

/// ML Kit groups columns into blocks. Rebuild visual rows so a total label
/// and its right-aligned value are read together rather than block by block.
String _readingOrder(RecognizedText text) {
  final lines = [
    for (final block in text.blocks) ...block.lines,
  ]..sort((a, b) => a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy));
  final rows = <List<TextLine>>[];
  for (final line in lines) {
    if (rows.isEmpty ||
        (line.boundingBox.center.dy - rows.last.first.boundingBox.center.dy)
                .abs() >
            math.min(
                  line.boundingBox.height,
                  rows.last.first.boundingBox.height,
                ) *
                .45) {
      rows.add([line]);
    } else {
      rows.last.add(line);
    }
  }
  return rows
      .map((row) {
        row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
        return row.map((line) => line.text).join(' ');
      })
      .join('\n');
}
