import 'dart:async';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mobile_scanner/mobile_scanner.dart' as mobile_scanner;

import 'card_text_matcher.dart';

/// UA-4 (Chunk 30): the thin, deliberately-dumb boundary between camera
/// hardware/OCR plugins and the pure matching logic in `card_text_matcher.dart`.
/// Everything below this line touches a platform channel and could NOT be
/// exercised in this sandbox (no camera hardware, no simulator/device
/// attached) — it is structurally present, not verified. `CardTextMatcher`
/// (the pure logic) is unit-tested instead; this file exists so that logic
/// never has to know a camera plugin exists.
abstract class CardTextRecognizer {
  /// Runs on-device text recognition over a single captured camera frame
  /// (a file path, per `google_mlkit_text_recognition`'s `InputImage.fromFilePath`
  /// contract) and returns everything recognized, unfiltered.
  Future<ExtractedCardText> recognizeText(String imagePath);

  Future<void> dispose();
}

/// Real ML Kit-backed implementation. UNVERIFIED — no device/simulator with
/// a camera was available while building this; wiring follows the package's
/// documented API but has never actually run against a live frame here.
class MlKitCardTextRecognizer implements CardTextRecognizer {
  final TextRecognizer _recognizer;

  MlKitCardTextRecognizer() : _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<ExtractedCardText> recognizeText(String imagePath) async {
    final input = InputImage.fromFilePath(imagePath);
    final result = await _recognizer.processImage(input);
    return ExtractedCardText(result.text);
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
