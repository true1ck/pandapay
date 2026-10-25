import 'portable_backup/app_private_temporary_storage.dart';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart';

/// Local OCR fallback for image-only/scanned statements. No PDF page image or
/// OCR text leaves the device; the caller sends only reviewed structured rows.
class PdfStatementOcr {
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  Future<String> extractText(
    Uint8List bytes, {
    int maxPages = 50,
    String? password,
    List<int>? pageNumbers,
  }) async {
    final workspace = await AppPrivateTemporaryStorage.create();
    PdfDocument? document;
    try {
      document = await PdfDocument.openData(bytes, password: password);
      final numbers =
          pageNumbers ?? List.generate(document.pagesCount, (i) => i + 1);
      if (numbers.length > maxPages) {
        throw StateError(
          'This scanned PDF exceeds $maxPages pages. Export a smaller date range to avoid missing transactions.',
        );
      }
      final pages = <String>[];
      for (final pageNumber in numbers) {
        if (pageNumber < 1 || pageNumber > document.pagesCount) {
          throw StateError('Invalid PDF page. Export the file again.');
        }
        final page = await document.getPage(pageNumber);
        try {
          final image = await page.render(
            width: page.width * 2,
            height: page.height * 2,
            format: PdfPageImageFormat.jpeg,
            backgroundColor: '#FFFFFF',
          );
          if (image == null) continue;
          final file = workspace.file('page-$pageNumber.jpg');
          await file.writeAsBytes(image.bytes, flush: true);
          final result = await _recognizer.processImage(
            InputImage.fromFilePath(file.path),
          );
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
      try {
        await document?.close();
      } finally {
        await workspace.cleanup();
      }
    }
  }

  Future<void> dispose() => _recognizer.close();
}
