import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_badge.dart';
import 'package:pandapay/features/activity/transfer_mark_panel.dart';
import 'package:pandapay/features/sms_v2/ui/owner_identity_actions.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _entry({
  String? merchant = 'ASHA RAO',
  String? vpa,
  TxnEntryKind kind = TxnEntryKind.spend,
  String? transferType,
  String? note,
  String? paymentMethod,
  int pipelineVersion = 2,
  String? eventId = 'e1',
}) => TransactionEntry(
  id: 't1',
  pipelineVersion: pipelineVersion,
  eventId: eventId,
  amount: Money.fromRupees(1500),
  occurredAt: DateTime(2026, 11, 9),
  merchantName: merchant,
  merchantVpa: vpa,
  entryKind: kind,
  transferType: transferType,
  note: note,
  paymentMethod: paymentMethod,
  source: 'sms',
  status: 'active',
);

Future<void> _pump(WidgetTester tester, TransactionEntry entry) => tester.pumpWidget(
  ProviderScope(
    key: UniqueKey(),
    child: MaterialApp(
      home: Scaffold(body: TransferMarkPanel(entry: entry)),
    ),
  ),
);

void main() {
  group('the panel', () {
    testWidgets('a self transfer says so and offers to take it back or call it family', (tester) async {
      await _pump(tester, _entry(kind: TxnEntryKind.transfer, transferType: 'self'));
      expect(find.text('Self transfer'), findsOneWidget);
      expect(find.text('Not a self transfer'), findsOneWidget);
      expect(find.text('Mark as family transfer'), findsOneWidget);
      expect(find.text('Mark as self transfer'), findsNothing);
    });

    testWidgets('a family transfer says so and offers to take it back or call it self', (tester) async {
      await _pump(tester, _entry(kind: TxnEntryKind.transfer, transferType: 'family'));
      expect(find.text('Family transfer'), findsOneWidget);
      expect(find.text('Not a family transfer'), findsOneWidget);
      expect(find.text('Mark as self transfer'), findsOneWidget);
      expect(find.text('Mark as family transfer'), findsNothing);
    });

    testWidgets('an older own-transfer row is recognised by its label', (tester) async {
      await _pump(
        tester,
        _entry(merchant: 'Transfer between your accounts', kind: TxnEntryKind.transfer),
      );
      expect(find.text('Not a self transfer'), findsOneWidget);
    });

    testWidgets('a payment to a named payee can be marked either way', (tester) async {
      await _pump(tester, _entry());
      expect(find.text('Is this a transfer?'), findsOneWidget);
      expect(find.text('Mark as self transfer'), findsOneWidget);
      expect(find.text('Mark as family transfer'), findsOneWidget);
    });

    testWidgets('money in can be marked too, and a handle alone is a payee', (tester) async {
      await _pump(tester, _entry(merchant: null, vpa: 'a@b', kind: TxnEntryKind.income));
      expect(find.text('Mark as self transfer'), findsOneWidget);
      expect(find.text('Mark as family transfer'), findsOneWidget);
    });

    testWidgets('nothing is offered with no payee, for a card bill, a wallet, an old row or an investment', (tester) async {
      Future<void> none(TransactionEntry e) async {
        await _pump(tester, e);
        expect(find.text('Mark as self transfer'), findsNothing);
        expect(find.text('Mark as family transfer'), findsNothing);
      }

      await none(_entry(merchant: 'UNKNOWN'));
      await none(_entry(kind: TxnEntryKind.transfer, merchant: 'Credit card payment', transferType: 'card_bill'));
      await none(_entry(kind: TxnEntryKind.transfer, merchant: 'Paytm Wallet', transferType: 'wallet'));
      await none(_entry(pipelineVersion: 1, eventId: null));
      await none(_entry(kind: TxnEntryKind.investment));
    });
  });

  group('the scope question', () {
    Future<MarkScope?> ask(
      WidgetTester tester, {
      TransferMark mark = TransferMark.family,
      int earlier = 4,
      String? payee = 'KABIR RAO',
      required Future<void> Function() choose,
    }) async {
      MarkScope? result;
      var answered = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showTransferScopeSheet(
                    context: context,
                    mark: mark,
                    plan: MarkPlan(
                      payee: payee,
                      canRemember: true,
                      canMarkOnce: true,
                      earlier: earlier,
                    ),
                  );
                  answered = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await choose();
      await tester.pumpAndSettle();
      expect(answered, isTrue);
      return result;
    }

    testWidgets('says what Always covers, with the number of earlier payments', (tester) async {
      await ask(
        tester,
        choose: () async {
          expect(find.text('Mark as a family transfer?'), findsOneWidget);
          expect(find.text('Always'), findsOneWidget);
          expect(find.text('Only this payment'), findsOneWidget);
          expect(
            find.text('KABIR RAO: 4 earlier payments and every payment from now on.'),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('scope-always')));
        },
      );
    });

    testWidgets('Always returns always, Only this payment returns once', (tester) async {
      expect(
        await ask(tester, choose: () => tester.tap(find.byKey(const Key('scope-always')))),
        MarkScope.always,
      );
      expect(
        await ask(tester, choose: () => tester.tap(find.byKey(const Key('scope-once')))),
        MarkScope.once,
      );
    });

    testWidgets('wording for none and one earlier payment, and for a self transfer', (tester) async {
      await ask(
        tester,
        mark: TransferMark.self,
        earlier: 0,
        choose: () async {
          expect(find.text('Mark as a self transfer?'), findsOneWidget);
          expect(find.text('KABIR RAO: every payment from now on.'), findsOneWidget);
          await tester.tap(find.byKey(const Key('scope-once')));
        },
      );
      await ask(
        tester,
        earlier: 1,
        payee: null,
        choose: () async {
          expect(
            find.text('this payee: 1 earlier payment and every payment from now on.'),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('scope-once')));
        },
      );
    });

    testWidgets('dismissing the sheet changes nothing', (tester) async {
      expect(await ask(tester, choose: () => tester.tapAt(const Offset(10, 10))), isNull);
    });
  });

  group('the badge', () {
    test('is decided in one place from the note and the transfer type', () {
      expect(txnBadgeKind(_entry()), isNull);
      expect(txnBadgeKind(_entry(kind: TxnEntryKind.transfer, transferType: 'self')), TxnBadgeKind.selfTransfer);
      expect(txnBadgeKind(_entry(kind: TxnEntryKind.transfer, transferType: 'family')), TxnBadgeKind.familyTransfer);
      expect(txnBadgeKind(_entry(kind: TxnEntryKind.transfer, transferType: 'card_bill')), TxnBadgeKind.cardBill);
      expect(txnBadgeKind(_entry(kind: TxnEntryKind.transfer, transferType: 'wallet')), TxnBadgeKind.walletTopup);
      expect(txnBadgeKind(_entry(kind: TxnEntryKind.transfer)), isNull, reason: 'a plain transfer has no specific badge');
      expect(txnBadgeKind(_entry(note: 'x [ignored: refund]')), TxnBadgeKind.refund);
      expect(txnBadgeKind(_entry(note: '[ignored: reversal]')), TxnBadgeKind.reversal);
      // A spend is never badged as a transfer, whatever its type field says.
      expect(txnBadgeKind(_entry(transferType: 'family')), isNull);
    });

    test('has plain words for places that cannot draw a pill', () {
      expect(txnBadgeLabel(_entry(kind: TxnEntryKind.transfer, transferType: 'family')), 'Family transfer');
      expect(txnBadgeLabel(_entry()), isNull);
    });

    test('only the transfer badges count as transfers', () {
      expect(TxnBadgeKind.values.where((k) => k.isTransfer), [
        TxnBadgeKind.selfTransfer,
        TxnBadgeKind.familyTransfer,
        TxnBadgeKind.cardBill,
        TxnBadgeKind.walletTopup,
      ]);
    });
  });

  group('payment by NEFT, IMPS, RTGS or cheque', () {
    test('is flagged for a check only when it is an SMS payment to a named payee', () {
      expect(transferCheckMethod(_entry(paymentMethod: 'neft')), 'NEFT');
      expect(transferCheckMethod(_entry(paymentMethod: 'cheque')), 'Cheque');
      expect(transferCheckMethod(_entry(paymentMethod: 'upi')), isNull);
      expect(transferCheckMethod(_entry(paymentMethod: 'neft', merchant: 'UNKNOWN')), isNull);
      expect(transferCheckMethod(_entry(paymentMethod: 'neft', pipelineVersion: 1, eventId: null)), isNull);
      expect(
        transferCheckMethod(_entry(paymentMethod: 'neft', kind: TxnEntryKind.transfer, transferType: 'self')),
        isNull,
        reason: 'already a transfer',
      );
    });

    testWidgets('the panel names the method and still offers both marks', (tester) async {
      await _pump(tester, _entry(paymentMethod: 'rtgs'));
      expect(find.text('Paid by RTGS. Is this a transfer?'), findsOneWidget);
      expect(find.text('Mark as self transfer'), findsOneWidget);
      expect(find.text('Mark as family transfer'), findsOneWidget);
    });
  });
}
