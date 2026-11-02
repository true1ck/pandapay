import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/foreign_payment.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/features/activity/foreign_payments_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

ForeignPayment _payment({
  String id = 'fx-one',
  String currency = 'USD',
  String? amount = '20.00',
  String status = 'estimated',
  Money? estimate = const Money.fromPaise(170000),
  String? transactionId,
  String merchant = 'Cursor',
  DateTime? occurredAt,
}) => ForeignPayment(
  id: id,
  sourceKey: id.padRight(64, 'a'),
  occurredAt: occurredAt ?? DateTime(2026, 3, 5),
  originalCurrency: currency,
  originalAmount: amount,
  valuationStatus: status,
  merchantName: merchant,
  estimatedInr: estimate,
  billedInr: status == 'confirmed' ? const Money.fromPaise(174200) : null,
  transactionId: transactionId,
  rate: estimate == null ? null : '85.00',
  rateDate: DateTime(2026, 3, 4),
  rateSource: 'Reference provider',
);

class _FakeForeignRepository implements ForeignPaymentsRepository {
  List<ForeignPayment> items;
  Money? confirmedAmount;
  String? editedCurrency;
  String? editedAmount;
  int confirms = 0;
  int refreshes = 0;
  _FakeForeignRepository(this.items);

  ForeignPayment _save(String id, Map<String, dynamic> patch) {
    final index = items.indexWhere((payment) => payment.id == id);
    final next = items[index].withPatch(patch);
    items = [...items]..[index] = next;
    return next;
  }

  @override
  Future<ForeignPayment> editOriginal(
    String id, {
    String? currency,
    String? amount,
    String? merchantName,
    String? categoryId,
    String? userCategoryId,
    String? userCardId,
  }) async {
    editedCurrency = currency;
    editedAmount = amount;
    return _save(id, {
      if (currency != null) 'original_currency': currency,
      if (amount != null) 'original_amount': amount,
      if (merchantName != null) 'merchant_name': merchantName,
      if (categoryId != null) 'category_id': categoryId,
      'valuation_status': 'awaiting_rate',
      'estimated_inr': null,
    });
  }

  @override
  Future<ForeignPayment> confirmBilled(
    String id, {
    required Money billedInr,
    String? transactionId,
    String? userCardId,
  }) async {
    confirms++;
    confirmedAmount = billedInr;
    return _save(id, {
      'billed_inr': moneyDecimal(billedInr),
      'valuation_status': 'confirmed',
      'transaction_id': transactionId ?? 'posted-one',
      'confirmation_source': 'user',
    });
  }

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Future<ForeignPayment> ignore(String id) async =>
      _save(id, {'valuation_status': 'ignored'});

  @override
  Future<ForeignPayment> restore(String id) async =>
      _save(id, {'valuation_status': 'awaiting_rate'});

