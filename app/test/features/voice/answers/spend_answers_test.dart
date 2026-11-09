import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../../lib/data/catalogue_repository.dart' show SpendCategory;
import '../../../../lib/data/spend_reports_repository.dart';
import '../../../../lib/data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind, TxnInstrument, UserCard;
import '../../../../lib/features/voice/answers/question_model.dart';
import '../../../../lib/features/voice/answers/spend_answers.dart';
import '../../../../lib/features/voice/answers/spend_data.dart';
import '../../../../lib/features/voice/answers/voice_answer.dart';

// Wednesday 11 November 2026.
final now = DateTime(2026, 11, 11, 15, 30);

const categories = [
  SpendCategory(id: 'dining-id', slug: 'dining', name: 'Dining'),
  SpendCategory(id: 'groceries-id', slug: 'groceries', name: 'Groceries'),
  SpendCategory(id: 'fuel-id', slug: 'fuel', name: 'Fuel'),
];

final cards = [
  UserCard(
    id: 'amex',
    cardProductId: 'p1',
    cardName: 'American Express Platinum Travel Card',
    nickname: 'Amex',
    isDefault: false,
  ),
];

EntryKindTotals totals(double rupees, int count, {double rewards = 0}) =>
    EntryKindTotals(
      total: Money.fromRupees(rupees),
      txnCount: count,
      rewards: Money.fromRupees(rewards),
    );

SpendReport report({
  double spend = 0,
  int count = 0,
  double income = 0,
  int incomeCount = 0,
  List<SpendBreakdownRow> byCategory = const [],
  List<SpendBreakdownRow> byMerchant = const [],
  List<CardSpendRow> byCard = const [],
  List<InstrumentSpendRow> byInstrument = const [],
}) => SpendReport(
  period: SpendPeriod.custom,
  periodStart: now,
  periodEnd: now,
  elapsedFraction: 1,
  spend: totals(spend, count),
  income: totals(income, incomeCount),
  investment: EntryKindTotals.zero,
  previousSpend: EntryKindTotals.zero,
  byCategory: byCategory,
  byMerchant: byMerchant,
  byCard: byCard,
  byInstrument: byInstrument,
  series: const [],
);

SpendBreakdownRow row(String label, double rupees, int count, {String? id}) =>
    SpendBreakdownRow(
      label: label,
      total: Money.fromRupees(rupees),
      txnCount: count,
      categoryId: id,
    );

String key(DateTime from, DateTime to) =>
    '${from.year}-${from.month}-${from.day}..${to.year}-${to.month}-${to.day}';

class FakeSource implements SpendDataSource {
  FakeSource({
    this.ready = true,
    this.earliest,
    this.reports = const {},
    this.transactions = const [],
  });

  @override
  final bool ready;
  @override
  final DateTime? earliest;
  final Map<String, SpendReport> reports;
  @override
  final List<TransactionEntry> transactions;
  final asked = <String>[];

  @override
  DateTime get now => DateTime(2026, 11, 11, 15, 30);

  @override
  SpendReport report(DateTime from, DateTime to) {
    asked.add(key(from, to));
    return reports[key(from, to)] ?? _empty;
  }

  static final _empty = SpendReport(
    period: SpendPeriod.custom,
    periodStart: DateTime(2026),
    periodEnd: DateTime(2026),
    elapsedFraction: 1,
    spend: EntryKindTotals.zero,
    income: EntryKindTotals.zero,
    investment: EntryKindTotals.zero,
    previousSpend: EntryKindTotals.zero,
    byCategory: const [],
    byMerchant: const [],
    byCard: const [],
    byInstrument: const [],
    series: const [],
  );
}

VoiceQuestion ask(String text) => const QuestionReader().read(
  text,
  now: now,
  cards: cards,
  categories: categories,
);

VoiceAnswer answer(String text, FakeSource source) =>
    const SpendAnswerer().answer(ask(text), source);

final nov = key(DateTime(2026, 11, 1), DateTime(2026, 11, 30));
final oct = key(DateTime(2026, 10, 1), DateTime(2026, 10, 31));
final sep = key(DateTime(2026, 9, 1), DateTime(2026, 9, 30));

