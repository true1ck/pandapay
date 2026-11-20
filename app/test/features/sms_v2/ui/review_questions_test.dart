// The Needs review screen counts the questions the person must answer (one per
// group of messages), and every question can be answered by editing the whole
// transaction, not only by the one or two canned answers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/bamboo_components.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/ui/review_clustering.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';

LocalReviewItem msg(
  String id,
  String body, {
  String kind = 'template',
  String? hash,
  DateTime? at,
  Map<String, Object?> payload = const {},
}) => LocalReviewItem(
  id: id,
  kind: kind,
  payload: {'sourceKey': id, 'templateHash': ?hash, ...payload},
  message: SmsIntakeEntry(
    id,
    QueuedSms(
      sender: 'VM-SBIUPI-S',
      body: body,
      receivedAt: at ?? DateTime.utc(2026, 10, 1),
    ),
  ),
);

const _declined =
    'Txn of Rs.81,467.00 on your HDFC Bank Card xx1234 was declined due to insufficient balance.';
const _debit = 'Rs.250.00 debited from A/c XX1234 on 05-11-26 to AMAZON Ref 1234';

Future<List<(List<LocalReviewItem>, String)>> pumpList(
  WidgetTester tester,
  List<LocalReviewItem> items,
) async {
  final calls = <(List<LocalReviewItem>, String)>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ReviewInboxList(
          items: items,
          onAction: (group, action) => calls.add((group, action)),
        ),
      ),
    ),
  );
  return calls;
}

void main() {
  group('the number is questions, not messages', () {
    test('messages of one format are one question', () {
      final items = [
        for (var i = 0; i < 5; i++) msg('a$i', _declined, hash: 'h-declined'),
        msg('b', _debit, hash: 'h-debit'),
      ];
      expect(items, hasLength(6));
      expect(reviewQuestionCount(items, reviewKindOf), 2);
    });

    test('an empty list is zero', () {
      expect(reviewQuestionCount(const [], reviewKindOf), 0);
    });

    test('questions that are never merged each count once', () {
      final items = [
        msg('l1', _debit, kind: 'link', hash: 'same'),
        msg('l2', _debit, kind: 'link', hash: 'same'),
        msg('b1', _debit, kind: 'bill_target', hash: 'same'),
        msg('b2', _debit, kind: 'bill_target', hash: 'same'),
      ];
      // Two "same payment?" questions, one bundle of two bill messages.
      expect(reviewQuestionCount(items, reviewKindOf), 3);
    });

    testWidgets('the filter chips count questions too', (tester) async {
      await pumpList(tester, [
        for (var i = 0; i < 5; i++) msg('a$i', _declined, hash: 'h-declined'),
        msg('b', _debit, hash: 'h-debit'),
      ]);
      expect(find.text('All (2)'), findsOneWidget);
      expect(find.text('All (6)'), findsNothing);
    });
  });

  group('every question can be answered by editing the transaction', () {
    testWidgets('a bill payment question offers Edit transaction', (tester) async {
      final calls = await pumpList(tester, [
        msg('b1', _debit, kind: 'bill_target', payload: {'eventId': 'ev1', 'hasReading': true}),
      ]);
      expect(find.text('Which card did this pay?'), findsOneWidget);
      expect(find.text('Edit transaction'), findsOneWidget);
      await tester.tap(find.text('Edit transaction'));
      expect(calls.single.$2, 'edit');
    });

    testWidgets('a reading the app made offers Edit transaction beside Correct', (tester) async {
      final calls = await pumpList(tester, [
        msg('r1', _debit, hash: 'h', payload: {'eventId': 'ev9', 'hasReading': true, 'reading': 'debit ₹250.0'}),
      ]);
      expect(find.text('Correct'), findsOneWidget);
      expect(find.text('Edit transaction'), findsOneWidget);
      await tester.tap(find.text('Edit transaction'));
      expect(calls.single.$2, 'edit');
    });

    testWidgets('a same-payment question offers it too', (tester) async {
      await pumpList(tester, [
        msg('k1', _debit, kind: 'link', payload: {'eventId': 'ev2', 'hasReading': true}),
      ]);
      expect(find.text('Choose match'), findsOneWidget);
      expect(find.text('Edit transaction'), findsOneWidget);
    });

    testWidgets('a message the app cannot read yet can be added as a transaction', (tester) async {
      final calls = await pumpList(tester, [msg('u1', _debit, hash: 'h-new')]);
      expect(find.text('Add as transaction'), findsOneWidget);
      await tester.tap(find.text('Add as transaction'));
      expect(calls.single.$2, 'edit');
    });

    testWidgets('the receipt question can add the payment yourself', (tester) async {
      final calls = await pumpList(tester, [
        LocalReviewItem(
          id: 'rc',
          kind: 'event',
          payload: {
            'reason': 'receipt_without_payment',
            'factId': 'f',
            'amountMinor': 1000,
            'receiptAt': '2026-11-07T10:00:00Z',
            'app': 'Airtel',
            'sourceKey': 'k',
            'hasReading': true,
          },
        ),
      ]);
      expect(find.text('Yes, I paid it'), findsOneWidget);
      expect(find.text('Add the payment yourself'), findsOneWidget);
      await tester.tap(find.text('Add the payment yourself'));
      expect(calls.single.$2, 'edit');
    });

    testWidgets('in a group of several messages, each message has its own Edit', (tester) async {
      final calls = await pumpList(tester, [
        for (var i = 0; i < 3; i++)
          msg('g$i', _debit, hash: 'h-g', payload: {'eventId': 'ev$i', 'hasReading': true}),
      ]);
      // The bar has no single transaction to edit; the expanded list does.
      expect(find.text('Edit transaction'), findsNothing);
      await tester.tap(find.text('Show all 3'));
      await tester.pump();
      expect(find.text('Edit'), findsNWidgets(3));
      await tester.tap(find.text('Edit').first);
      expect(calls.single.$1, hasLength(1));
      expect(calls.single.$2, 'edit');
    });
  });

  group('the card list is grouped by bank', () {
    testWidgets('a choice with a group shows one header per group', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showBambooChoiceSheet<String>(
                  context: context,
                  title: 'Which card?',
                  options: const [
                    BambooChoice(value: 'a', label: 'Millennia', detail: '••1111', group: 'HDFC Bank'),
                    BambooChoice(value: 'b', label: 'Regalia', detail: '••2222', group: 'HDFC Bank'),
                    BambooChoice(value: 'c', label: 'Simply Save', detail: '••3333', group: 'SBI Card'),
                  ],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('HDFC Bank'), findsOneWidget);
      expect(find.text('SBI Card'), findsOneWidget);
      expect(find.text('Regalia'), findsOneWidget);
    });
  });
}
