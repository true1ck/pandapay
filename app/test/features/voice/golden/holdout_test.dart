import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnInstrument, UserCard;
import 'package:pandapay/features/voice/answers/question_model.dart';
import 'package:pandapay/features/voice/voice_action_parser.dart';

/// Natural phrases, written the way people actually talk and type, after the
/// rules were built and not shaped to them. A failure here is fixed only by a
/// general change to the engine, never by a rule for one phrase. The 66
/// phrases the old parser was first measured on are included.
// Wednesday 11 November 2026.
final now = DateTime(2026, 11, 11, 15, 30);

const slugs = [
  'travel',
  'dining',
  'groceries',
  'fuel',
  'online',
  'bills',
  'entertainment',
  'health',
  'rent',
];
final categories = [
  for (final s in slugs)
    SpendCategory(
      id: '$s-id',
      slug: s,
      name: '${s[0].toUpperCase()}${s.substring(1)}',
    ),
];
final cards = [
  UserCard(
    id: 'amex',
    cardProductId: 'p1',
    cardName: 'American Express Platinum Travel Card',
    nickname: 'Amex',
    last4: '1007',
    isDefault: false,
  ),
  UserCard(
    id: 'hs',
    cardProductId: 'p2',
    cardName: 'HDFC Swiggy Credit Card',
    last4: '4521',
    isDefault: false,
  ),
  UserCard(
    id: 'hr',
    cardProductId: 'p3',
    cardName: 'HDFC Regalia Gold Credit Card',
    last4: '9090',
    isDefault: false,
  ),
  UserCard(
    id: 'axis',
    cardProductId: 'p4',
    cardName: 'Axis Atlas Credit Card',
    last4: '3344',
    isDefault: false,
  ),
];

/// One entry or several: amounts, and optionally what else must be found.
class H {
  const H(
    this.text,
    this.amounts, {
    this.type = VoiceActionType.expense,
    this.cat,
    this.merchant,
    this.day,
    this.notice,
    this.foreign,
    this.instrument,
  });
  final String text;
  final List<double?> amounts;
  final VoiceActionType type;
  final String? cat;
  final String? merchant;

  /// Days from today (-1 yesterday); null means no date said.
  final int? day;
  final VoiceNotice? notice;
  final String? foreign;
  final TxnInstrument? instrument;
}

