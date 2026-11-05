import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TxnEntryKind;
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/flag.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/ui/ledger_screens.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

import '../support/scenario_model.dart';

/// Lane V: the product screens read from the real pipeline. Every model is a
/// golden scenario replayed through [SmsV2Runtime]; flag on only.
QueuedSms sms(String sender, String body, String at) =>
    QueuedSms(sender: sender, body: body, receivedAt: DateTime.parse(at));

final november = (
  DateTime.utc(2026, 10, 31, 18, 30),
  DateTime.utc(2026, 11, 30, 18, 30),
);

void main() {
  Future<LedgerReadModel> replay(
    WidgetTester tester,
    List<String> scenarios, {
    List<QueuedSms> extra = const [],
  }) async {
    late LedgerReadModel model;
    await tester.runAsync(() async {
      model = await replayScenarios(scenarios, extra: extra);
    });
    return model;
  }

  Future<void> show(
    WidgetTester tester,
    SmsLedgerScreen screen,
    LedgerReadModel model,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          smsPipelineV2EnabledProvider.overrideWithValue(true),
          smsV2LedgerReadModelProvider.overrideWith((_) async => model),
        ],
        child: MaterialApp(home: SmsLedgerScreenView(screen: screen)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder text(String s) => find.textContaining(s, findRichText: true);

  group('Your IPO applications', () {
    testWidgets('allotted: blocked then debited is one row, counted as investment', (
      tester,
    ) async {
      final model = await replay(tester, ['ipo_block_then_allotment']);
      await show(tester, SmsLedgerScreen.ipos, model);
      expect(find.text('TATA TECHNOLOGIES LTD'), findsOneWidget);
      expect(text('Allotted'), findsOneWidget);
      expect(text('Blocked ₹14,250.00 • Invested ₹14,250.00'), findsOneWidget);
      expect(text('Account ••1234'), findsOneWidget);
      expect(text('Applied 22 Nov 2026'), findsOneWidget);
      // The issuer is not shown as the platform.
      expect(text('TATA TECHNOLOGIES •'), findsNothing);
      final totals = model.snapshot().totals(november.$1, november.$2);
      expect(totals.investmentMinor, 1425000);
      expect(totals.spendMinor, 0);
    });

    testWidgets('released: shown as not allotted and changes no total', (
      tester,
    ) async {
      final model = await replay(tester, ['ipo_block_then_release']);
      await show(tester, SmsLedgerScreen.ipos, model);
      expect(find.text('TATA TECHNOLOGIES LTD'), findsOneWidget);
      expect(text('Not allotted, amount released'), findsOneWidget);
      expect(text('Released ₹14,250.00'), findsOneWidget);
      final totals = model.snapshot().totals(november.$1, november.$2);
      expect(totals.investmentMinor, 0);
      expect(totals.transactionCount, 0);
    });

    testWidgets('a block with no outcome yet reads applied, amount blocked', (
      tester,
    ) async {
      final model = await replay(
        tester,
        const [],
        extra: [
          sms(
            'VM-HDFCBK-S',
            'Rs.9,000.00 has been blocked in your A/c XX1234 towards ASBA application for ACME INDUSTRIES LTD IPO on 20-11-26. -HDFC Bank',
            '2026-11-20T09:00:00Z',
          ),
        ],
      );
      await show(tester, SmsLedgerScreen.ipos, model);
      expect(text('Applied, amount blocked'), findsOneWidget);
      expect(text('Blocked ₹9,000.00 • Invested ₹0.00'), findsOneWidget);
      // A hold is not an investment and not spending.
      final totals = model.snapshot().totals(november.$1, november.$2);
      expect(totals.investmentMinor, 0);
      expect(totals.spendMinor, 0);
    });

    testWidgets('three different applications are three rows, newest first', (
      tester,
    ) async {
      final model = await replay(
        tester,
        ['ipo_block_then_allotment'],
        extra: [
          sms(
            'VM-HDFCBK-S',
            'Rs.9,000.00 has been blocked in your A/c XX1234 towards ASBA application for ACME INDUSTRIES LTD IPO on 24-11-26. -HDFC Bank',
            '2026-11-24T09:00:00Z',
          ),
        ],
      );
      await show(tester, SmsLedgerScreen.ipos, model);
      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title as Text).data)
          .toList();
      expect(titles, ['ACME INDUSTRIES LTD', 'TATA TECHNOLOGIES LTD']);
    });
  });

  group('Investments', () {
    testWidgets('IPO and direct dividends are not spending or fake platforms', (
      tester,
    ) async {
      final model = await replay(tester, [
        'ipo_block_then_allotment',
        'dividend_credit',
      ]);
      await show(tester, SmsLedgerScreen.investments, model);
      expect(find.text('IPO allotments'), findsOneWidget);
      expect(text('Put in ₹14,250.00 • Taken out ₹0.00'), findsOneWidget);
      expect(text('Net invested ₹14,250.00'), findsOneWidget);
      expect(find.text('Dividends paid to bank'), findsOneWidget);
      expect(text('Dividends ₹1,200.00'), findsOneWidget);
      expect(text('UNKNOWN SERVICE'), findsNothing);
      expect(text('TATA TECHNOLOGIES LTD'), findsNothing);
      final totals = model.snapshot().totals(november.$1, november.$2);
      expect(totals.spendMinor, 0, reason: 'investments are never spending');
      expect(totals.investmentMinor, 1425000);
      expect(
        model.ledger.entries.where((e) => e.isInvestment).length,
        1,
        reason: 'only the allotment debit is an investment entry',
      );
    });
  });

  group('Money in', () {
    testWidgets('salary, dividends, refunds and people; no own transfers', (
      tester,
    ) async {
      final model = await replay(
        tester,
        [
          'lanej_salary_two_months_same_payer',
          'dividend_credit',
          'refund_after_purchase',
          'self_transfer',
          'card_bill_pair',
        ],
        extra: [
          sms(
            'VM-HDFCBK-S',
            'Rs.2,500.00 credited to A/c XX1234 on 12-11-26 by UPI Ref 432100123456 from RAVI KUMAR (ravi@okhdfc).',
            '2026-11-12T07:00:00Z',
          ),
        ],
      );
      await show(tester, SmsLedgerScreen.moneyIn, model);
      expect(find.text('Salary'), findsOneWidget);
      expect(find.text('Dividends'), findsOneWidget);
      expect(find.text('Refunds'), findsOneWidget);
      expect(find.text('From people'), findsOneWidget);
      // Two salary credits from ACME TECHNOLOGIES, once each.
      expect(find.text('ACME TECHNOLOGIES'), findsNWidgets(2));
      expect(find.text('₹85,000.00'), findsNWidgets(2));
      expect(find.text('₹1,70,000.00'), findsOneWidget);
      // The refund is named after the merchant, not an unknown service.
      expect(find.text('SWIGGY'), findsOneWidget);
      expect(find.text('Unknown service'), findsNothing);
      // The own transfer and the card payment never appear.
      expect(find.text('₹20,000.00'), findsNothing);
      expect(find.text('₹25,000.00'), findsNothing);
      // Income total = salary + dividend + people; the refund is excluded.
      expect(find.text('₹1,73,700.00'), findsOneWidget);
      final totals = model.snapshot().totals(
        DateTime.utc(2026, 10, 31, 18, 30),
        DateTime.utc(2026, 12, 31, 18, 30),
      );
      expect(totals.incomeMinor, 17000000 + 120000 + 250000);
      expect(totals.refundMinor, 49900);
    });

    testWidgets('a salary with no payer text is salary from the second month', (
      tester,
    ) async {
      final model = await replay(
        tester,
        ['lanej_salary_two_months_same_payer'],
      );
      final rows = moneyIn(
        model.facts,
        model.snapshot().events,
        DateTime.utc(2026),
        DateTime.utc(2028),
      );
      expect(rows.map((r) => r.kind), ['salary', 'salary']);
      expect(rows.map((r) => r.amountMinor), everyElement(8500000));
    });
  });

  group('Subscriptions', () {
    testWidgets('a mandate with a charge is active; the IPO mandate is not listed', (
      tester,
    ) async {
      final model = await replay(
        tester,
        ['mandate_then_charge', 'ipo_block_then_allotment'],
        extra: [
          sms(
            'VM-ICICIT-S',
            'Dear Customer, UPI Mandate for Rs 14,250.00 for IPO of TATA TECH has been successfully created and amount is blocked in A/c XX1234. UMRN 1234567890. -ICICI Bank',
            '2026-11-21T08:05:00Z',
          ),
          sms(
            'VM-ICICIT-S',
            'Dear Customer, you have approved the mandate of INR 15000.00 raised by SAMPLE WORKS LI on 10-Nov-26, through RRN 600100200300-ICICI Bank.',
            '2026-11-10T08:05:00Z',
          ),
        ],
      );
      await show(tester, SmsLedgerScreen.subscriptions, model);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('NETFLIX'), findsOneWidget);
      expect(find.text('₹649.00'), findsOneWidget);
      expect(find.byType(ListTile), findsOneWidget);
      expect(text('TATA'), findsNothing);
      expect(text('SAMPLE WORKS'), findsNothing);
      // The scheduled-debit notice is not an extra spend.
      final totals = model.snapshot().totals(november.$1, november.$2);
      expect(totals.spendMinor, 64900);
    });

    testWidgets('a cancelled service is one past row and keeps its last charge', (
      tester,
    ) async {
      final model = await replay(
        tester,
        ['mandate_then_charge'],
        extra: [
          sms(
            'VM-HDFCBK-S',
            'AutoPay mandate for NETFLIX has been revoked successfully on A/c XX1797.',
            '2026-12-01T08:00:00Z',
          ),
        ],
      );
      await show(tester, SmsLedgerScreen.subscriptions, model);
      expect(find.text('NETFLIX'), findsOneWidget);
      expect(find.text('Active'), findsNothing);
      expect(find.text('Past and interrupted'), findsOneWidget);
      expect(text('cancelled'), findsOneWidget);
      expect(find.text('₹649.00'), findsOneWidget);
    });

    testWidgets('a failed payment is a state on the service, never a spend', (
      tester,
    ) async {
      final model = await replay(
        tester,
        ['mandate_then_charge'],
        extra: [
          sms(
            'VM-HDFCBK-S',
            'AutoPay payment of Rs 649.00 towards NETFLIX failed due to insufficient balance. No money was debited.',
            '2026-12-05T08:00:00Z',
          ),
        ],
      );
      await show(tester, SmsLedgerScreen.subscriptions, model);
      expect(find.text('NETFLIX'), findsOneWidget);
      expect(text('failed payment'), findsOneWidget);
      final totals = model.snapshot().totals(
        DateTime.utc(2026, 10, 31, 18, 30),
        DateTime.utc(2026, 12, 31, 18, 30),
      );
      expect(totals.spendMinor, 64900);
    });
  });

  group('Card payments are not spending', () {
    testWidgets('bank debit plus card receipt is one own-to-own entry', (
      tester,
    ) async {
      final model = await replay(tester, ['card_bill_pair']);
      final totals = model.snapshot().totals(november.$1, november.$2);
      expect(totals.spendMinor, 0);
      expect(totals.transactionCount, 0);
      expect(model.ledger.entries.length, 1);
      expect(model.ledger.entries.single.amountMinor, 2500000);
      expect(model.ledger.entries.single.countsAsTransaction, isFalse);
      final rows = model.transactions;
      expect(rows.length, 1);
      expect(rows.single.entryKind, TxnEntryKind.transfer);
      expect(rows.single.merchantName, 'Credit card payment');
    });

    testWidgets('CHEQ, CRED and BBPS bill-pay are card payments, not spends', (
      tester,
    ) async {
      final model = await replay(
        tester,
        ['card_bill_via_cheq_no_receipt'],
        extra: [
          sms(
            'VM-HDFCBK-S',
            'Rs.5,000.00 debited from A/c XX1234 on 14-11-26 to VPA cred.club@axisb (UPI Ref No 432100998811). Avl bal Rs 60,100.40',
            '2026-11-14T10:15:00Z',
          ),
          sms(
            'VM-HDFCBK-S',
            'Rs.3,000.00 debited from A/c XX1234 on 15-11-26 towards BBPS - HDFC Bank Credit Card XX5678. Ref 11111',
            '2026-11-15T10:15:00Z',
          ),
        ],
      );
      final events = model.snapshot().events;
      expect(
        events.map((e) => e.type),
        everyElement(EventType.cardBillPayment),
      );
      expect(events.length, 3);
      final totals = model.snapshot().totals(november.$1, november.$2);
      expect(totals.spendMinor, 0);
      expect(totals.transactionCount, 0);
      expect(
        model.transactions.map((r) => r.merchantName),
        everyElement('Credit card payment'),
      );
      expect(
        model.transactions.map((r) => r.entryKind),
        everyElement(TxnEntryKind.transfer),
      );
    });

    testWidgets('own transfer stays out of money in and spending', (
      tester,
    ) async {
      final model = await replay(tester, ['self_transfer']);
      final totals = model.snapshot().totals(november.$1, november.$2);
      expect(totals.spendMinor, 0);
      expect(totals.incomeMinor, 0);
      expect(totals.transactionCount, 0);
      await show(tester, SmsLedgerScreen.moneyIn, model);
      expect(find.byType(ListTile), findsNothing);
    });
  });

  testWidgets('empty states read as empty, not broken', (tester) async {
    final model = LedgerReadModel(ledger: _empty());
    for (final screen in SmsLedgerScreen.values) {
      await show(tester, screen, model);
      expect(text('Nothing here yet'), findsOneWidget);
    }
    expect(ipoApplications(const [], const []), isEmpty);
  });
}

LedgerSnapshot _empty() => LedgerSnapshot(entries: [], events: []);