  @override
  Future<ForeignPayment> retry(String id) async =>
      items.firstWhere((payment) => payment.id == id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<ForeignPayment> payments = const [],
  _FakeForeignRepository? repository,
}) async {
  final repo = repository ?? _FakeForeignRepository(payments);
  await tester.binding.setSurfaceSize(const Size(430, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        foreignPaymentsProvider.overrideWith((ref) async => repo.items),
        foreignPaymentsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => []),
        categoriesProvider.overrideWith((ref) async => const <SpendCategory>[]),
      ],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'period and query filter foreign evidence without converting it into ledger rows',
    () {
      final march = _payment();
      final april = _payment(id: 'april', occurredAt: DateTime(2026, 4, 1));
      expect(
        foreignPaymentsForPeriod(
          [march, april],
          from: DateTime(2026, 3, 1),
          to: DateTime(2026, 3, 31),
          query: 'USD',
        ),
        [march],
      );
      expect(
        foreignPaymentsForPeriod([march], query: 'not this merchant'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'summary separates estimates, unknown amounts and confirmed payments',
    (tester) async {
      final payments = [
        _payment(),
        _payment(
          id: 'unknown',
          amount: null,
          status: 'awaiting_amount',
          estimate: null,
        ),
        _payment(id: 'confirmed', status: 'confirmed'),
        _payment(id: 'ignored', status: 'ignored'),
      ];
      await _pump(
        tester,
        Scaffold(body: ForeignPaymentSummaryCard(payments: payments)),
      );
      expect(find.textContaining('₹1,700 estimated'), findsOneWidget);
      expect(find.textContaining('2 payments'), findsOneWidget);
      expect(find.textContaining('1 amount unclear'), findsOneWidget);
      expect(
        find.textContaining('Shown separately from confirmed spending'),
        findsOneWidget,
      );
      expect(find.textContaining('₹3,400'), findsNothing);
    },
  );

  testWidgets('missing foreign price remains explicitly unknown', (
    tester,
  ) async {
    final payment = _payment(
      amount: null,
      estimate: null,
      status: 'awaiting_amount',
    );
    await _pump(
      tester,
      Scaffold(
        body: ForeignPaymentTile(payment: payment, onTap: () {}),
      ),
    );
    expect(find.text('USD · amount needed'), findsOneWidget);
    expect(find.textContaining('₹0'), findsNothing);
    expect(find.textContaining('2,86,388'), findsNothing);
  });

  testWidgets(
    'foreign view filters confirmed and ignored records without duplicate pending rows',
    (tester) async {
      await _pump(
        tester,
        const ForeignPaymentsScreen(),
        payments: [
          _payment(),
          _payment(
            id: 'confirmed',
            status: 'confirmed',
            merchant: 'Settled merchant',
            transactionId: 'posted-one',
          ),
          _payment(
            id: 'ignored',
            status: 'ignored',
            merchant: 'Ignored merchant',
          ),
        ],
      );
      expect(find.text('Cursor'), findsOneWidget);
      expect(find.text('Settled merchant'), findsNothing);
      await tester.tap(find.text('Confirmed'));
      await tester.pumpAndSettle();
      expect(find.text('Settled merchant'), findsOneWidget);
      expect(find.text('Cursor'), findsNothing);
      await tester.tap(find.text('Ignored'));
      await tester.pumpAndSettle();
      expect(find.text('Ignored merchant'), findsOneWidget);
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(find.text('Cursor'), findsOneWidget);
      expect(find.text('Settled merchant'), findsOneWidget);
      expect(find.text('Ignored merchant'), findsNothing);
      await tester.enterText(find.byType(TextField), 'settled');
      await tester.pumpAndSettle();
      expect(find.text('Settled merchant'), findsOneWidget);
      expect(find.text('Cursor'), findsNothing);
    },
  );

  testWidgets(
    'detail labels reference rate and fees while keeping estimate unconfirmed',
    (tester) async {
      final payment = _payment();
      await _pump(
        tester,
        ForeignPaymentDetailScreen(paymentId: payment.id),
        payments: [payment],
      );
      expect(find.text('USD 20.00'), findsOneWidget);
      expect(find.text('Estimated INR'), findsOneWidget);
      expect(find.text('4 Mar 2026'), findsOneWidget);
      expect(find.text('Reference provider'), findsOneWidget);
      expect(
        find.textContaining('bank’s rate and fees may differ'),
        findsOneWidget,
      );
      expect(find.text('View billed transaction'), findsNothing);
    },
  );

  testWidgets(
    'original edit saves a real missing price independently of billed INR',
    (tester) async {
      final payment = _payment(
        amount: null,
        estimate: null,
        status: 'awaiting_amount',
      );
      final repo = _FakeForeignRepository([payment]);
      await _pump(
        tester,
        ForeignPaymentDetailScreen(paymentId: payment.id),
        repository: repo,
      );
      await tester.tap(find.text('Edit original amount or currency'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('foreign-original-currency')),
        'eur',
      );
      await tester.enterText(
        find.byKey(const Key('foreign-original-amount')),
        '12.99',
      );
      await tester.tap(find.text('Save original amount'));
      await tester.pumpAndSettle();
      expect(repo.editedCurrency, 'EUR');
      expect(repo.editedAmount, '12.99');
      expect(repo.confirms, 0);
      expect(find.text('EUR 12.99'), findsOneWidget);
    },
  );

  testWidgets(
    'billed INR never prefills an estimate and requires valid actual amount',
    (tester) async {
      final payment = _payment();
      final repo = _FakeForeignRepository([payment]);
      await _pump(
        tester,
        ForeignPaymentDetailScreen(paymentId: payment.id),
        repository: repo,
      );
      await tester.tap(find.text('Confirm actual billed INR'));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('foreign-billed-inr'));
      expect(tester.widget<TextFormField>(field).controller!.text, isEmpty);
      await tester.enterText(field, '0');
      await tester.tap(find.text('Confirm billed amount'));
      await tester.pumpAndSettle();
      expect(repo.confirms, 0);
      expect(
        find.textContaining('Enter the actual INR amount'),
        findsOneWidget,
      );
      await tester.enterText(field, '1742.57');
      await tester.tap(find.text('Confirm billed amount'));
      await tester.pumpAndSettle();
      expect(repo.confirms, 1);
      expect(repo.confirmedAmount, const Money.fromPaise(174257));
      expect(find.text('View billed transaction'), findsOneWidget);
      expect(find.text('Confirm actual billed INR'), findsNothing);
    },
  );

  testWidgets('ignore remains recoverable through restore', (tester) async {
    final payment = _payment();
    final repo = _FakeForeignRepository([payment]);
    await _pump(
      tester,
      ForeignPaymentDetailScreen(paymentId: payment.id),
      repository: repo,
    );
    await tester.ensureVisible(find.text('Ignore this payment'));
    await tester.tap(find.text('Ignore this payment'));
    await tester.pumpAndSettle();
    expect(repo.items.single.isIgnored, isTrue);
    expect(find.text('Restore payment'), findsOneWidget);
    await tester.tap(find.text('Restore payment'));
    await tester.pumpAndSettle();
    expect(repo.items.single.isPending, isTrue);
  });

  testWidgets('confirmed ledger detail preserves original currency once', (
    tester,
  ) async {
    await _pump(
      tester,
      const Scaffold(body: ForeignTransactionInfo(transactionId: 'posted-one')),
      payments: [
        _payment(status: 'confirmed', transactionId: 'posted-one'),
        _payment(id: 'pending'),
      ],
    );
    expect(find.text('USD 20.00'), findsOneWidget);
    expect(find.textContaining('billed INR counted once'), findsOneWidget);
  });

  testWidgets(
    'pending confirmation can display saved INR without claiming a posted charge',
    (tester) async {
      final payment = _payment(
        estimate: null,
        status: 'awaiting_rate',
      ).withPatch({'billed_inr': '1742.57', 'locally_pending': true});
      await _pump(
        tester,
        Scaffold(
          body: ForeignPaymentTile(payment: payment, onTap: () {}),
        ),
      );
      expect(find.text('₹1,742.57 · sync pending'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