const spends = <H>[
  H('just paid 450 for an auto', [450], cat: 'travel'),
  H('bought vegetables from the market for 320', [320], cat: 'groceries'),
  H('i had dinner at barbeque nation it was 2,400', [2400], cat: 'dining'),
  H('ordered pizza from dominos 680 rupees', [680], cat: 'dining'),
  H(
    'uber ride to the airport cost me 1250',
    [1250],
    merchant: 'Uber',
    cat: 'travel',
  ),
  H('filled up petrol 2000', [2000], cat: 'fuel'),
  H('electricity bill 1,860', [1860], cat: 'bills'),
  H('paid rent 25,000', [25000], cat: 'rent'),
  H('movie tickets 700 on bookmyshow', [700], cat: 'entertainment'),
  H('gave 500 to the maid', [500]),
  H('coffee at starbucks 340', [340], cat: 'dining'),
  H('the phone recharge was 299', [299], cat: 'bills'),
  H('medicines from apollo pharmacy 540 rupees', [540], cat: 'health'),
  H('got groceries for about 1800', [1800], cat: 'groceries'),
  H(
    'lunch with colleagues cost 1,350 yesterday',
    [1350],
    cat: 'dining',
    day: -1,
  ),
  H('parking 60 rupees', [60]),
  H('toll 85', [85], cat: 'travel'),
  H('spent around 3k on shopping at myntra', [3000], merchant: 'Myntra'),
  H('dinner 1200 last night', [1200], cat: 'dining', day: -1),
  H('two coffees for 380', [380]),
  H('bought 3 shirts for 2,400', [2400]),
  H('paid 1,500 for 2 tickets', [1500]),
  H('ola cab 230 this morning', [230], cat: 'travel'),
  H('five hundred for the haircut', [500]),
  H('hotel booking 8,500 for 2 nights', [8500], cat: 'travel'),
  H('paid the plumber 800', [800]),
  H('netflix 649', [649], merchant: 'Netflix'),
  H('spent 1.2k on books', [1200]),
  H('bought a gift for 2500', [2500]),
  H(
    'zomato order 450 yesterday',
    [450],
    merchant: 'Zomato',
    cat: 'dining',
    day: -1,
  ),
  H('paid ₹120 for tea and snacks', [120], cat: 'dining'),
  H('grocery run, 2,150 at dmart', [2150], cat: 'groceries'),
  H('auto fare 90', [90], cat: 'travel'),
  H('gym membership 3000 rupees', [3000]),
  H('paid 750 for a haircut and 300 for a beard trim', [750, 300]),
  H('lunch 250 and coffee 120', [250, 120]),
  H('yesterday spent 400 on snacks and 1,000 on petrol', [400, 1000], day: -1),
  H('bought milk 60 bread 45 eggs 80', [60, 45, 80]),
  H('spent two thousand five hundred on a dress', [2500]),
  H('paid eighteen hundred for the electrician', [1800]),
  H('cab to office 180 and cab back 210', [180, 210]),
  H('five hundred rupees for diesel', [500], cat: 'fuel'),
  H('bought a book for 350', [350]),
  H('chai 15', [15], cat: 'dining'),
  H('i spent 4,500 on flights', [4500], cat: 'travel'),
  H('booked train tickets 1,240', [1240], cat: 'travel'),
  H('paid water bill 420', [420], cat: 'bills'),
  H('swiggy dinner 560 on my hdfc card', [560], merchant: 'Swiggy'),
  H('wifi bill 999 last friday', [999], cat: 'bills', day: -5),
  H('on the 3rd i paid 900 for school fees', [900], day: -8),
  H('spent 250 on groceries', [250], cat: 'groceries'),
  H('spent ₹1,250 at reliance fresh', [1250]),
  H('paid 2,50,000 rupees for rent', [250000], cat: 'rent'),
  H('spent 1.5k on groceries', [1500], cat: 'groceries'),
  H('spent 2k on fuel', [2000], cat: 'fuel'),
  H('spent two fifty on lunch', [250], cat: 'dining'),
  H('spent fifteen hundred on petrol', [1500], cat: 'fuel'),
  H('spent two lakh on a laptop', [200000]),
  H('spent 2.5 lakh on a car down payment', [250000]),
  H('250 for lunch', [250], cat: 'dining'),
  H('lunch was 250', [250], cat: 'dining'),
  H('spent on 2 coffees 300', [300]),
  H('250 for lunch, 300 for fuel and 150 for chai', [250, 300, 150]),
  H('spent 600 on lunch and 400 on a taxi', [600, 400]),
  H('paid 250 bucks for parking', [250]),
  H('paid Rs. 250 for parking', [250]),
  H('spent 99.50 on coffee', [99.5], cat: 'dining'),
  H('spent 500 cash on tea', [500], instrument: TxnInstrument.cash),
  H('paid 100 by upi for parking', [100], instrument: TxnInstrument.upiBank),
];

const incoming = <H>[
  H('got my salary 85,000 today', [85000], type: VoiceActionType.moneyIn),
  H('rahul sent me 1,500 for dinner', [1500], type: VoiceActionType.moneyIn),
  H('received 12000 from client', [12000], type: VoiceActionType.moneyIn),
  H('refund of 499 came from myntra', [499], type: VoiceActionType.refund),
  H('amazon refunded me 1,299', [1299], type: VoiceActionType.refund),
  H('cashback of 120 credited', [120], type: VoiceActionType.moneyIn),
  H('dividend 340 credited', [340], type: VoiceActionType.moneyIn),
  H('my friend paid me back 600', [600], type: VoiceActionType.moneyIn),
  H('interest credited 1,250', [1250], type: VoiceActionType.moneyIn),
  H('received 5000 from Rahul', [5000], type: VoiceActionType.moneyIn),
  H('got a refund of 500 from Amazon', [500], type: VoiceActionType.refund),
  H('salary credited 50000', [50000], type: VoiceActionType.moneyIn),
];

const foreignPhrases = <H>[
  H('spent 20 dollars on uber in new york', [null], foreign: 'USD'),
  H('paid 45 euros for dinner in rome', [null], foreign: 'EUR'),
  H('tokyo ramen was 1500 yen', [null], foreign: 'JPY'),
  H('bought a souvenir for 12 pounds', [null], foreign: 'GBP'),
  H('hotel was 300 dirhams', [null], foreign: 'AED'),
  H('spent 50 dollars in Dubai', [null], foreign: 'USD'),
  H('paid 30 euros for a museum ticket', [null], foreign: 'EUR'),
];

