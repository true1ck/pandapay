import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/premium_reminders.dart';
import 'package:pandapay/features/home/money_went_screen.dart';
import 'package:pandapay/features/insights/bill_detail_screen.dart';
import 'package:pandapay/features/insights/bill_proof_section.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/sms_v2.dart' show Totals;

// Synthetic names and messages only: the repository is public.
const _sms =
    'Your SIP instalment of Rs 5,000 in Flexi Cap Fund is due on 05-Nov-26. '
    'Keep sufficient balance in account 123456789012.';

Commitment _sip({CommitmentStatus status = CommitmentStatus.due, String? txn}) =>
    Commitment(
      id: 'v2:abc',
      title: 'Flexi Cap Fund SIP',
      category: CommitmentCategory.investment,
      amount: Money.fromRupees(5000),
      dueOn: DateTime(2026, 11, 5),
      cadence: CommitmentCadence.monthly,
      status: status,
      paidOn: status == CommitmentStatus.paid ? DateTime(2026, 11, 5) : null,
      linkedTransactionId: txn,
      sourceKey: 'sms:src',
      confidence: .95,
    );

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(430, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        smsV2LedgerReadModelProvider.overrideWith(
          (ref) async => throw StateError('no ledger in this test'),
        ),
        billProofSmsProvider.overrideWith(
          (ref, key) async => key == 'sms:src'
              ? SmsIntakeEntry(
                  key,
                  QueuedSms(
                    sender: 'VM-FUNDCO-S',
                    body: _sms,
                    receivedAt: DateTime(2026, 11, 1, 9),
                  ),
                )
              : null,
        ),
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a SIP page reads like a transaction: amount, rows, SMS evidence',
      (tester) async {
    await _pump(tester, BillDetailScreen(commitment: _sip()));

    expect(find.text('Bill details'), findsOneWidget);
    expect(find.text('₹5,000'), findsOneWidget);
    expect(find.text('Flexi Cap Fund SIP'), findsOneWidget);
    expect(find.text('SIP'), findsWidgets); // the kind badge
    expect(find.text('Investment / SIP'), findsOneWidget);
    expect(find.textContaining('Thursday, 5 November 2026'), findsOneWidget);
    expect(find.text('Repeats'), findsOneWidget);
    expect(find.text('SMS evidence'), findsOneWidget);
    expect(find.text('Amount detected'), findsOneWidget);
    expect(find.text('Original SMS captured on this device'), findsOneWidget);
    // Long digits in the message are masked.
    expect(find.textContaining('•••• 9012'), findsOneWidget);
    expect(find.textContaining('123456789012'), findsNothing);
    expect(find.text('Mark as paid'), findsOneWidget);
    expect(find.text('Dismiss detected bill'), findsOneWidget);
  });

  testWidgets('a paid bill links to its payment and offers no Mark as paid', (
    tester,
  ) async {
    await _pump(
      tester,
      BillDetailScreen(
        commitment: _sip(status: CommitmentStatus.paid, txn: 'v2:evt'),
      ),
    );
    expect(find.text('Paid'), findsWidgets);
    expect(find.text('Paid on'), findsOneWidget);
    expect(find.text('View payment & receipt'), findsOneWidget);
    expect(find.text('Mark as paid'), findsNothing);
  });

  testWidgets('an insurance premium notice names the month, not a day', (
    tester,
  ) async {
    await _pump(
      tester,
      BillDetailScreen.premium(
        PremiumReminder(
          id: 'p',
          title: 'Sunrise Life Insurance',
          category: CommitmentCategory.insurance,
          accountLast4: '6789',
          premiumMonth: DateTime(2026, 12),
          receivedAt: DateTime(2026, 11, 2),
          sampleBody: 'Next Premium falls due on 12/2026',
          sourceKey: 'sms:src',
        ),
      ),
    );
    expect(find.text('Premium details'), findsOneWidget);
    expect(find.text('INSURANCE'), findsOneWidget);
    expect(find.text('Premium due'), findsOneWidget);
    expect(find.text('December 2026 · day not stated'), findsOneWidget);
    expect(find.text('Policy'), findsOneWidget);
    expect(find.text('Mark as paid'), findsNothing);
    expect(find.text('SMS evidence'), findsOneWidget);
  });

  testWidgets('a past premium notice keeps its status and message', (
    tester,
  ) async {
    await _pump(
      tester,
      BillDetailScreen.past(
        PastBillReceipt(
          id: 'past-premium-x',
          sourceKey: 'sms:src',
          merchant: 'Sunrise Life Insurance',
          kind: PastBillReceiptKind.bill,
          amount: null,
          occurredAt: DateTime(2026, 8, 20),
          receivedAt: DateTime(2026, 8, 20),
          status: PastBillReceiptStatus.needsConfirmation,
          categoryName: 'insurance',
          dueDate: DateTime(2026, 9, 30),
          dueMonthOnly: true,
        ),
      ),
    );
    expect(find.text('Needs your confirmation'), findsOneWidget);
    expect(find.text('September 2026 · day not stated'), findsOneWidget);
    expect(find.text('Mark as paid'), findsNothing);
  });

  testWidgets('Home: tapping Investments opens the investment transactions', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: MoneyFlowLines(
              totals: const Totals(
                spendMinor: 100000,
                refundMinor: 0,
                incomeMinor: 0,
                investmentMinor: 500000,
                investmentOutMinor: 500000,
                transactionCount: 2,
                byCategory: {},
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/activity',
          builder: (_, state) => Scaffold(
            body: Text('activity ${state.uri.queryParameters['type']}'),
          ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home_investments_line')));
    await tester.pumpAndSettle();
    expect(find.text('activity investments'), findsOneWidget);
  });
}
