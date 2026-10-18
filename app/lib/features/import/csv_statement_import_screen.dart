import 'package:flutter/material.dart';
import 'document_import_screen.dart';

/// Compatibility entry point; every financial document uses the shared pipeline.
class CsvStatementImportScreen extends StatelessWidget {
  const CsvStatementImportScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const DocumentImportScreen(pdfEntry: false);
}