const refused = <H>[
  H('transferred 10000 to my wife', [], notice: VoiceNotice.transfer),
  H(
    'paid hdfc credit card bill 23,400',
    [],
    notice: VoiceNotice.cardBillPayment,
  ),
  H('sent 5000 to my brother', [], notice: VoiceNotice.transfer),
  H('add a new debit card', [], notice: VoiceNotice.addCard),
  H('link my kotak card', [], notice: VoiceNotice.addCard),
  H('moved 20000 to savings', [], notice: VoiceNotice.transfer),
  H(
    'paid my amex statement of 15,000',
    [],
    notice: VoiceNotice.cardBillPayment,
  ),
  H(
    'paid my credit card bill of 12000',
    [],
    notice: VoiceNotice.cardBillPayment,
  ),
  H('transferred 5000 to my savings account', [], notice: VoiceNotice.transfer),
  H('add a new credit card', [], notice: VoiceNotice.addCard),
  H('Add my new debit card to the wallet', [], notice: VoiceNotice.addCard),
];

class Q {
  const Q(
    this.text,
    this.kind, {
    this.cat,
    this.merchant,
    this.card,
    this.instrument,
    this.from,
    this.to,
  });
  final String text;
  final QuestionKind kind;
  final String? cat;
  final String? merchant;
  final String? card;
  final TxnInstrument? instrument;
  final DateTime? from;
  final DateTime? to;
}

final questions = <Q>[
  Q(
    'how much have i spent on food this month',
    QuestionKind.spend,
    cat: 'dining',
    from: DateTime(2026, 11, 1),
    to: DateTime(2026, 11, 30),
  ),
  Q(
    "what's my total spend this week",
    QuestionKind.spend,
    from: DateTime(2026, 11, 9),
    to: DateTime(2026, 11, 15),
  ),
  const Q('did i overspend last month', QuestionKind.unknown),
  Q(
    'which card gives me the most rewards on fuel',
    QuestionKind.bestCard,
    cat: 'fuel',
  ),
  Q(
    'how many reward points are left on my amex',
    QuestionKind.pointsBalance,
    card: 'amex',
  ),
  const Q('when do i need to pay my icici bill', QuestionKind.billsDue),
  const Q("what's due this month", QuestionKind.billsDue),
  Q(
    'how much did i earn this month',
    QuestionKind.moneyIn,
    from: DateTime(2026, 11, 1),
    to: DateTime(2026, 11, 30),
  ),
  Q(
    'show my spending on uber this year',
    QuestionKind.spend,
    merchant: 'Uber',
    from: DateTime(2026, 1, 1),
    to: DateTime(2026, 12, 31),
  ),
  Q(
    'biggest expense last month',
    QuestionKind.topSpends,
    from: DateTime(2026, 10, 1),
    to: DateTime(2026, 10, 31),
  ),
  const Q('compare this month with last month', QuestionKind.compare),
  Q('how much cap do i have left on my hdfc card', QuestionKind.capsLeft),
  const Q('what is the weather', QuestionKind.unknown),
  const Q('tell me a joke', QuestionKind.unknown),
  Q('how much did i spend at croma', QuestionKind.spend, merchant: 'Croma'),
  Q(
    'how much did i spend on groceries in october',
    QuestionKind.spend,
    cat: 'groceries',
    from: DateTime(2026, 10, 1),
    to: DateTime(2026, 10, 31),
  ),
  Q(
    'which card should i use at swiggy',
    QuestionKind.bestCard,
    merchant: 'Swiggy',
  ),
  const Q('how many points do i have', QuestionKind.pointsBalance),
  Q(
    'what did i spend on my axis card last week',
    QuestionKind.spend,
    card: 'axis',
    from: DateTime(2026, 11, 2),
    to: DateTime(2026, 11, 8),
  ),
  Q(
    'total spend by cash this month',
    QuestionKind.spend,
    instrument: TxnInstrument.cash,
  ),
  Q(
    'how much money came in last month',
    QuestionKind.moneyIn,
    from: DateTime(2026, 10, 1),
    to: DateTime(2026, 10, 31),
  ),
  const Q('am i close to my fuel cap', QuestionKind.capsLeft),
  const Q('when is my amex bill due', QuestionKind.billsDue),
  const Q('what is my balance', QuestionKind.unknown),
  Q(
    'where did i spend the most this month',
    QuestionKind.topSpends,
    from: DateTime(2026, 11, 1),
    to: DateTime(2026, 11, 30),
  ),
  Q(
    'how much did i spend on dining last month',
    QuestionKind.spend,
    cat: 'dining',
    from: DateTime(2026, 10, 1),
    to: DateTime(2026, 10, 31),
  ),
  Q('how much on netflix this year', QuestionKind.spend, merchant: 'Netflix'),
  Q(
    'how much came in this week',
    QuestionKind.moneyIn,
    from: DateTime(2026, 11, 9),
    to: DateTime(2026, 11, 15),
  ),
  const Q('do i have any bills due', QuestionKind.billsDue),
  const Q(
    'what is my points balance on axis atlas',
    QuestionKind.pointsBalance,
  ),
];

