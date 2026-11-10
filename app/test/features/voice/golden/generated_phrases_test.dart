import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/flashtext_merchant_extractor.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnInstrument, UserCard;
import 'package:pandapay/features/voice/answers/question_model.dart';
import 'package:pandapay/features/voice/voice_action_parser.dart';

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
  for (final s in slugs) SpendCategory(id: '$s-id', slug: s, name: _title(s)),
];
String _title(String s) => '${s[0].toUpperCase()}${s.substring(1)}';

// ---- number rendering ---------------------------------------------------------

const _ones = [
  'zero',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
  'nine',
  'ten',
  'eleven',
  'twelve',
  'thirteen',
  'fourteen',
  'fifteen',
  'sixteen',
  'seventeen',
  'eighteen',
  'nineteen',
];
const _tens = [
  '',
  '',
  'twenty',
  'thirty',
  'forty',
  'fifty',
  'sixty',
  'seventy',
  'eighty',
  'ninety',
];

String _below100(int n) => n < 20
    ? _ones[n]
    : '${_tens[n ~/ 10]}${n % 10 == 0 ? '' : ' ${_ones[n % 10]}'}';

String _words(int n, Random r) {
  final parts = <String>[];
  var rest = n;
  if (rest >= 100000) {
    parts.add('${_below100(rest ~/ 100000)} lakh');
    rest %= 100000;
  }
  if (rest >= 1000) {
    parts.add('${_below100(rest ~/ 1000)} thousand');
    rest %= 1000;
  }
  if (rest >= 100) {
    parts.add('${_ones[rest ~/ 100]} hundred');
    rest %= 100;
    if (rest > 0 && r.nextBool()) parts.add('and');
  }
  if (rest > 0) parts.add(_below100(rest));
  return parts.join(' ');
}

String _indian(int n) {
  final s = n.toString();
  if (s.length <= 3) return s;
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);
  return '${groups.join(',')},$last3';
}

({int value, String text}) amount(Random r) {
  final b = r.nextInt(10);
  int n;
  if (b < 4) {
    n = 10 + r.nextInt(990);
  } else if (b < 8) {
    n = (1 + r.nextInt(99)) * 100 + (r.nextBool() ? 0 : 50);
  } else if (b < 9) {
    n = (1 + r.nextInt(99)) * 1000;
  } else {
    n = (1 + r.nextInt(9)) * 100000 + r.nextInt(2) * 50000;
  }
  final forms = <String>['$n', '₹$n', 'Rs $n', '$n rupees', 'Rs. $n'];
  if (n >= 1000) forms.addAll([_indian(n), '₹${_indian(n)}']);
  forms.add(_words(n, r));
  if (n % 1000 == 0 && n < 100000) forms.add('${n ~/ 1000}k');
  if (n >= 100000 && n % 50000 == 0) {
    final lakhs = n / 100000;
    forms.add(
      lakhs == lakhs.roundToDouble() ? '${lakhs.toInt()} lakh' : '$lakhs lakh',
    );
  }
  if (n >= 150 && n < 1000 && n % 100 == 50) {
    forms.add('${_ones[n ~/ 100]} fifty');
  }
  if (n >= 1100 && n <= 1900 && n % 100 == 0) {
    forms.add('${_below100(n ~/ 100)} hundred');
  }
  return (value: n, text: forms[r.nextInt(forms.length)]);
}

// ---- the facts of an entry ----------------------------------------------------------

class Obj {
  const Obj(this.text, this.category, this.merchant);
  final String text;
  final String? category;
  final String? merchant;
}

/// What is bought: a plain word that is a category, or a known brand.
final objects = <Obj>[
  const Obj('groceries', 'groceries', null),
  const Obj('lunch', 'dining', null),
  const Obj('dinner', 'dining', null),
  const Obj('petrol', 'fuel', null),
  const Obj('coffee', 'dining', null),
  const Obj('medicines', 'health', null),
  const Obj('movie tickets', 'entertainment', null),
  const Obj('rent', 'rent', null),
  for (final brand in const [
    'swiggy',
    'zomato',
    'uber',
    'amazon',
    'flipkart',
    'bigbasket',
    'blinkit',
    'netflix',
  ])
    Obj(
      brand,
      FlashTextMerchantExtractor.defaultExtractor.extractFirst(brand)?.category,
      FlashTextMerchantExtractor.defaultExtractor
          .extractFirst(brand)
          ?.canonicalName,
    ),
];

