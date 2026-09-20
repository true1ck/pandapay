import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_scanner/mobile_scanner.dart' as mobile_scanner;

import 'card_text_matcher.dart';

/// UA-4 (Chunk 30): the thin, deliberately-dumb boundary between camera
/// hardware/OCR plugins and the pure matching logic in `card_text_matcher.dart`.
/// `CardTextMatcher` (the pure logic) is unit-tested instead; this file
/// exists so that logic never has to know a camera plugin exists.
abstract class CardTextRecognizer {
  /// Runs on-device text recognition over a single captured camera frame
  /// (a file path, per `google_mlkit_text_recognition`'s `InputImage.fromFilePath`
  /// contract) and returns everything recognized, unfiltered.
  Future<ExtractedCardText> recognizeText(String imagePath);

  Future<void> dispose();
}

/// The real implementation, wired to `google_mlkit_text_recognition` — this
/// class was previously declared abstract with no concrete backing, despite
/// `ScanCardScreen`'s own doc-comment claiming the OCR path was "wired".
///
/// Deliberately dumb: it hands back every recognized text block joined into
/// one string, with no attempt to distinguish "this looks like an issuer
/// name" from "this looks like a PAN" from "this is decorative card art".
/// `card_text_matcher.dart`'s fuzzy matcher already does that filtering on
/// the pure-Dart side, and duplicating any of it here would just be a second
/// place for the two to disagree.
///
/// `TextRecognitionScript.latin` covers every issuer/network wordmark this
/// catalogue prints in — Devanagari card art exists but issuer names on
/// Indian cards are printed in Latin script regardless.
class MlKitCardTextRecognizer implements CardTextRecognizer {
  final TextRecognizer _recognizer;

  MlKitCardTextRecognizer({TextRecognizer? recognizer})
    : _recognizer =
          recognizer ?? TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<ExtractedCardText> recognizeText(String imagePath) async {
    final ocrPaths = await _prepareOcrVariants(imagePath);
    try {
      final texts = <String>[];
      for (final ocrPath in ocrPaths) {
        final inputImage = InputImage.fromFilePath(ocrPath);
        final result = await _recognizer.processImage(inputImage);
        if (result.text.trim().isNotEmpty) texts.add(result.text.trim());
      }
      return ExtractedCardText(texts.join('\n'));
    } finally {
      for (final ocrPath in ocrPaths.where((path) => path != imagePath)) {
        try {
          await File(ocrPath).delete();
        } catch (_) {
          // The OCR result is already available; a best-effort temp-file
          // cleanup must never turn a successful scan into an error.
        }
      }
    }
  }

  /// ML Kit can miss the small issuer/product wordmark on a low-resolution
  /// gallery image while confidently reading a large network/tier label such
  /// as "RuPay Platinum". Upscale genuinely small inputs and run overlapping
  /// horizontal crops so small top/bottom wordmarks get a larger OCR target.
  Future<List<String>> _prepareOcrVariants(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return [imagePath];

    const minimumLongEdge = 1400;
    final originalLongEdge = math.max(decoded.width, decoded.height);
    if (originalLongEdge >= minimumLongEdge) return [imagePath];

    // A tiny gallery image can contain the product wordmark only a few
    // pixels high. Cropping the two wordmark zones before upscaling gives
    // ML Kit more pixels per character than resizing the whole card. The
    // lower crop intentionally reaches the bottom edge; the previous
    // 20%-offset crop stopped at 80% and could discard HDFC/SBI marks.
    final variants = <img.Image>[decoded];
    void addCrop(double yFraction, double heightFraction) {
      final cropHeight = (decoded.height * heightFraction).round();
      final maxY = decoded.height - cropHeight;
      final y = (decoded.height * yFraction).round().clamp(0, maxY).toInt();
      if (cropHeight > 0 && cropHeight < decoded.height) {
        variants.add(
          img.copyCrop(
            decoded,
            x: 0,
            y: y,
            width: decoded.width,
            height: cropHeight,
          ),
        );
      }
    }

    addCrop(0.0, 0.45); // Tata/issuer marks at the top.
    addCrop(0.55, 0.45); // Bank/network marks at the bottom.
    addCrop(0.0, 0.72); // Preserve larger product text near the top.
    addCrop(0.28, 0.72); // Preserve larger product text near the bottom.

    final paths = <String>[];
    for (var i = 0; i < variants.length; i++) {
      final variant = variants[i];
      final longEdge = math.max(variant.width, variant.height);
      final scale = longEdge < minimumLongEdge
          ? minimumLongEdge / longEdge
          : 1.0;
      var prepared = scale == 1.0
          ? variant
          : img.copyResize(
              variant,
              width: (variant.width * scale).round(),
              height: (variant.height * scale).round(),
              interpolation: img.Interpolation.cubic,
            );
      if (i > 0) {
        // Light grayscale/contrast normalization helps white wordmarks on
        // saturated purple/blue card artwork without changing the original
        // full-card pass used for normal images.
        prepared = img.adjustColor(
          img.grayscale(prepared),
          contrast: 1.25,
          brightness: 1.05,
        );
      }
      if (i == 0 && scale == 1.0) {
        paths.add(imagePath);
        continue;
      }
      final tempPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'pandapay_ocr_${DateTime.now().microsecondsSinceEpoch}_$i.jpg';
      await File(tempPath).writeAsBytes(
        img.encodeJpg(prepared, quality: 95, chroma: img.JpegChroma.yuv444),
      );
      paths.add(tempPath);
    }
    return paths;
  }

  @override
  Future<void> dispose() => _recognizer.close();
}

/// Decodes a QR/barcode payload (e.g. printed on some card mailers or
/// statements) into the same `ExtractedCardText` shape the OCR path
/// produces, so both feed the same matcher. Scope note: this reads whatever
/// text payload is encoded in the code — it does not know the card mailer
/// QR format of any specific issuer, so the payload is treated as opaque
/// text and run through the same fuzzy matcher as OCR output, not parsed
/// as a structured record.
ExtractedCardText extractedTextFromBarcode(mobile_scanner.Barcode barcode) {
  return ExtractedCardText(barcode.rawValue ?? barcode.displayValue ?? '');
}
