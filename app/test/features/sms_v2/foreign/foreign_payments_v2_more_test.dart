import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/foreign_payment.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

// Foreign ATM withdrawals, non-card foreign debits, markup fees and EMI
// conversions through the v2 pipeline into the Foreign payments records.
// Synthetic messages only.

const _ns = 'user:test';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;
  var seq = 0;

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: testRuleBundle(),
      appVersion: '2.0.0',
    );
    seq = 0;
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  String key() => (++seq).toRadixString(16).padLeft(64, 'b');

  SmsMessage sms(String body, {DateTime? at, String sender = 'VM-HDFCBK-S'}) =>
      SmsMessage(
        sender: sender,
        body: body,
        sourceKey: key(),
        observedAt: at ?? DateTime.utc(2026, 11, 1, 7),
      );

  Future<Map<String, ForeignPayment>> rows() async {
    ensureForeignPaymentsSchema(db);
    final all = await ForeignPaymentsRepository(
      database: Future.value(db),
      namespace: _ns,
      apiBaseUrl: 'https://fixture.test',
      client: MockClient((_) async => http.Response('{}', 500)),
      accessToken: () => null,
    ).fetchAll(refresh: false);
    return {for (final p in all) p.sourceKey: p};
  }

  int ledgerSpend() => LedgerStore(
    db.db,
    namespace: _ns,
  ).list().where((e) => e.isSpend).fold(0, (sum, e) => sum + e.amountMinor);

  List<Map<String, dynamic>> transactions() =>
      financial.entities(_ns, 'transactions').toList();

  group('foreign ATM withdrawals', () {
    test(
      'a foreign-only withdrawal is a pending cash-withdrawal record, never INR',
      () async {
        final m = sms(
          'Cash withdrawal of USD 200.00 at ATM using your Debit Card XX1234 on 01-11-26.',
        );
        expect(pipeline.process(m), isTrue);
        expect(transactions(), isEmpty);
        expect(ledgerSpend(), 0);
        final p = (await rows())[m.sourceKey]!;
        expect(p.originalCurrency, 'USD');
        expect(p.originalAmount, '200');
        expect(p.valuationStatus, 'awaiting_rate');
        expect(p.billedInr, isNull);
        expect(p.direction, 'spend');
        expect(p.cardLast4, '1234');
        expect(p.instrument, 'debit_card');
        expect(p.merchantName, 'ATM withdrawal');
        expect(p.categoryName, 'Cash withdrawal');
        expect(p.isCashWithdrawal, isTrue);
      },
    );

    test(
      'a withdrawal that states the INR counts once and is confirmed beside it',
      () async {
        final m = sms(
          'Rs.17,450.00 withdrawn from Debit Card x1234 at ATM on 01-11-26 (USD 200.00)',
        );
        pipeline.process(m);
        expect(ledgerSpend(), 1745000);
        expect(transactions(), hasLength(1));
        final p = (await rows())[m.sourceKey]!;
        expect(p.valuationStatus, 'confirmed');
        expect(p.billedInr?.paise, 1745000);
        expect(p.transactionId, transactions().single['id']);
      },
    );

    test('the billed withdrawal settles the earlier foreign-only one', () async {
      final first = sms(
        'Cash withdrawal of USD 200.00 at ATM using your Debit Card XX1234 on 01-11-26.',
      );
      final billed = sms(
        'Rs.17,450.00 withdrawn from Debit Card x1234 at ATM on 02-11-26 (USD 200.00)',
        at: DateTime.utc(2026, 11, 2, 7),
      );
      pipeline.process(first);
      pipeline.process(billed);
      final all = await rows();
      expect(all[first.sourceKey]!.valuationStatus, 'ignored');
      expect(all[billed.sourceKey]!.valuationStatus, 'confirmed');
      expect(ledgerSpend(), 1745000, reason: 'one withdrawal, counted once');
    });

    test(
      'a withdrawal never settles a purchase of the same amount, or the reverse',
      () async {
        final purchase = sms(
          'Spent USD 200.00 on Debit Card x1234 at SAMPLE HOTEL on 2026-11-01:07:00:11.',
        );
        final atmBilled = sms(
          'Rs.17,450.00 withdrawn from Debit Card x1234 at ATM on 02-11-26 (USD 200.00)',
          at: DateTime.utc(2026, 11, 2, 7),
        );
        final atmOnly = sms(
          'Cash withdrawal of EUR 50.00 at ATM using your Debit Card XX1234 on 03-11-26.',
          at: DateTime.utc(2026, 11, 3, 7),
        );
        final purchaseBilled = sms(
          'Spent Rs.4,600.00 on Debit Card x1234 at SAMPLE CAFE (EUR 50.00) on 2026-11-03:09:00:11.',
          at: DateTime.utc(2026, 11, 3, 9),
        );
        pipeline.processBatch([purchase, atmBilled, atmOnly, purchaseBilled]);
        final all = await rows();
        expect(all[purchase.sourceKey]!.isPending, isTrue);
        expect(all[atmOnly.sourceKey]!.isPending, isTrue);
        expect(all[atmBilled.sourceKey]!.valuationStatus, 'confirmed');
        expect(all[purchaseBilled.sourceKey]!.valuationStatus, 'confirmed');
      },
    );
  });

  group('non-card foreign debits', () {
    test('a forex card spend is a card record', () async {
      final m = sms(
        'Your Forex Card XX1234 has been debited with EUR 50.00 at SAMPLE CAFE on 01-11-26. Available balance EUR 450.00.',
      );
      pipeline.process(m);
      final p = (await rows())[m.sourceKey]!;
      expect(p.originalCurrency, 'EUR');
      expect(p.originalAmount, '50');
      expect(p.cardLast4, '1234');
      expect(p.accountLast4, isNull);
      expect(p.merchantName, 'SAMPLE CAFE');
      expect(p.valuationStatus, 'awaiting_rate');
      expect(ledgerSpend(), 0);
    });

    test('a bank account debit is an account record', () async {
      final m = sms(
        'USD 100.00 debited from your A/c XX1234 on 01-11-26 towards SAMPLE REMIT. Ref 612345678901.',
      );
      pipeline.process(m);
      final p = (await rows())[m.sourceKey]!;
      expect(p.accountLast4, '1234');
      expect(p.cardLast4, isNull);
      expect(p.instrument, 'upi_bank');
      expect(p.merchantName, 'SAMPLE REMIT');
      expect(ledgerSpend(), 0);
    });
  });

  group('markup fees', () {
    test(
      'a fee is INR spend, never a foreign record, and leaves the purchase pending',
      () async {
        final purchase = sms(
          'Spent USD 20.00 on Credit Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.',
        );
        final fee = sms(
          'Forex markup fee of Rs 52.50 charged on your Credit Card XX1234 for transaction of USD 20.00 at SAMPLE AI on 03-11-26.',
          at: DateTime.utc(2026, 11, 3, 10),
        );
        pipeline.process(purchase);
        pipeline.process(fee);
        final all = await rows();
        expect(all.keys, [
          purchase.sourceKey,
        ], reason: 'the fee is not a foreign payment');
        expect(all[purchase.sourceKey]!.valuationStatus, 'awaiting_rate');
        expect(ledgerSpend(), 5250);
        expect(transactions(), hasLength(1));
      },
    );
  });

  group('EMI conversion', () {
    test(
      'converting a foreign purchase to EMI adds no record and no spend',
      () async {
        final purchase = sms(
          'Spent Rs.43,500.00 on Credit Card x1234 at SAMPLE STORE (USD 500.00) on 2026-11-01:07:00:11.',
        );
        final emi = sms(
          'Your transaction of USD 500.00 at SAMPLE STORE on Credit Card XX1234 has been converted to EMI of Rs 7,350.00 for 6 months.',
          at: DateTime.utc(2026, 11, 4, 10),
        );
        pipeline.process(purchase);
        pipeline.process(emi);
        final all = await rows();
        expect(all.keys, [purchase.sourceKey]);
        expect(all[purchase.sourceKey]!.valuationStatus, 'confirmed');
        expect(ledgerSpend(), 4350000);
        expect(transactions(), hasLength(1));
      },
    );
  });

  test('raw SMS text never reaches the outbox for the new shapes', () {
    pipeline.process(
      sms(
        'Cash withdrawal of USD 200.00 at ATM using your Debit Card XX1234 on 01-11-26.',
      ),
    );
    pipeline.process(
      sms(
        'USD 100.00 debited from your A/c XX1234 on 01-11-26 towards SAMPLE REMIT. Ref 612345678901.',
      ),
    );
    for (final r in db.db.select(
      'SELECT payload FROM foreign_payments_outbox',
    )) {
      final body = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
      expect(jsonEncode(body), isNot(contains('withdrawal of USD')));
      expect(jsonEncode(body), isNot(contains('debited from')));
    }
  });
}
