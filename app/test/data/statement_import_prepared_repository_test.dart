import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/import_repository.dart';

const _key = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

String _response({int? receiptVersion}) => jsonEncode({
  'receiptVersion': ?receiptVersion,
  'statementImport': {
    'id': 'server-id',
    'user_card_id': null,
    'statement_from': '2026-10-01',
    'statement_to': '2026-10-02',
    'txn_count': 1,
    'reconciled_count': 0,
    'imported_at': '2026-10-02T00:00:00.000Z',
  },
  'summary': {'imported': 1, 'pendingDuplicates': 0, 'exactRetries': 0},
  'duplicate': false,
});

void main() {
  test(
    'receipt handshake with missing or inconsistent counters cannot erase a saved batch',
    () async {
      for (final summary in [
        null,
        {'imported': 0},
        {'imported': 1, 'pendingDuplicates': 0, 'exactRetries': -1},
        {'imported': 0, 'pendingDuplicates': 0, 'exactRetries': 0},
      ]) {
        final response =
            jsonDecode(_response(receiptVersion: 1)) as Map<String, dynamic>;
        response['summary'] = summary;
        final repository = ImportRepository(
          apiBaseUrl: 'https://api.invalid',
          accessToken: 'synthetic',
          client: MockClient(
            (_) async => http.Response(jsonEncode(response), 200),
          ),
        );
        await expectLater(
          repository.confirmPreparedStatementImport({
            'importKey': _key,
            'transactions': [{}],
          }),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );
  test(
    'prepared POST preserves the exact canonical body and receipt totals',
    () async {
      final expected = <String, dynamic>{
        'userCardId': null,
        'instrument': 'other',
        'statementFrom': '2026-10-01',
        'statementTo': '2026-10-02',
        'txnCount': 1,
        'reconciledCount': 0,
        'importSource': 'statement',
        'importKey': _key,
        'transactions': [
          {
            'occurredAt': '2026-10-01T00:00:00.000Z',
            'amountInr': 10,
            'merchantName': 'Market',
            'entryKind': 'spend',
          },
        ],
      };
      Map<String, dynamic>? received;
      final repository = ImportRepository(
        apiBaseUrl: 'https://api.invalid',
        accessToken: 'test-only',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          received = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(_response(receiptVersion: 1), 201);
        }),
      );

      final result = await repository.confirmPreparedStatementImport(expected);
      expect(received, equals(expected));
      expect(result.addedCount, 1);
      expect(result.exactRetryCount, 0);
    },
  );

  test(
    'prepared POST does not accept a legacy response without a receipt',
    () async {
      final repository = ImportRepository(
        apiBaseUrl: 'https://api.invalid',
        accessToken: 'test-only',
        client: MockClient((_) async => http.Response(_response(), 200)),
      );

      await expectLater(
        repository.confirmPreparedStatementImport({
          'importKey': _key,
          'transactions': const [],
        }),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