const dates = <(String, int?)>[
  ('', null),
  ('', null),
  ('', null),
  ('today', null),
  ('yesterday', -1),
  ('2 days ago', -2),
  ('3 days ago', -3),
  ('last friday', -5),
  ('on friday', -5),
  ('last monday', -2),
  ('on the 5th', -6),
];

const instruments = <(String, TxnInstrument?)>[
  ('', null),
  ('', null),
  ('', null),
  ('using my UPI', TxnInstrument.upiBank),
  ('with google pay', TxnInstrument.upiBank),
  ('in cash', TxnInstrument.cash),
  ('on my debit card', TxnInstrument.debitCard),
];

// ---- phrase building -----------------------------------------------------------------

String addNoise(String text, Random r) {
  var words = text.split(' ');
  // fillers
  if (r.nextInt(5) == 0) {
    final i = r.nextInt(words.length);
    words.insert(i, ['um', 'uh', 'like', 'so'][r.nextInt(4)]);
  }
  // a repeated word, as speech recognizers do
  if (r.nextInt(12) == 0) {
    final i = r.nextInt(words.length);
    // Recognizers repeat ordinary words; a repeated "four" or "fifty" would
    // be a different number, so those are left alone.
    if (RegExp(r'^[a-z]+$').hasMatch(words[i]) &&
        words[i].length > 2 &&
        !_ones.contains(words[i]) &&
        !_tens.contains(words[i])) {
      words.insert(i, words[i]);
    }
  }
  var out = words.join(' ');
  if (r.nextInt(6) == 0) out = '${out[0].toUpperCase()}${out.substring(1)}';
  if (r.nextInt(10) == 0) out = '$out.';
  return out;
}

class Frame {
  Frame(this.text, this.expect, this.template);
  final String text;
  final List<Expect> expect;
  final String template;
}

class Expect {
  Expect({
    this.type = VoiceActionType.expense,
    this.amount,
    this.dayOffset,
    this.category,
    this.merchant,
    this.instrument,
    this.foreign,
  });
  final VoiceActionType type;
  final double? amount;
  final int? dayOffset;
  final String? category;
  final String? merchant;
  final TxnInstrument? instrument;
  final String? foreign;
}

Frame spendFrame(Random r) {
  final a = amount(r);
  final o = objects[r.nextInt(objects.length)];
  final d = dates[r.nextInt(dates.length)];
  final i = instruments[r.nextInt(instruments.length)];
  final verb = ['spent', 'paid'][r.nextInt(2)];
  final t = r.nextInt(7);
  final dp = d.$1;
  final ip = i.$1;
  String s;
  switch (t) {
    case 0:
      s = '$verb ${a.text} on ${o.text} $ip $dp';
    case 1:
      s = '$dp $verb ${a.text} on ${o.text} $ip';
    case 2:
      s = '${a.text} for ${o.text} $dp $ip';
    case 3:
      s = 'I $verb ${a.text} on ${o.text} $ip $dp';
    case 4:
      s = '$dp I $verb ${a.text} $ip for ${o.text}';
    case 5:
      s = 'add spending of ${a.text} on ${o.text} $dp $ip';
    default:
      s = '$verb ${a.text} at ${o.text} $dp $ip';
  }
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return Frame(addNoise(s, r), [
    Expect(
      amount: a.value.toDouble(),
      dayOffset: d.$2,
      category: o.category,
      merchant: o.merchant,
      instrument: i.$2,
    ),
  ], 'spend-$t');
}