String? checkEntry(H h) {
  final drafts = VoiceActionParser.parseMany(
    h.text,
    cards: cards,
    categories: categories,
    now: now,
  );
  if (h.notice != null) {
    final d = drafts.first;
    if (d.notice != h.notice) return 'notice ${d.notice}, wanted ${h.notice}';
    if (drafts.any((x) => x.canSave)) return 'would be saved';
    return null;
  }
  if (drafts.length != h.amounts.length) {
    return 'wanted ${h.amounts.length} entries, got ${drafts.length}: ${drafts.map((d) => '${d.type.name}:${d.amount}').toList()}';
  }
  for (var i = 0; i < drafts.length; i++) {
    final d = drafts[i];
    if (d.type != h.type)
      return 'entry $i is ${d.type.name}, wanted ${h.type.name}';
    if (h.foreign != null) {
      if (d.foreignCurrency != h.foreign)
        return 'currency ${d.foreignCurrency}, wanted ${h.foreign}';
      if (d.amount != null) return 'foreign amount saved as rupees ${d.amount}';
      continue;
    }
    final want = h.amounts[i];
    if (want != null &&
        (d.amount == null || (d.amount! - want).abs() > 0.001)) {
      return 'entry $i amount ${d.amount}, wanted $want';
    }
    if (i == 0) {
      if (h.cat != null && d.categoryId != '${h.cat}-id')
        return 'category ${d.categoryId}, wanted ${h.cat}';
      if (h.merchant != null && d.merchant != h.merchant)
        return 'merchant ${d.merchant}, wanted ${h.merchant}';
      if (h.instrument != null && d.instrument != h.instrument)
        return 'instrument ${d.instrument}';
    }
    if (h.day != null) {
      final w = DateTime(2026, 11, 11 + h.day!, 12);
      if (d.occurredAt != w) return 'entry $i date ${d.occurredAt}, wanted $w';
    }
  }
  return null;
}

String? checkQuestion(Q q) {
  final r = const QuestionReader().read(
    q.text,
    now: now,
    cards: cards,
    categories: categories,
    knownMerchants: const ['Croma'],
  );
  if (r.kind != q.kind) return 'kind ${r.kind.name}, wanted ${q.kind.name}';
  if (q.cat != null && r.category?.slug != q.cat)
    return 'category ${r.category?.slug}, wanted ${q.cat}';
  if (q.merchant != null && r.merchant != q.merchant)
    return 'merchant ${r.merchant}, wanted ${q.merchant}';
  if (q.card != null && (r.cards.isEmpty || r.cards.first.id != q.card))
    return 'card ${r.cards.map((c) => c.id)}, wanted ${q.card}';
  if (q.instrument != null && r.instrument != q.instrument)
    return 'instrument ${r.instrument}';
  if (q.from != null && (r.period?.from != q.from || r.period?.to != q.to)) {
    return 'period ${r.period?.from}..${r.period?.to}, wanted ${q.from}..${q.to}';
  }
  return null;
}

void main() {
  void group(String name, List<H> list, {required double minPass}) {
    test('$name: ${list.length} natural phrases', () {
      final failures = <String>[];
      for (final h in list) {
        final p = checkEntry(h);
        if (p != null) failures.add('"${h.text}" -> $p');
      }
      final pass = list.length - failures.length;
      // ignore: avoid_print
      print(
        'HOLDOUT $name: $pass/${list.length}${failures.isEmpty ? '' : '\n  ${failures.join('\n  ')}'}',
      );
      expect(
        pass / list.length,
        greaterThanOrEqualTo(minPass),
        reason: failures.join('\n'),
      );
    });
  }

  group('spends', spends, minPass: 0.95);
  group('money in and refunds', incoming, minPass: 0.95);
  group('foreign amounts', foreignPhrases, minPass: 1.0);
  group('recognized, not logged', refused, minPass: 1.0);

  test('questions: ${questions.length} natural phrases', () {
    final failures = <String>[];
    for (final q in questions) {
      final p = checkQuestion(q);
      if (p != null) failures.add('"${q.text}" -> $p');
    }
    final pass = questions.length - failures.length;
    // ignore: avoid_print
    print(
      'HOLDOUT questions: $pass/${questions.length}${failures.isEmpty ? '' : '\n  ${failures.join('\n  ')}'}',
    );
    expect(
      pass / questions.length,
      greaterThanOrEqualTo(0.95),
      reason: failures.join('\n'),
    );
  });
}
