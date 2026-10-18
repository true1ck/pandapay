import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/csv_statement_parser.dart';
import 'package:pandapay/data/import_models.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/transaction_import_pipeline.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

ParsedStatementLine line(
  int i, {
  String? account,
  String? source,
  int amount = 100,
}) => ParsedStatementLine(
  date: DateTime(2026, 10, 2, 12, i % 60, i ~/ 60),
  description: 'Shop $i',
  amount: Money.fromRupees(amount),
  sourceAccount: account,
  sourceRowId: source ?? 'table:row:${i + 2}',
);

void main() {
  test(
    'long Unicode descriptions are batched below the API byte limit',
    () async {
      var requests = 0;
      final repository = ImportRepository(
        apiBaseUrl: 'https://example.test',
        accessToken: 'token',
        client: MockClient((request) async {
          requests++;
          expect(request.bodyBytes.length, lessThan(100 * 1024));
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          final count = (payload['transactions'] as List).length;
          return http.Response(
            jsonEncode({
              'statementImport': {
                'id': '$requests',
                'user_card_id': null,
                'statement_from': payload['statementFrom'],
                'statement_to': payload['statementTo'],
                'imported_at': '2026-10-18T00:00:00Z',
              },
              'summary': {
                'imported': count,
                'pendingDuplicates': 0,
                'exactRetries': 0,
              },
            }),
            201,
          );
        }),
      );
      final rows = List.generate(
        250,
        (i) => ParsedStatementLine(
          date: DateTime(2026, 10, 2, 12, i % 60, i ~/ 60),
          description: '${List.filled(490, '漢').join()}$i',
          amount: Money.fromRupees(100),
          sourceRowId: 'row:$i',
        ),
      );
      final session = TransactionImportSession(
        fileDigest: 'file',
        importSource: 'csv',
        statement: ParsedStatement(transactions: rows),
      );
      session.destinations[TransactionImportSession.unknownAccount] = '';
      final result = await session.submit(repository);
      expect(requests, greaterThan(1));
      expect(result.added, 250);
    },
  );
  test(
    'credit-card identifiers and balances are never used as amount columns',
    () {
      final result = parseFlexibleCsvStatement(
        'Date,Description,Credit Card,Amount,Balance\n2026-10-02,Coffee,1234,100,5000',
      );
      expect(result.transactions.single.amount.rupees, 100);
      expect(result.transactions.single.isCredit, isFalse);
    },
  );

  test('localized dates, times, named months and grouping are validated', () {
    final result = parseFlexibleCsvStatement(
      'Date;Description;Amount\n14/10/2026 08:32 PM;Coffee;100\nOct 15 2026;Fuel;200\n20260230;Bad date;300\n2026-10-16;Bad grouping;1,2,3',
    );
    expect(result.transactions, hasLength(2));
    expect(result.transactions.first.date, DateTime(2026, 10, 14, 20, 32));
    expect(result.transactions.last.date, DateTime(2026, 10, 15));
    expect(result.rejectedRows, hasLength(2));
  });

  test('possible credits without a direction are held for explicit review', () {
    final row = ParsedStatementLine(
      date: DateTime(2026, 10, 2),
      description: 'Salary',
      amount: Money.fromRupees(100),
    );
    final session = TransactionImportSession(
      fileDigest: 'file',
      importSource: 'csv',
      statement: ParsedStatement(transactions: [row]),
    );
    expect(session.selected, isEmpty);
    expect(session.rows.single.reviewReasons, isNotEmpty);
  });
  test(
    'sniffs content, not extensions, and rejects legacy/empty/mismatched files',
    () {
      expect(
        ImportDocument.open(
          Uint8List.fromList(
            utf8.encode('Date,Description,Amount\n2026-10-02,Coffee,100'),
          ),
          'export.bin',
        ).kind,
        ImportDocumentKind.delimited,
      );
      expect(
        () => ImportDocument.open(Uint8List(0), 'empty.csv'),
        throwsException,
      );
      expect(
        () => ImportDocument.open(
          Uint8List.fromList([0xd0, 0xcf, 0x11, 0xe0]),
          'legacy.xls',
        ),
        throwsException,
      );
      expect(
        () => ImportDocument.open(
          Uint8List.fromList(utf8.encode('not a PDF')),
          'fake.pdf',
        ),
        throwsException,
      );
    },
  );

  test('JSON transaction objects share CSV semantics and source locations', () {
    final document = ImportDocument.open(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'transactions': [
              {
                'date': '2026-10-02',
                'merchant': 'Coffee',
                'amount': 123.45,
                'account': 'Bank',
              },
            ],
          }),
        ),
      ),
      'export.json',
    );
    final parsed = document.parse();
    expect(document.kind, ImportDocumentKind.json);
    expect(parsed.transactions.single.description, 'Coffee');
    expect(parsed.transactions.single.sourceRowId, 'json:row:2');
  });

  test(
    'unknown columns can be mapped; ambiguous dates require explicit format',
    () {
      final rows = [
        ['When', 'Who', 'HowMuch'],
        ['03/04/2026', 'Coffee', '1.234,56'],
      ];
      final options = StatementTableOptions(
        headerRow: 0,
        columns: const {
          ImportColumn.date: 0,
          ImportColumn.description: 1,
          ImportColumn.amount: 2,
        },
        numberFormat: ImportNumberFormat.decimalComma,
      );
      final ambiguous = parseStatementRows(rows, options: options);
      expect(ambiguous.transactions.single.reviewReasons, isNotEmpty);
      final parsed = parseStatementRows(
        rows,
        options: const StatementTableOptions(
          headerRow: 0,
          dateOrder: ImportDateOrder.monthFirst,
          dateOrderConfirmed: true,
          columns: {
            ImportColumn.date: 0,
            ImportColumn.description: 1,
            ImportColumn.amount: 2,
          },
          numberFormat: ImportNumberFormat.decimalComma,
        ),
      );
      expect(parsed.transactions.single.date, DateTime(2026, 3, 4));
      expect(parsed.transactions.single.amount.rupees, 1234.56);
      expect(parsed.transactions.single.reviewReasons, isEmpty);
    },
  );

  test(
    'signed conventions, dedicated credit columns and suffixes keep direction',
    () {
      final negativeExpense = parseFlexibleCsvStatement(
        'Date,Description,Amount\n2026-10-02,Coffee,-100',
        options: const StatementTableOptions(negativeIsExpense: true),
      );
      expect(negativeExpense.transactions.single.isCredit, isFalse);
      final credit = parseFlexibleCsvStatement(
        'Date,Description,Amount,Debit,Credit\n2026-10-02,Refund,100,0,100',
      );
      expect(credit.transactions.single.isCredit, isTrue);
      final suffix = parseFlexibleCsvStatement(
        'Date,Description,Amount\n2026-10-02,Refund,100 CR',
      );
      expect(suffix.transactions.single.isCredit, isTrue);
      expect(
        parseFlexibleCsvStatement(
          'Date,Description,Debit,Credit\n2026-10-02,Ambiguous,100,50',
        ).rejectedRows,
        hasLength(1),
      );
    },
  );

  test('headerless data is not mistaken for a header by account words', () {
    final result = parseFlexibleCsvStatement(
      '2026-10-02,Coffee,100,Example credit\n2026-10-03,Fuel,200,Example credit',
    );
    expect(result.transactions, hasLength(2));
  });

  test('missing years need review; corrected rows keep stable identities', () {
    final ambiguous = parseFlexibleCsvStatement(
      'Date,Description,Amount\n14/10,Coffee,100',
    );
    expect(ambiguous.transactions.single.reviewReasons, isNotEmpty);
    final known = parseFlexibleCsvStatement(
      'Date,Description,Amount\n14/10,Coffee,100',
      options: const StatementTableOptions(year: 2024),
    );
    expect(known.transactions.single.date.year, 2024);
    expect(known.transactions.single.reviewReasons, isEmpty);
    final broken = parseFlexibleCsvStatement(
      'Date,Description,Amount\n2026-10-02,Coffee,broken\n2026-10-03,Fuel,200',
    );
    final session = TransactionImportSession(
      fileDigest: 'file',
      importSource: 'csv',
      statement: broken,
    );
    final original = session.rowKey(0);
    session.addCorrectedRow(broken.rejectedRows.single, line(5));
    expect(session.rowKey(0), original);
    expect(session.rows.last.sourceRowId, 'table:row:2');
    expect(
      () => session.addCorrectedRow(broken.rejectedRows.single, line(6)),
      throwsStateError,
    );
  });

  test(
    'repeated rows are retained but require review; distinct purchases survive',
    () {
      final first = line(1);
      final repeated = first.reviewed(sourceRowId: 'table:row:3');
      final session = TransactionImportSession(
        fileDigest: 'file',
        importSource: 'csv',
        statement: ParsedStatement(transactions: [first, repeated, line(2)]),
      );
      expect(session.rows, hasLength(3));
      expect(session.selected, [0, 2]);
      session.replaceRow(
        1,
        repeated,
      ); // Explicit review confirms a real second purchase.
      expect(session.selected, [0, 1, 2]);
    },
  );

  test(
    'multi-account review requires all selected accounts and never guesses a card',
    () {
      final session = TransactionImportSession(
        fileDigest: 'file',
        importSource: 'csv',
        statement: ParsedStatement(
          transactions: [
            line(1, account: 'Bank'),
            line(2, account: 'Card'),
          ],
        ),
      );
      expect(session.ready, isFalse);
      session.destinations['Bank'] = '';
      expect(session.ready, isFalse);
      session.destinations['Card'] = 'card';
      expect(session.ready, isTrue);
      expect(session.selectedPaise, 20000);
    },
  );

  test(
    'batches retry a timed-out submission with identical keys and correct summaries',
    () async {
      final bodies = <Map<String, dynamic>>[];
      var call = 0;
      final repository = ImportRepository(
        apiBaseUrl: 'https://example.test',
        accessToken: 'token',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(body);
          call++;
          if (call == 2)
            throw http.ClientException('connection lost after send');
          return http.Response(
            jsonEncode({
              'statementImport': {
                'id': '$call',
                'user_card_id': body['userCardId'],
                'statement_from': body['statementFrom'],
                'statement_to': body['statementTo'],
                'txn_count': body['txnCount'],
                'reconciled_count': body['txnCount'],
                'imported_at': '2026-10-18T00:00:00Z',
              },
              'summary': {
                'imported': call == 1 ? 249 : 1,
                'pendingDuplicates': call == 1 ? 1 : 0,
                'exactRetries': 0,
              },
            }),
            201,
          );
        }),
      );
      final session = TransactionImportSession(
        fileDigest: 'file',
        importSource: 'csv',
        statement: ParsedStatement(
          transactions: List.generate(
            251,
            (i) => line(i, account: 'Bank 1234567890'),
          ),
        ),
      );
      session.destinations['Bank 1234567890'] = '';
      await expectLater(
        session.submit(repository),
        throwsA(isA<http.ClientException>()),
      );
      expect(session.progress.completedBatches, 1);
      expect(session.progress.added, 249);
      expect(session.progress.duplicates, 1);
      expect(session.reviewLocked, isTrue);
      expect(() => session.replaceRow(0, line(0)), throwsStateError);
      final result = await session.submit(repository);
      expect(bodies, hasLength(3)); // Completed first batch was not re-sent.
      expect(bodies[1]['importKey'], bodies[2]['importKey']);
      expect(bodies[1]['transactions'], bodies[2]['transactions']);
      expect(bodies.first['userCardId'], isNull);
      expect(
        (bodies.first['transactions'] as List).first['sourceAccount'],
        'Bank ****7890',
      );
      expect(result.added, 250);
      expect(result.duplicates, 1);
      expect(result.completedBatches, 2);
    },
  );

  test(
    'screenshot row identities survive reordering or overlapping image selections',
    () {
      final row = line(1, source: 'image:hash:pdf:line:1');
      final first = TransactionImportSession(
        fileDigest: 'set-a',
        importSource: 'screenshot',
        statement: ParsedStatement(transactions: [row]),
      );
      final second = TransactionImportSession(
        fileDigest: 'set-b',
        importSource: 'screenshot',
        statement: ParsedStatement(transactions: [line(0), row]),
      );
      expect(first.rowKey(0), second.rowKey(1));
    },
  );
}
