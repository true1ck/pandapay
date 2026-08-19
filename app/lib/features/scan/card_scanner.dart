import 'dart:async';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
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
    : _recognizer = recognizer ?? TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<ExtractedCardText> recognizeText(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final result = await _recognizer.processImage(inputImage);
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
