import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

import 'receipt_parser.dart';

Uint8List? _prepareReceiptImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  var image = img.bakeOrientation(decoded);
  final longest = math.max(image.width, image.height);
  final target = longest < 1800 ? 1800 : math.min(longest, 3200);
  image = img.copyResize(
    image,
    width: (image.width * target / longest).round(),
  );
  // Receipt paper is usually monochrome. Grayscale removes the camera's
  // colour cast and makes faint thermal text easier for ML Kit to segment.
  return img.encodeJpg(img.grayscale(image), quality: 96);
}

/// A single, shared OCR pipeline for receipt photos.
///
/// ML Kit's blocks are not guaranteed to be in visual order. A receipt's
/// labels and right-aligned values can therefore arrive in separate blocks,
/// which is exactly how an item amount such as 60.00 can be paired with a
/// `Grand Total` label. This class rebuilds rows before parsing and retries a
/// normalized image when the camera image is hard to read.
class ReceiptOcr {
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  Future<List<String>> _recognizeLines(String path) async {
    final result = await _recognizer.processImage(
      InputImage.fromFilePath(path),
    );
    return readingOrderLines(result);
  }

  Future<List<String>> recognizeLines(String path) async {
    final original = await _recognizeLines(path);
    final originalScan = parseReceiptFields(original);
    if (originalScan.parsedLine != null && originalScan.reviewReasons.isEmpty) {
      return original;
    }

    final bytes = await compute(
      _prepareReceiptImage,
      await File(path).readAsBytes(),
    );
    if (bytes == null) return original;

    final directory = await Directory.systemTemp.createTemp(
      'pandapay-receipt-ocr-',
    );
    try {
      final prepared = File(
        '${directory.path}${Platform.pathSeparator}receipt.jpg',
      );
      await prepared.writeAsBytes(bytes);
      final retry = await _recognizeLines(prepared.path);
      // Keep the better result. A failed retry must never erase a useful
      // original read, and a successful retry is preferred because it has
      // passed the same receipt parser after normalization.
      final retryScan = parseReceiptFields(retry);
      return retryScan.parsedLine != null ? retry : original;
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup only; OCR has already completed.
      }
    }
  }

  Future<List<String>> recognize(String path) => recognizeLines(path);

  Future<void> dispose() => _recognizer.close();
}

/// Reconstructs visual rows from ML Kit's block/line output.
///
/// This is intentionally public so the screenshot and receipt paths can use
/// the same ordering rule and cannot regress independently.
List<String> readingOrderLines(RecognizedText text) {
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

  return rows.map((row) {
    row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
    return row.map((line) => line.text).join(' ');
  }).toList();
}