TransactionEntry txn(
  String id,
  double rupees,
  DateTime at, {
  String? merchant,
  String? categoryId,
  String? cardId,
  TxnInstrument instrument = TxnInstrument.creditCard,
  TxnEntryKind kind = TxnEntryKind.spend,
  String status = 'active',
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(rupees),
  occurredAt: at,
  merchantName: merchant,
  categoryId: categoryId,
  userCardId: cardId,
  instrument: instrument,
  entryKind: kind,
  source: 'sms',
  status: status,
);

void main() {
  final since = DateTime(2026, 8, 12);

  group('totals', () {
    test('this month, with the month before for comparison', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(spend: 12400, count: 37),
          oct: report(spend: 10500, count: 30),
        },
      );
      final a = answer('how much did I spend this month', s);
      expect(a.status, AnswerStatus.ok);
      expect(a.headline, '₹12,400');
      expect(a.title, 'Spending · this month');
      expect(a.comparison, '₹1,900 more than last month (18%)');
      expect(
        a.evidence,
        '37 transactions, 1 Nov to 30 Nov. Same figures as the Spending screen.',
      );
      expect(a.coverageNote, isNull);
      expect(
        a.spoken,
        'You spent ₹12,400 this month, ₹1,900 more than last month (18%).',
      );
    });

    test('a named month', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          oct: report(spend: 10500, count: 30),
          sep: report(spend: 11000, count: 33),
        },
      );
      final a = answer('how much did I spend in october', s);
      expect(a.title, 'Spending · last month');
      expect(a.comparison, '₹500 less than the month before (5%)');
    });

    test('no spending is said plainly, with a zero', () {
      final s = FakeSource(earliest: since, reports: {nov: report()});
      final a = answer('how much did I spend on dining this month', s);
      expect(a.headline, '₹0');
      expect(a.spoken, 'I found no dining spending this month.');
    });

    test('Indian grouping in big numbers', () {
      final s = FakeSource(
        earliest: since,
        reports: {nov: report(spend: 250000, count: 4)},
      );
      expect(answer('how much did I spend this month', s).headline, '₹2,50,000');
    });
  });

  group('one filter reads the very row the Spending screen shows', () {
    test('a category', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(
            spend: 12400,
            count: 37,
            byCategory: [
              row('Dining', 4200, 9, id: 'dining-id'),
              row('Groceries', 3000, 7, id: 'groceries-id'),
            ],
          ),
          oct: report(
            spend: 10500,
            byCategory: [row('Dining', 3900, 8, id: 'dining-id')],
          ),
        },
      );
      final a = answer('how much did I spend on dining this month', s);
      expect(a.headline, '₹4,200');
      expect(a.title, 'Dining · this month');
      expect(a.comparison, '₹300 more than last month (8%)');
      final show = a.actions.firstWhere(
        (x) => x.kind == AnswerActionKind.showTransactions,
      );
      expect(show.categoryId, 'dining-id');
      expect(show.categoryLabel, 'Dining');
      expect(show.from, DateTime(2026, 11, 1));
      expect(show.to, DateTime(2026, 11, 30));
    });

    test('a merchant, by words, across rows', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(
            byMerchant: [
              row('swiggy', 1800, 4),
              row('swiggy instamart', 500, 2),
              row('zomato', 900, 3),
            ],
          ),
        },
      );
      final a = answer('what did I spend on swiggy this month', s);
      expect(a.headline, '₹2,300');
      expect(a.evidence, startsWith('6 transactions'));
      final show = a.actions.firstWhere(
        (x) => x.kind == AnswerActionKind.showTransactions,
      );
      expect(show.query, 'Swiggy');
    });

    test('a card, with its own row and a wallet button', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(
            byCard: [
              CardSpendRow(
                cardId: 'amex',
                cardName: 'Amex',
                total: Money.fromRupees(18000),
                rewards: Money.fromRupees(540),
                txnCount: 8,
              ),
              CardSpendRow(
                cardId: null,
                cardName: 'Cash',
                total: Money.fromRupees(700),
                rewards: const Money.zero(),
                txnCount: 2,
              ),
            ],
          ),
        },
      );
      final a = answer('how much did I spend on my amex this month', s);
      expect(a.headline, '₹18,000');
      expect(a.spoken, startsWith('You spent ₹18,000 on your Amex this month'));
      expect(a.actions.any((x) => x.kind == AnswerActionKind.wallet), isTrue);
    });

    test('a payment method', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(
            byInstrument: [
              InstrumentSpendRow(
                instrument: 'upi_bank',
                total: Money.fromRupees(5000),
                txnCount: 12,
              ),
              InstrumentSpendRow(
                instrument: 'cash',
                total: Money.fromRupees(800),
                txnCount: 3,
              ),
            ],
          ),
        },
      );
      expect(answer('how much did I spend by upi this month', s).headline, '₹5,000');
    });
  });

  group('several filters add up the matching transactions, and say so', () {
    test('dining on the amex', () {
      final s = FakeSource(
        earliest: since,
        transactions: [
          txn('1', 500, DateTime(2026, 11, 3), categoryId: 'dining-id', cardId: 'amex'),
          txn('2', 700, DateTime(2026, 11, 8), categoryId: 'dining-id', cardId: 'amex'),
          txn('3', 900, DateTime(2026, 11, 8), categoryId: 'dining-id', cardId: 'other'),
          txn('4', 300, DateTime(2026, 11, 9), categoryId: 'fuel-id', cardId: 'amex'),
          txn('5', 100, DateTime(2026, 10, 9), categoryId: 'dining-id', cardId: 'amex'),
          txn('6', 600, DateTime(2026, 11, 9), categoryId: 'dining-id', cardId: 'amex', status: 'deleted'),
          txn('7', 800, DateTime(2026, 11, 9), categoryId: 'dining-id', cardId: 'amex', kind: TxnEntryKind.income),
        ],
      );
      final a = answer('how much on dining with my amex this month', s);
      expect(a.headline, '₹1,200');
      expect(a.title, 'Dining · Amex · this month');
      expect(a.evidence, 'Calculated from 2 transactions on this phone, 1 Nov to 30 Nov.');
      expect(a.comparison, '₹1,100 more than last month (1100%)');
    });
  });

  group('honesty about the data', () {
    test('history that starts later is called out', () {
      final s = FakeSource(
        earliest: DateTime(2026, 11, 5),
        reports: {nov: report(spend: 2000, count: 5)},
      );
      final a = answer('how much did I spend this month', s);
      expect(a.coverageNote, contains('History on this phone starts'));
      expect(a.coverageNote, contains('5 Nov'));
      // No comparison is offered for a month the phone does not cover.
      expect(a.comparison, isNull);
    });

    test('a period before any history is not answered with zero', () {
      final s = FakeSource(earliest: since);
      final a = answer('how much did I spend last year', s);
      expect(a.status, AnswerStatus.noData);
      expect(a.evidence, contains('start on'));
    });

    test('no transactions at all', () {
      final a = answer('how much did I spend this month', FakeSource());
      expect(a.status, AnswerStatus.noData);
    });

    test('a ledger that is not ready says so', () {
      final a = answer(
        'how much did I spend this month',
        FakeSource(ready: false, earliest: since),
      );
      expect(a.status, AnswerStatus.notReady);
    });
  });

  group('top spends, money in and comparisons', () {
    test('where the most went', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(
            spend: 19300,
            count: 40,
            byCategory: [
              row('Groceries', 9100, 12, id: 'groceries-id'),
              row('Dining', 12400, 20, id: 'dining-id'),
              row('Fuel', 6000, 3, id: 'fuel-id'),
              row('Other', 100, 1),
            ],
            byMerchant: [row('bigbasket', 5000, 6), row('swiggy', 7000, 9)],
          ),
        },
      );
      final a = answer('where did I spend the most this month', s);
      expect(a.headline, 'Dining · ₹12,400');
      expect(a.rows.take(3).map((r) => r.label), ['Dining', 'Groceries', 'Fuel']);
      expect(a.rows.last.label, 'At bigbasket');
      expect(
        a.spoken,
        'Your biggest category this month was Dining at ₹12,400, then Groceries at ₹9,100 and Fuel at ₹6,000.',
      );
    });

    test('money in', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(income: 82000, incomeCount: 3),
          oct: report(income: 80000, incomeCount: 2),
        },
      );
      final a = answer('how much came in this month', s);
      expect(a.title, 'Money in · this month');
      expect(a.headline, '₹82,000');
      expect(a.comparison, '₹2,000 more than last month (3%)');
      final show = a.actions.firstWhere(
        (x) => x.kind == AnswerActionKind.showTransactions,
      );
      expect(show.spendOnly, isFalse);
    });

    test('this month against last month', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(spend: 12400, count: 37),
          oct: report(spend: 10500, count: 30),
        },
      );
      final a = answer('this month versus last month', s);
      expect(a.headline, '₹12,400 vs ₹10,500');
      expect(a.rows.map((r) => r.label), ['this month', 'last month']);
      expect(
        a.spoken,
        'You spent ₹12,400 this month, against ₹10,500 last month, which is ₹1,900 more.',
      );
    });

    test('a comparison for one category', () {
      final s = FakeSource(
        earliest: since,
        reports: {
          nov: report(byCategory: [row('Dining', 4200, 9, id: 'dining-id')]),
          oct: report(byCategory: [row('Dining', 3900, 8, id: 'dining-id')]),
        },
      );
      final a = answer('compare my dining spend to last month', s);
      expect(a.title, 'Dining · this month vs last month');
      expect(a.headline, '₹4,200 vs ₹3,900');
    });
  });
}
