import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Reads selected spending screenshots locally using the same on-device ML
/// Kit engine already used by the card scanner.
class SpendingScreenshotOcr {
  final TextRecognizer _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  Future<String> recognize(String path) async {
    final result = await _recognizer.processImage(InputImage.fromFilePath(path));
    return result.text;
  }

  Future<void> dispose() => _recognizer.close();
}
