import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'csv_statement_parser.dart';
import 'pdf_statement_parser.dart';

/// Reads OOXML workbooks locally and shares column inference with CSV imports.
/// Legacy binary XLS files must be exported as XLSX or CSV first.
ParsedStatement parseSpreadsheetStatement(
  Uint8List bytes, {
  StatementTableOptions options = const StatementTableOptions(),
}) {
  final tables = readSpreadsheetTables(bytes);
  final transactions = <ParsedStatementLine>[];
  final warnings = <String>[];
  final rejected = <ImportRejectedRow>[];
  for (final table in tables.entries) {
    final parsed = parseStatementRows(
      table.value,
      options: options,
      sourceId: table.key,
    );
    transactions.addAll(parsed.transactions);
    warnings.addAll(parsed.warnings);
    rejected.addAll(parsed.rejectedRows);
  }
  return ParsedStatement(
    transactions: transactions,
    warnings: warnings,
    rejectedRows: rejected,
  );
}

Map<String, List<List<String>>> readSpreadsheetTables(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  if (archive.files.fold<int>(0, (sum, file) => sum + file.size) >
      80 * 1024 * 1024) {
    throw const StatementParseException(
      'The expanded workbook is too large. Export a smaller date range as CSV.',
    );
  }
  String? read(String name) {
    final file = archive.findFile(name);
    if (file == null) return null;
    if (file.size > 20 * 1024 * 1024) {
      throw const StatementParseException(
        'This worksheet is too large. Export a smaller date range.',
      );
    }
    return utf8.decode(file.content as List<int>);
  }

  final stringsXml = read('xl/sharedStrings.xml');
  final strings = stringsXml == null
      ? <String>[]
      : XmlDocument.parse(stringsXml)
            .findAllElements('si')
            .map((si) => si.findAllElements('t').map((t) => t.innerText).join())
            .toList();
  final stylesXml = read('xl/styles.xml');
  final dateStyles = <int>{};
  if (stylesXml != null) {
    final styles = XmlDocument.parse(stylesXml);
    final custom = <int, String>{
      for (final format in styles.findAllElements('numFmt'))
        int.parse(format.getAttribute('numFmtId')!):
            format.getAttribute('formatCode') ?? '',
    };
    final formats =
        styles
            .findAllElements('cellXfs')
            .firstOrNull
            ?.findElements('xf')
            .toList() ??
        [];
    for (var i = 0; i < formats.length; i++) {
      final id = int.tryParse(formats[i].getAttribute('numFmtId') ?? '') ?? 0;
      final code = (custom[id] ?? '').replaceAll(
        RegExp(r'"[^"]*"|\[[^\]]*\]'),
        '',
      );
      if ((id >= 14 && id <= 22) ||
          RegExp(r'[yd]', caseSensitive: false).hasMatch(code)) {
        dateStyles.add(i);
      }
    }
  }
  final workbook = read('xl/workbook.xml');
  final date1904 =
      workbook != null &&
      XmlDocument.parse(workbook)
          .findAllElements('workbookPr')
          .any((e) => ['1', 'true'].contains(e.getAttribute('date1904')));
  final tables = <String, List<List<String>>>{};
  for (final file in archive.files.where(
    (f) => RegExp(r'^xl/worksheets/[^/]+\.xml$').hasMatch(f.name),
  )) {
    final sheet = XmlDocument.parse(read(file.name)!);
    final rows = <List<String>>[];
    for (final row in sheet.findAllElements('row')) {
      final cells = <String>[];
      for (final cell in row.findElements('c')) {
        final reference = cell.getAttribute('r') ?? '';
        var column = 0;
        for (final letter
            in RegExp(r'^[A-Z]+').stringMatch(reference)?.codeUnits ??
                <int>[]) {
          column = column * 26 + letter - 64;
        }
        if (column < 1 || column > 16384) continue;
        while (cells.length < column) {
          cells.add('');
        }
        var value = cell.getElement('v')?.innerText ?? '';
        final type = cell.getAttribute('t');
        if (type == 's') {
          final index = int.tryParse(value);
          value = index != null && index >= 0 && index < strings.length
              ? strings[index]
              : '';
        } else if (type == 'inlineStr') {
          value = cell.findAllElements('t').map((t) => t.innerText).join();
        } else if (dateStyles.contains(
          int.tryParse(cell.getAttribute('s') ?? ''),
        )) {
          final serial = double.tryParse(value);
          if (serial != null &&
              serial.isFinite &&
              serial >= 0 &&
              serial < 1000000) {
            final date = (date1904 ? DateTime(1904) : DateTime(1899, 12, 30))
                .add(
                  Duration(
                    milliseconds: (serial * Duration.millisecondsPerDay)
                        .round(),
                  ),
                );
            value = date.toIso8601String();
          }
        }
        cells[column - 1] = value;
      }
      rows.add(cells);
    }
    tables[file.name] = rows;
  }
  return tables;
}
