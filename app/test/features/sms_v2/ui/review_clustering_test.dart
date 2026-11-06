import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/ui/dismissed_reviews_view.dart';
import 'package:pandapay/features/sms_v2/ui/review_clustering.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';

LocalReviewItem item(
  String id,
  String sender,
  String body, {
  String kind = 'template',
  DateTime? at,
  Map<String, Object?> payload = const {},
}) => LocalReviewItem(
  id: id,
  kind: kind,
  payload: {'sourceKey': id, ...payload},
  message: SmsIntakeEntry(
    id,
    QueuedSms(
      sender: sender,
      body: body,
      receivedAt: at ?? DateTime.utc(2026, 10, 1),
    ),
  ),
);

List<ReviewBundle> bundle(List<LocalReviewItem> items) =>
    bundleReviewItems(items, reviewKindOf);

void main() {
  group('cleanReviewSender', () {
    test('drops carrier prefix and route suffix', () {
      expect(cleanReviewSender('AX-HDFCBK-S'), 'HDFCBK');
      expect(cleanReviewSender('VM-AXIOIN-T'), 'AXIOIN');
      expect(cleanReviewSender('SIMPL'), 'SIMPL');
    });
  });

  group('classifyReviewContent', () {
    test('real messages from a migrated history', () {
      expect(
        classifyReviewContent(
          'Txn of Rs.81,467.00 on your HDFC Bank Card xx1234 was declined due to insufficient balance. Not you? Call 18002586161',
        ),
        ReviewContent.declined,
      );
      expect(
        classifyReviewContent(
          'For the upcoming mandate set for 10-11-26, INR 1250.00 will be debited from your A/c towards BESCOM ELECTRICITY for Mandate.',
        ),
        ReviewContent.mandate,
      );
      expect(
        classifyReviewContent(
          'Credit Alert! Rs.1.00 credited to HDFC Bank A/c XX5552 on 30-10-26 from VPA x@oksbi',
        ),
        ReviewContent.credit,
      );
      expect(
        classifyReviewContent(
          'Rs 549 debited to KFC INDIA via UPI on 31-10-2026. Account XX9876 balance Rs 39800',
        ),
        ReviewContent.debit,
      );
      expect(
        classifyReviewContent(
          'HDFC Bank: Rs.899.00 debited from A/c XX1234 through UPI to UBER EATS. Avl Bal Rs.12345.00',
        ),
        ReviewContent.debit,
      );
    });
    test('other kinds', () {
      expect(
        classifyReviewContent('Your OTP is 123456. Do not share it.'),
        ReviewContent.security,
      );
      expect(
        classifyReviewContent('Pre-approved loan offer! Apply now.'),
        ReviewContent.promotion,
      );
      expect(
        classifyReviewContent('Your card bill is due on 05-12-2026.'),
        ReviewContent.bill,
      );
      expect(
        classifyReviewContent('Avl Bal in your A/c XX1234 is Rs 5000'),
        ReviewContent.balance,
      );
      expect(classifyReviewContent('Welcome aboard'), ReviewContent.other);
    });
    test('a payment with a trailing balance is not a balance update', () {
      // The synthetic UPI message the emulator smoke test uses.
      expect(
        classifyReviewContent(
          'Sent Rs.250.00\nFrom HDFC Bank A/C *1797\nTo VPA 9876543210@ybl\nOn 11/05/25\nRef 412345678901 Avl Bal Rs.12,345.67',
        ),
        ReviewContent.debit,
      );
      // Unknown wording with an amount first stays "other", never an alert.
      expect(
        classifyReviewContent('Rs.250 moved on your account. Avl Bal Rs.5000'),
        ReviewContent.other,
      );
      // A pure balance notice is still a balance notice.
      expect(
        classifyReviewContent('Avl Bal in your A/c XX1234 is Rs 5000'),
        ReviewContent.balance,
      );
    });
    test('a reversal is money coming back, not a failed payment', () {
      expect(
        classifyReviewContent('Rs.1,250 reversed to your A/c XX1234'),
        ReviewContent.credit,
      );
      expect(
        classifyReviewContent('Payment of Rs.500 failed'),
        ReviewContent.declined,
      );
    });
    test('a promotion that moved money is still money', () {
      expect(
        classifyReviewContent('Rs.200 debited. Offer: 10% cashback soon'),
        ReviewContent.debit,
      );
    });
    test('the first verb decides when both appear', () {
      expect(
        classifyReviewContent('Rs.50 debited and Rs.5 cashback credited'),
        ReviewContent.debit,
      );
      expect(
        classifyReviewContent('Rs.5 cashback credited after Rs.50 debited'),
        ReviewContent.credit,
      );
    });
    test('only real movements are summable', () {
      for (final c in ReviewContent.values) {
        expect(
          c.summable,
          c == ReviewContent.debit || c == ReviewContent.credit,
        );
      }
    });
  });

  group('payLaterProviderOf', () {
    test('recognises providers by sender or opening words', () {
      expect(payLaterProviderOf('AD-AXIOIN-S', 'Your bill'), contains('Axio'));
      expect(payLaterProviderOf('VK-LZYPAY', 'LazyPay bill'), 'LazyPay');
      expect(payLaterProviderOf('X', 'Amazon Pay Later due'), contains('Axio'));
    });
    test('does not match ordinary words', () {
      expect(payLaterProviderOf('AX-HDFCBK-S', 'A simple axiom'), isNull);
      expect(payLaterProviderOf('AX-HDFCBK-S', 'Rs 5 spent on card'), isNull);
    });
    test('a bank offer that mentions a provider later on is not Pay Later', () {
      expect(
        payLaterProviderOf(
          'AX-HDFCBK-S',
          'HDFC Bank: Get 5% back on your next order when you pay with LazyPay',
        ),
        isNull,
      );
    });
  });

  group('amounts', () {
    int? amount(String body) =>
        reviewItemAmountMinor(item('a', 'AX-FOO-S', body));
    test('Indian grouping, decimals and INR', () {
      expect(amount('Rs 1,23,456.78 debited'), 12345678);
      expect(amount('INR 5,00,000 debited'), 50000000);
      expect(amount('₹1,200.5 spent'), 120050);
      expect(amount('Rs. 37.00 debited'), 3700);
    });
    test('never takes a prefix of a longer decimal', () {
      expect(amount('Rs.10.555 charged'), 1000);
    });
    test('zero and missing amounts are absent', () {
      expect(amount('Rs.0 debited'), isNull);
      expect(amount('No money here'), isNull);
    });
  });

  group('bundleReviewItems', () {
    test('same sender and format merge across amounts and dates', () {
      final bundles = bundle([
        item(
          'a',
          'AX-FOO-S',
          'Spent Rs.100.00 at Shop on 01-10-2026 card XX1234',
        ),
        item(
          'b',
          'VM-FOO-S',
          'Spent Rs.250.50 at Shop on 05-10-2026 card XX1234',
          at: DateTime.utc(2026, 10, 5),
        ),
      ]);
      expect(bundles, hasLength(1));
      expect(bundles.single.items.map((i) => i.id), ['b', 'a']);
      expect(bundles.single.totalMinor, 35050);
      expect(bundles.single.content, ReviewContent.debit);
      expect(bundles.single.uniformFormat, isTrue);
    });

    test('different formats or different kinds stay apart', () {
      final bundles = bundle([
        item('a', 'AX-FOO-S', 'Spent Rs.100 at Shop on card XX1234'),
        item('b', 'AX-FOO-S', 'Your statement is ready, call us today'),
        item(
          'c',
          'AX-FOO-S',
          'Spent Rs.100 at Shop on card XX1234',
          kind: 'instrument',
        ),
      ]);
      expect(bundles, hasLength(3));
    });

    test('receipts and links are never merged', () {
      const same = 'Paid Rs.100 via Kiwi on 01-10-2026';
      final bundles = bundle([
        item('l1', 'AX-FOO-S', same, kind: 'link'),
        item('l2', 'AX-FOO-S', same, kind: 'link'),
        item(
          'r1',
          'AX-FOO-S',
          same,
          payload: const {'reason': 'receipt_without_payment'},
        ),
      ]);
      expect(bundles.where((b) => b.kind == 'link'), hasLength(2));
      expect(bundles.every((b) => b.isSingle), isTrue);
    });

    test('Pay Later merges across formats but is not format-uniform', () {
      final bundles = bundle([
        item('a', 'AD-AXIOIN-S', 'Rs.1,200 used on Amazon Pay Later'),
        item(
          'b',
          'AD-AXIOIN-S',
          'Your Axio bill of Rs.3,400 is generated, pay by 05-11',
        ),
        item('c', 'VK-LZYPAY-S', 'LazyPay: Rs.500 spent'),
      ]);
      final axio = bundles.singleWhere((b) => b.items.length == 2);
      expect(axio.isPayLater, isTrue);
      expect(axio.uniformFormat, isFalse);
      expect(axio.content, isNull);
      // A bill and its drawdowns would double-count, so no total.
      expect(axio.totalMinor, isNull);
      expect(
        bundles.singleWhere((b) => b.items.length == 1).payLaterProvider,
        'LazyPay',
      );
    });

    test('declined payments and upcoming mandates show no total', () {
      final declined = bundle([
        item(
          'a',
          'AX-FOO-S',
          'Txn of Rs.500 on card xx1 was declined due to insufficient balance',
        ),
        item(
          'b',
          'AX-FOO-S',
          'Txn of Rs.900 on card xx1 was declined due to insufficient balance',
        ),
      ]).single;
      expect(declined.content, ReviewContent.declined);
      expect(declined.totalMinor, isNull);

      final mandates = bundle([
        item(
          'a',
          'AX-FOO-S',
          'For the upcoming mandate set for 10-11-26, INR 1250.00 will be debited towards BESCOM',
        ),
        item(
          'b',
          'AX-FOO-S',
          'For the upcoming mandate set for 05-12-26, INR 1250.00 will be debited towards BESCOM',
        ),
      ]).single;
      expect(mandates.content, ReviewContent.mandate);
      expect(mandates.totalMinor, isNull);
    });

    test('total is withheld unless every member has an amount', () {
      final forced = bundle([
        item(
          'a',
          'AX-FOO-S',
          'Spent Rs.100 at Shop',
          payload: const {'templateHash': 'h'},
        ),
        item(
          'b',
          'AX-FOO-S',
          'Spent at Shop',
          payload: const {'templateHash': 'h'},
        ),
      ]);
      expect(forced.single.totalMinor, isNull);
    });

    test('messages whose text is gone stay single and never crash', () {
      const gone = LocalReviewItem(
        id: 'gone',
        kind: 'template',
        payload: {'sourceKey': 'gone'},
      );
      final bundles = bundle([gone, item('a', 'AX-FOO-S', 'Spent Rs.1')]);
      expect(bundles, hasLength(2));
      expect(reviewMonthKey(gone), isNull);
      expect(reviewContentOf(gone), ReviewContent.other);
    });

    test('newest bundle first, stable order', () {
      final bundles = bundle([
        item('old', 'AX-ONE-S', 'one message', at: DateTime.utc(2026, 1, 1)),
        item('new', 'AX-TWO-S', 'two message', at: DateTime.utc(2026, 9, 1)),
      ]);
      expect(bundles.first.items.single.id, 'new');
    });
  });

  group('filters and months', () {
    ReviewFilter f(LocalReviewItem i) => reviewFilterOf(i, reviewKindOf);
    test('content decides the chip for unknown formats', () {
      expect(f(item('a', 'AX-F-S', 'Rs 5 debited')), ReviewFilter.spends);
      expect(f(item('b', 'AX-F-S', 'Rs 5 credited')), ReviewFilter.credits);
      expect(
        f(item('c', 'AX-F-S', 'Mandate set up for Rs 5')),
        ReviewFilter.bills,
      );
      expect(
        f(item('d', 'AX-F-S', 'Payment was declined')),
        ReviewFilter.alerts,
      );
      expect(f(item('e', 'AX-F-S', 'Welcome')), ReviewFilter.other);
    });
    test('question kinds keep their own chip; Pay Later wins', () {
      expect(f(item('a', 'AX-F-S', 'x', kind: 'link')), ReviewFilter.link);
      expect(
        f(item('b', 'AX-F-S', 'x', kind: 'category')),
        ReviewFilter.category,
      );
      expect(
        f(item('c', 'AX-F-S', 'x', kind: 'instrument')),
        ReviewFilter.account,
      );
      expect(
        f(item('d', 'AD-AXIOIN-S', 'Rs 5 debited', kind: 'instrument')),
        ReviewFilter.payLater,
      );
    });
    test('month keys and labels', () {
      final i = item('a', 'AX-F-S', 'x', at: DateTime(2026, 11, 6, 12));
      expect(reviewMonthKey(i), '2026-11');
      expect(reviewMonthLabel('2026-11'), 'Nov 2026');
    });
  });

  group('formatting', () {
    test('span', () {
      expect(
        formatBundleSpan(DateTime(2026, 10, 1), DateTime(2026, 10, 9)),
        'Oct 2026',
      );
      expect(
        formatBundleSpan(DateTime(2026, 8, 1), DateTime(2026, 10, 9)),
        'Aug – Oct 2026',
      );
      expect(
        formatBundleSpan(DateTime(2025, 12, 1), DateTime(2026, 2, 9)),
        'Dec 2025 – Feb 2026',
      );
    });
    test('rupees use Indian grouping', () {
      expect(formatRupeesMinor(1840000), '₹18,400');
      expect(formatRupeesMinor(35050), '₹350.50');
    });
  });

  group('DismissedReviewList', () {
    testWidgets('groups by format and moves a group back', (tester) async {
      final moved = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DismissedReviewList(
              items: [
                item('a', 'AX-FOO-S', 'Txn of Rs.5 failed'),
                item('b', 'AX-FOO-S', 'Txn of Rs.9 failed'),
                item('c', 'AX-BAR-S', 'Your OTP is 1. Do not share it.'),
              ],
              onRestore: (items) => moved.add(items.length),
            ),
          ),
        ),
      );
      expect(find.text('Move back to review'), findsNWidgets(2));
      // Bundles are ordered by recency then key; the two-message format and
      // the one-message format each get their own button.
      await tester.tap(find.text('Move back to review').first);
      await tester.tap(find.text('Move back to review').last);
      expect(moved.toList()..sort(), [1, 2]);
    });

    testWidgets('says so when nothing was dismissed', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DismissedReviewList(items: const [], onRestore: (_) {}),
          ),
        ),
      );
      expect(find.text('Nothing dismissed'), findsOneWidget);
    });
  });

  group('ReviewInboxList', () {
    Widget host(
      List<LocalReviewItem> items,
      void Function(List<LocalReviewItem>, String) onAction,
    ) => MaterialApp(
      home: Scaffold(
        body: ReviewInboxList(items: items, onAction: onAction),
      ),
    );

    List<LocalReviewItem> spends() => [
      for (var i = 0; i < 3; i++)
        item(
          'm$i',
          'AX-FOO-S',
          'Spent Rs.${100 + i} at Shop on card XX1234',
          at: DateTime.utc(2026, 10, 1 + i),
        ),
    ];

    testWidgets('a bundle acts on all members and can be expanded', (
      tester,
    ) async {
      final calls = <String>[];
      await tester.pumpWidget(
        host(spends(), (group, action) => calls.add('$action:${group.length}')),
      );
      expect(find.textContaining('3 messages · Money out'), findsOneWidget);
      expect(find.textContaining('total'), findsOneWidget);
      await tester.tap(find.text('Show all 3'));
      await tester.pump();
      expect(find.text('Hide messages'), findsOneWidget);
      await tester.ensureVisible(find.text('Not financial (all)'));
      await tester.pump();
      await tester.tap(find.text('Not financial (all)'));
      expect(calls, ['ignore:3']);
    });

    testWidgets('Pay Later bundle withholds Fix and Correct', (tester) async {
      await tester.pumpWidget(
        host([
          item('a', 'AD-AXIOIN-S', 'Rs.1,200 used on Amazon Pay Later'),
          item('b', 'AD-AXIOIN-S', 'Your Axio bill of Rs.3,400 is generated'),
        ], (_, _) {}),
      );
      expect(find.textContaining('Amazon Pay Later (Axio)'), findsOneWidget);
      expect(find.text('Fix'), findsNothing);
      expect(find.text('Correct'), findsNothing);
      expect(find.text('Not financial (all)'), findsOneWidget);
    });

    testWidgets('type chips filter and show counts', (tester) async {
      await tester.pumpWidget(
        host([
          ...spends(),
          item('d', 'AX-BAR-S', 'Txn of Rs.500 was declined'),
          item('c', 'AX-BAZ-S', 'Credit Alert! Rs.1 credited'),
        ], (_, _) {}),
      );
      expect(find.text('All (5)'), findsOneWidget);
      expect(find.text('Money out (3)'), findsOneWidget);
      expect(find.text('Money in (1)'), findsOneWidget);
      expect(find.text('Declined & alerts (1)'), findsOneWidget);
      await tester.tap(find.text('Declined & alerts (1)'));
      await tester.pump();
      expect(find.textContaining('declined'), findsWidgets);
      expect(find.textContaining('Spent Rs.'), findsNothing);
      await tester.tap(find.text('All (5)'));
      await tester.pump();
      expect(find.textContaining('Spent Rs.'), findsWidgets);
    });

    testWidgets('month chips appear only with more than one month', (
      tester,
    ) async {
      await tester.pumpWidget(host(spends(), (_, _) {}));
      expect(find.text('All time'), findsNothing);
      await tester.pumpWidget(
        host([
          ...spends(),
          item('z', 'AX-BAR-S', 'Rs 9 credited', at: DateTime(2026, 9, 3, 12)),
        ], (_, _) {}),
      );
      expect(find.text('All time'), findsOneWidget);
      expect(find.textContaining('Sep 2026 ('), findsOneWidget);
    });

    testWidgets('a chip that empties falls back to All', (tester) async {
      final all = [
        ...spends(),
        item('c', 'AX-BAZ-S', 'Credit Alert! Rs.1 credited'),
      ];
      await tester.pumpWidget(host(all, (_, _) {}));
      await tester.tap(find.text('Money in (1)'));
      await tester.pump();
      // The credit is dealt with elsewhere and leaves the list.
      await tester.pumpWidget(host(spends(), (_, _) {}));
      await tester.pump();
      expect(find.textContaining('Spent Rs.'), findsWidgets);
      expect(find.text('Nothing matches these filters.'), findsNothing);
    });

    testWidgets('bulk dismiss is offered only under Declined & alerts', (
      tester,
    ) async {
      final calls = <String>[];
      await tester.pumpWidget(
        host([
          item('a', 'AX-FOO-S', 'Txn of Rs.500 was declined'),
          item('b', 'AX-BAR-S', 'Your OTP is 123456. Do not share it.'),
          item('c', 'AX-BAZ-S', 'Spent Rs.100 at Shop'),
        ], (group, action) => calls.add('$action:${group.length}')),
      );
      // On All it is never offered: that list can hold real spends.
      expect(find.textContaining('Not financial — all'), findsNothing);
      await tester.tap(find.text('Declined & alerts (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not financial — all 2 shown'));
      await tester.pumpAndSettle();
      expect(find.text('Mark 2 messages as not financial?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('Not financial — all 2 shown'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark all'));
      await tester.pumpAndSettle();
      expect(calls, ['ignore:2']);
    });

    testWidgets('notices that moved no money lead with dismissing', (
      tester,
    ) async {
      final calls = <String>[];
      await tester.pumpWidget(
        host([
          item('b', 'AX-BAR-S', 'Your OTP is 123456. Do not share it.'),
        ], (group, action) => calls.add(action)),
      );
      expect(find.text('Dismiss notice'), findsOneWidget);
      expect(find.text('Fix'), findsOneWidget);
      await tester.tap(find.text('Dismiss notice'));
      expect(calls, ['ignore']);
    });

    testWidgets('biggest unknown format comes first', (tester) async {
      await tester.pumpWidget(
        host([
          item(
            'one',
            'AX-ONE-S',
            'Lone message Rs.1 debited',
            at: DateTime.utc(2026, 10, 9),
          ),
          for (var i = 0; i < 3; i++)
            item(
              'big$i',
              'AX-BIG-S',
              'Big format Rs.${10 + i} debited',
              at: DateTime.utc(2026, 10, 1 + i),
            ),
        ], (_, _) {}),
      );
      final big = tester.getTopLeft(find.textContaining('Big format').first);
      final lone = tester.getTopLeft(find.textContaining('Lone message'));
      expect(big.dy, lessThan(lone.dy));
    });
  });
}