Frame multiFrame(Random r) {
  final n = 2 + r.nextInt(2);
  final amounts = [for (var k = 0; k < n; k++) amount(r)];
  final objs = [for (var k = 0; k < n; k++) objects[r.nextInt(objects.length)]];
  final d = dates[r.nextInt(dates.length)];
  final verb = ['spent', 'paid'][r.nextInt(2)];
  final style = r.nextInt(3);
  final parts = <String>[];
  for (var k = 0; k < n; k++) {
    parts.add(
      style == 0
          ? '${k == 0 ? '$verb ' : ''}${amounts[k].text} on ${objs[k].text}'
          : '${amounts[k].text} for ${objs[k].text}',
    );
  }
  var body = parts.length == 2
      ? parts.join(' and ')
      : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  final lead = r.nextBool();
  final s = d.$1.isEmpty
      ? body
      : (lead
            ? '${d.$1} $verb ${body.replaceFirst('$verb ', '')}'
            : '$body ${d.$1}');
  return Frame(
    addNoise(s.replaceAll(RegExp(r'\s+'), ' ').trim(), r),
    [
      for (var k = 0; k < n; k++)
        Expect(
          amount: amounts[k].value.toDouble(),
          dayOffset: d.$2,
          category: objs[k].category,
          merchant: objs[k].merchant,
        ),
    ],
    'multi-${style == 0 ? 'verb' : 'plain'}-$n',
  );
}

const people = ['Rahul', 'Priya', 'Ankit', 'Meera'];

Frame incomeFrame(Random r) {
  final a = amount(r);
  final p = people[r.nextInt(people.length)];
  final shop = ['amazon', 'flipkart', 'myntra'][r.nextInt(3)];
  final t = r.nextInt(5);
  switch (t) {
    case 0:
      return Frame(addNoise('received ${a.text} from $p', r), [
        Expect(
          type: VoiceActionType.moneyIn,
          amount: a.value.toDouble(),
          merchant: p,
        ),
      ], 'income-received');
    case 1:
      return Frame(addNoise('$p paid me ${a.text}', r), [
        Expect(type: VoiceActionType.moneyIn, amount: a.value.toDouble()),
      ], 'income-paid-me');
    case 2:
      return Frame(addNoise('salary credited ${a.text}', r), [
        Expect(type: VoiceActionType.moneyIn, amount: a.value.toDouble()),
      ], 'income-salary');
    case 3:
      return Frame(addNoise('got a refund of ${a.text} from $shop', r), [
        Expect(type: VoiceActionType.refund, amount: a.value.toDouble()),
      ], 'refund-got');
    default:
      return Frame(addNoise('refund of ${a.text} from $shop', r), [
        Expect(type: VoiceActionType.refund, amount: a.value.toDouble()),
      ], 'refund-of');
  }
}

Frame foreignFrame(Random r) {
  final v = 5 + r.nextInt(500);
  final c = [
    ('dollars', 'USD'),
    ('euros', 'EUR'),
    ('pounds', 'GBP'),
    ('dirhams', 'AED'),
  ][r.nextInt(4)];
  final place = ['Dubai', 'Paris', 'London', 'Singapore'][r.nextInt(4)];
  final s = r.nextBool()
      ? 'spent $v ${c.$1} in $place'
      : 'paid $v ${c.$1} for a museum ticket';
  return Frame(addNoise(s, r), [
    Expect(foreign: c.$2, amount: null),
  ], 'foreign');
}

/// Things that must not become a spend.
Frame notSpendFrame(Random r) {
  final a = amount(r);
  final t = r.nextInt(5);
  final texts = [
    'transferred ${a.text} to my savings account',
    'paid my credit card bill of ${a.text}',
    'paid the hdfc card statement ${a.text}',
    'add a new credit card',
    'link my axis card',
  ];
  return Frame(addNoise(texts[t], r), [
    Expect(type: VoiceActionType.unsupported),
  ], 'not-spend-$t');
}

// ---- checking ---------------------------------------------------------------------------

