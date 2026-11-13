import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

Map<String, dynamic> _row({Object? paymentMethod, Object? instrument}) => {
  'id': 'txn-1',
  'amount_inr': 125,
  'occurred_at': '2026-10-20T12:00:00Z',
  'source': 'manual',
  'status': 'active',
  'payment_method': ?paymentMethod,
  'instrument': ?instrument,
};

void main() {
  final fixture =
      jsonDecode(
            File('test/fixtures/payment_methods_v1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final fixtureWires = (fixture['methods'] as List)
      .map((m) => (m as Map<String, dynamic>)['wire'] as String)
      .toList();

  group('payment-method vocabulary', () {
    test('the model list equals the frozen fixture exactly', () {
      expect(
        TransactionEntry.knownPaymentMethods,
        unorderedEquals(fixtureWires),
      );
    });
  });

  group('TransactionEntry.fromJson payment_method', () {
    test('keeps every fixture value, including the legacy upi', () {
      for (final wire in fixtureWires) {
        expect(
          TransactionEntry.fromJson(_row(paymentMethod: wire)).paymentMethod,
          wire,
        );
      }
    });

    test('missing, null, unknown or non-string values become null, never throw',
        () {
      expect(TransactionEntry.fromJson(_row()).paymentMethod, isNull);
      expect(
        TransactionEntry.fromJson({..._row(), 'payment_method': null})
            .paymentMethod,
        isNull,
      );
      for (final bad in <Object>['bitcoin', '', 'UPI', 'Cheque', 42, true, []]) {
        expect(
          TransactionEntry.fromJson(_row(paymentMethod: bad)).paymentMethod,
          isNull,
          reason: '$bad',
        );
      }
    });

    test('toJson/fromJson round-trips a method and omits it when absent', () {
      final withMethod = TransactionEntry.fromJson(
        _row(paymentMethod: 'cheque', instrument: 'upi_bank'),
      );
      final json = withMethod.toJson();
      expect(json['payment_method'], 'cheque');
      expect(TransactionEntry.fromJson(json).paymentMethod, 'cheque');
      expect(
        TransactionEntry.fromJson(_row()).toJson().containsKey('payment_method'),
        isFalse,
      );
    });
  });

  group('TxnInstrument.fromJson', () {
    test('known values map to themselves', () {
      for (final i in TxnInstrument.values) {
        expect(TxnInstrument.fromJson(i.wireValue), i);
      }
    });

    test('an unrecognised value is NOT read as a credit card', () {
      expect(TxnInstrument.fromJson('crypto_wallet'), TxnInstrument.other);
      expect(TxnInstrument.fromJson(''), TxnInstrument.other);
      expect(
        TransactionEntry.fromJson(_row(instrument: 'crypto_wallet')).instrument,
        TxnInstrument.other,
      );
    });

    test('a missing value keeps the historical default and is flagged unknown',
        () {
      expect(TxnInstrument.fromJson(null), TxnInstrument.creditCard);
      final entry = TransactionEntry.fromJson(_row());
      expect(entry.instrument, TxnInstrument.creditCard);
      expect(entry.instrumentKnown, isFalse);
    });
  });

  group('logTransaction request body', () {
    Future<String> post({String? paymentMethod}) async {
      late String body;
      final repo = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((request) async {
          body = request.body;
          return http.Response(
            jsonEncode({
              'transaction': {'id': 't1'},
            }),
            201,
          );
        }),
      );
      await repo.logTransaction(
        amount: Money.fromRupees(500),
        instrument: TxnInstrument.upiBank,
        clientMutationId: 'm1',
        paymentMethod: paymentMethod,
      );
      return body;
    }

    test('omits paymentMethod when not supplied (byte-identical to before)',
        () async {
      expect(
        await post(),
        jsonEncode({
          'amountInr': Money.fromRupees(500).rupees,
          'occurredAt': null,
          'instrument': 'upi_bank',
          'entryKind': 'spend',
          'clientMutationId': 'm1',
        }),
      );
    });

    test('includes paymentMethod when supplied', () async {
      final body = jsonDecode(await post(paymentMethod: 'neft')) as Map;
      expect(body['paymentMethod'], 'neft');
      expect(body['instrument'], 'upi_bank');
    });
  });

  group('editTransaction PATCH body', () {
    Future<Map<String, dynamic>> patch(
      Future<void> Function(UserCardsRepository repo) call,
    ) async {
      late http.Request seen;
      final repo = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
      );
      await call(repo);
      expect(seen.method, 'PATCH');
      expect(seen.url.path, '/transactions/txn-1');
      return jsonDecode(seen.body) as Map<String, dynamic>;
    }

    test('absence never clears: no paymentMethod key unless supplied', () async {
      final body = await patch((r) => r.editTransaction('txn-1', amountInr: 10));
      expect(body, {'amountInr': 10});
      expect(body.containsKey('paymentMethod'), isFalse);
    });

    test('a supplied method is sent', () async {
      final body = await patch(
        (r) => r.editTransaction('txn-1', paymentMethod: 'cheque'),
      );
      expect(body, {'paymentMethod': 'cheque'});
    });

    test('clearPaymentMethod sends an explicit null', () async {
      final body = await patch(
        (r) => r.editTransaction('txn-1', clearPaymentMethod: true),
      );
      expect(body.containsKey('paymentMethod'), isTrue);
      expect(body['paymentMethod'], isNull);
    });

    test('clearing and setting at once is rejected', () async {
      final repo = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(
        () => repo.editTransaction(
          'txn-1',
          paymentMethod: 'neft',
          clearPaymentMethod: true,
        ),
        throwsArgumentError,
      );
    });
  });
}
