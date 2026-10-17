import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart';

/// Local OCR fallback for image-only/scanned statements. No PDF page image or
/// OCR text leaves the device; the caller sends only reviewed structured rows.
class PdfStatementOcr {
  final TextRecognizer _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  Future<String> extractText(Uint8List bytes, {int maxPages = 50}) async {
    final tempDir = await Directory.systemTemp.createTemp('pandapay-pdf-ocr-');
    PdfDocument? document;
    try {
      document = await PdfDocument.openData(bytes);
      final pageCount = document.pagesCount < maxPages ? document.pagesCount : maxPages;
      final pages = <String>[];
      for (var pageNumber = 1; pageNumber <= pageCount; pageNumber++) {
        final page = await document.getPage(pageNumber);
        try {
          final image = await page.render(
            width: page.width * 2,
            height: page.height * 2,
            format: PdfPageImageFormat.jpeg,
            backgroundColor: '#FFFFFF',
          );
          if (image == null) continue;
          final file = File('${tempDir.path}/page-$pageNumber.jpg');
          await file.writeAsBytes(image.bytes, flush: true);
          final result = await _recognizer.processImage(InputImage.fromFilePath(file.path));
          if (result.text.trim().isNotEmpty) pages.add(result.text);
          try {
            await file.delete();
          } catch (_) {
            // Temporary OCR files are best-effort cleanup only.
          }
        } finally {
          await page.close();
        }
      }
      return pages.join('\n');
    } finally {
      await document?.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Temporary OCR directory is best-effort cleanup only.
      }
    }
  }

  Future<void> dispose() => _recognizer.close();
}