String? check(Frame f) {
  final drafts = VoiceActionParser.parseMany(
    f.text,
    cards: const <UserCard>[],
    categories: categories,
    now: now,
  );
  if (drafts.length != f.expect.length) {
    return 'wanted ${f.expect.length} entries, got ${drafts.length}: '
        '${drafts.map((d) => '${d.type.name}:${d.amount}').toList()}';
  }
  for (var i = 0; i < drafts.length; i++) {
    final d = drafts[i];
    final e = f.expect[i];
    if (d.type != e.type)
      return 'entry $i type ${d.type.name}, wanted ${e.type.name}';
    if (e.type == VoiceActionType.unsupported) continue;
    if (e.foreign != null) {
      if (d.foreignCurrency != e.foreign)
        return 'currency ${d.foreignCurrency}';
      if (d.amount != null)
        return 'foreign amount logged as rupees ${d.amount}';
      continue;
    }
    if (e.amount != null &&
        (d.amount == null || (d.amount! - e.amount!).abs() > 0.001)) {
      return 'entry $i amount ${d.amount}, wanted ${e.amount}';
    }
    if (e.dayOffset == null) {
      if (d.occurredAt != null)
        return 'entry $i has a date ${d.occurredAt}, none said';
    } else {
      final want = DateTime(2026, 11, 11 + e.dayOffset!, 12);
      if (d.occurredAt != want)
        return 'entry $i date ${d.occurredAt}, wanted $want';
    }
    if (e.category != null && d.categoryId != '${e.category}-id') {
      return 'entry $i category ${d.categoryId}, wanted ${e.category}';
    }
    if (e.merchant != null && d.merchant != e.merchant) {
      return 'entry $i merchant ${d.merchant}, wanted ${e.merchant}';
    }
    if (e.instrument != null && d.instrument != e.instrument) {
      return 'entry $i instrument ${d.instrument}, wanted ${e.instrument}';
    }
  }
  return null;
}

void runGroup(
  String name,
  Frame Function(Random) make,
  int count, {
  required double minPass,
  int seed = 7,
}) {
  test('$name: $count generated phrases', () {
    final r = Random(seed);
    final failures = <String, List<String>>{};
    var pass = 0;
    var silentWrong = 0;
    for (var i = 0; i < count; i++) {
      final f = make(r);
      final problem = check(f);
      if (problem == null) {
        pass++;
      } else {
        failures
            .putIfAbsent(f.template, () => [])
            .add('"${f.text}" -> $problem');
        if (problem.contains('amount') && !problem.contains('null'))
          silentWrong++;
      }
    }
    final rate = pass / count;
    // ignore: avoid_print
    print(
      '$name: $pass/$count (${(rate * 100).toStringAsFixed(1)}%), wrong amounts $silentWrong'
      '${failures.entries.map((e) => '\n  ${e.key}: ${e.value.length}\n    ${e.value.take(3).join('\n    ')}').join()}',
    );
    expect(rate, greaterThanOrEqualTo(minPass), reason: failures.toString());
  });
}

// ---- questions ------------------------------------------------------------------------------

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

