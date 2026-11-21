// A developer tool, not a test: reads one real statement through the app's own
// import path and prints what the phone would see, so a bank's file can be
// checked without importing it.
//
//   STMT_FILE=/path/statement.pdf STMT_OUT=/some/private/folder \
//     [STMT_PASSWORD=...] flutter test test/tool/statement_probe_test.dart
//
// The console shows only counts, totals and the balance-proof result: no
// narration, no names. The rows themselves go to STMT_OUT/<name>.rows.csv, which
// is personal data: keep that folder outside the repository. Without STMT_FILE
// the test does nothing.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/pdf_statement_parser.dart';
import 'package:pandapay/data/transaction_import_pipeline.dart';
import 'package:pandapay_domain/statement_layouts.dart' as layouts;

String _csv(String v) => '"${v.replaceAll('"', '""')}"';
String _day(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _rupees(int paise) =>
    '${paise ~/ 100}.${(paise % 100).toString().padLeft(2, '0')}';

void main() {
  test('read one statement', () {
    final path = Platform.environment['STMT_FILE'];
    final out = Platform.environment['STMT_OUT'];
    if (path == null || out == null) {
      markTestSkipped('STMT_FILE and STMT_OUT not set');
      return;
    }
    final password = Platform.environment['STMT_PASSWORD'];
    final name = path.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    Directory(out).createSync(recursive: true);
    final bytes = Uint8List.fromList(File(path).readAsBytesSync());

    final document = ImportDocument.open(bytes, path.split('/').last);
    var reader = document.kind.name;
    if (document.kind == ImportDocumentKind.pdf) {
      final x = PdfStatementReader().extract(
        bytes,
        password: password == null || password.isEmpty ? null : password,
      );
      document.pdfText = x.pages.join('\n');
      document.pdfWords = x.words;
      final table = layouts.readStatementTable(x.words);
      reader = table == null ? 'pdf text reader (no provable table)' : 'pdf table reader';
      // ignore: avoid_print
      print('PROBE pages=${x.pages.length} words=${x.words.length}');
      if (table != null) {
        final check = table.check;
        // ignore: avoid_print
        print(
          'PROBE proof: rows=${table.rows.length} chainBreaks=${check.chainBreaks.length} '
          'directionUnknown=${check.directionUnknown.length} skipped=${table.skipped.length} '
          'unreadPages=${table.unreadPages} reversed=${check.reversed} '
          'verified=${check.verifiedSomething} problems=${check.problems}',
        );
      }
    }
    final parsed = document.parse();
    final rows = parsed.transactions;
    final debit = rows.where((r) => !r.isCredit).toList();
    final credit = rows.where((r) => r.isCredit).toList();
    int sum(Iterable r) => r.fold(0, (a, e) => a + (e.amount.paise as int));
    // ignore: avoid_print
    print('PROBE reader=$reader');
    // ignore: avoid_print
    print(
      'PROBE rows=${rows.length} debit=${debit.length} (${_rupees(sum(debit))}) '
      'credit=${credit.length} (${_rupees(sum(credit))}) '
      'transfers=${rows.where((r) => r.isTransfer).length} '
      'first=${rows.isEmpty ? '-' : _day(rows.map((r) => r.date).reduce((a, b) => a.isBefore(b) ? a : b))} '
      'last=${rows.isEmpty ? '-' : _day(rows.map((r) => r.date).reduce((a, b) => a.isAfter(b) ? a : b))}',
    );
    // ignore: avoid_print
    print('PROBE account=${rows.map((r) => r.sourceAccount).toSet().toList()}');
    // ignore: avoid_print
    print(
      'PROBE flaggedRows=${rows.where((r) => r.reviewReasons.isNotEmpty).length} '
      'rejectedRows=${parsed.rejectedRows.length} warnings=${parsed.warnings}',
    );
    final reasons = <String, int>{};
    for (final r in rows) {
      for (final why in r.reviewReasons) {
        reasons[why] = (reasons[why] ?? 0) + 1;
      }
    }
    // ignore: avoid_print
    print('PROBE reviewReasons=$reasons');

    File('$out/$name.rows.csv').writeAsStringSync(
      [
        'date,amount,direction,description,reasons',
        for (final r in rows)
          [
            _day(r.date),
            _rupees(r.amount.paise),
            r.isCredit ? 'credit' : 'debit',
            _csv(r.description),
            _csv(r.reviewReasons.join(' | ')),
          ].join(','),
      ].join('\n'),
    );
    File('$out/$name.rejected.txt').writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert([
        for (final r in parsed.rejectedRows) {'row': r.sourceRowId, 'cells': r.cells},
      ]),
    );
  });
}