void questionGroup(int count) {
  test('questions: $count generated phrases', () {
    final r = Random(11);
    final periods = <(String, DateTime, DateTime)>[
      ('this month', DateTime(2026, 11, 1), DateTime(2026, 11, 30)),
      ('last month', DateTime(2026, 10, 1), DateTime(2026, 10, 31)),
      ('this week', DateTime(2026, 11, 9), DateTime(2026, 11, 15)),
      ('last week', DateTime(2026, 11, 2), DateTime(2026, 11, 8)),
      ('yesterday', DateTime(2026, 11, 10), DateTime(2026, 11, 10)),
      ('this year', DateTime(2026, 1, 1), DateTime(2026, 12, 31)),
      ('last year', DateTime(2025, 1, 1), DateTime(2025, 12, 31)),
      ('in october', DateTime(2026, 10, 1), DateTime(2026, 10, 31)),
    ];
    final filters = <(String, String?, String?, String?, TxnInstrument?)>[
      ('', null, null, null, null),
      ('', null, null, null, null),
      ('on dining', 'dining', null, null, null),
      ('on groceries', 'groceries', null, null, null),
      ('on fuel', 'fuel', null, null, null),
      ('on swiggy', null, 'Swiggy', null, null),
      ('on netflix', null, 'Netflix', null, null),
      ('on my amex', null, null, 'amex', null),
      ('by upi', null, null, null, TxnInstrument.upiBank),
    ];
    final failures = <String>[];
    var pass = 0;
    for (var i = 0; i < count; i++) {
      final p = periods[r.nextInt(periods.length)];
      final f = filters[r.nextInt(filters.length)];
      final t = r.nextInt(14);
      String text;
      QuestionKind kind = QuestionKind.spend;
      var checkFilters = true;
      var checkPeriod = true;
      switch (t) {
        case 0:
          text = 'how much did I spend ${f.$1} ${p.$1}';
        case 1:
          text = 'what did I spend ${f.$1} ${p.$1}';
        case 2:
          text = 'total spending ${f.$1} ${p.$1}';
        case 3:
          text = 'show me my spending ${f.$1} ${p.$1}';
        case 4:
          text = 'how much have I spent ${f.$1} ${p.$1}';
        case 5:
          text = 'where did I spend the most ${p.$1}';
          kind = QuestionKind.topSpends;
          checkFilters = false;
        case 6:
          text = 'how much came in ${p.$1}';
          kind = QuestionKind.moneyIn;
          checkFilters = false;
        case 7:
          text = 'what is my income ${p.$1}';
          kind = QuestionKind.moneyIn;
          checkFilters = false;
        case 8:
          final c = ['hdfc', 'amex', 'axis atlas'][r.nextInt(3)];
          text = 'when is my $c bill due';
          kind = QuestionKind.billsDue;
          checkFilters = false;
          checkPeriod = false;
        case 9:
          final c = ['swiggy', 'atlas', 'amex'][r.nextInt(3)];
          text = 'how much cap is left on my $c card';
          kind = QuestionKind.capsLeft;
          checkFilters = false;
          checkPeriod = false;
        case 10:
          final c = ['amex', 'axis atlas', 'hdfc'][r.nextInt(3)];
          text = 'how many points do I have on $c';
          kind = QuestionKind.pointsBalance;
          checkFilters = false;
          checkPeriod = false;
        case 11:
          final a = amount(r);
          text = 'which card should I use for ${a.text} at croma';
          kind = QuestionKind.bestCard;
          checkFilters = false;
          checkPeriod = false;
        case 12:
          text = 'this month versus last month';
          kind = QuestionKind.compare;
          checkFilters = false;
          checkPeriod = false;
        default:
          text = 'did I spend more than last month';
          kind = QuestionKind.compare;
          checkFilters = false;
          checkPeriod = false;
      }
      text = addNoise(text.replaceAll(RegExp(r'\s+'), ' ').trim(), r);
      final q = const QuestionReader().read(
        text,
        now: now,
        cards: cards,
        categories: categories,
        knownMerchants: const ['Croma'],
      );
      String? problem;
      if (q.kind != kind) {
        problem = 'kind ${q.kind.name}, wanted ${kind.name}';
      } else if (checkPeriod &&
          (q.period?.from != p.$2 || q.period?.to != p.$3)) {
        problem =
            'period ${q.period?.from}..${q.period?.to}, wanted ${p.$2}..${p.$3}';
      } else if (checkFilters) {
        if (q.category?.slug != f.$2) {
          problem = 'category ${q.category?.slug}, wanted ${f.$2}';
        } else if (q.merchant != f.$3) {
          problem = 'merchant ${q.merchant}, wanted ${f.$3}';
        } else if ((q.cards.isEmpty ? null : q.cards.single.id) != f.$4) {
          problem = 'card ${q.cards.map((c) => c.id)}, wanted ${f.$4}';
        } else if (q.instrument != f.$5) {
          problem = 'instrument ${q.instrument}, wanted ${f.$5}';
        }
      }
      if (problem == null) {
        pass++;
      } else {
        failures.add('"$text" -> $problem');
      }
    }
    // ignore: avoid_print
    print(
      'questions: $pass/$count${failures.isEmpty ? '' : '\n  ${failures.take(8).join('\n  ')}'}',
    );
    expect(
      pass / count,
      greaterThanOrEqualTo(0.97),
      reason: failures.take(10).join('\n'),
    );
  });
}

void main() {
  runGroup('one spend', spendFrame, 2500, minPass: 0.98);
  runGroup('several spends', multiFrame, 800, minPass: 0.95, seed: 8);
  runGroup('money in and refunds', incomeFrame, 600, minPass: 0.98, seed: 9);
  runGroup('foreign amounts', foreignFrame, 300, minPass: 0.99, seed: 10);
  runGroup('never a spend', notSpendFrame, 400, minPass: 1.0, seed: 12);
  questionGroup(1500);
}
