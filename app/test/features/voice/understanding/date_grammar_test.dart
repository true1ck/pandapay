import 'package:flutter_test/flutter_test.dart';

import '../../../../lib/features/voice/understanding/date_grammar.dart';
import '../../../../lib/features/voice/understanding/en_pack.dart';
import '../../../../lib/features/voice/understanding/tokens.dart';

// Wednesday 11 November 2026.
final now = DateTime(2026, 11, 11, 15, 30);
final today = DateTime(2026, 11, 11);

TimeSpan? first(String text, {DateTime? at}) {
  final spans = findTimeSpans(tokenize(text), enPack, at ?? now);
  return spans.isEmpty ? null : spans.first;
}

DateTime d(int y, int m, int day) => DateTime(y, m, day);

void main() {
  test('the reference date is a Wednesday', () {
    expect(today.weekday, DateTime.wednesday);
  });

  group('single days', () {
    final cases = <String, DateTime>{
      'today': today,
      'tonight': today,
      'this morning': today,
      'yesterday': d(2026, 11, 10),
      'yesterday evening': d(2026, 11, 10),
      'last night': d(2026, 11, 10),
      'the day before yesterday': d(2026, 11, 9),
      '2 days ago': d(2026, 11, 9),
      'three days ago': d(2026, 11, 8),
      'a week ago': d(2026, 11, 4),
      'a month ago': d(2026, 10, 11),
      'two weeks ago': d(2026, 10, 28),
      'last friday': d(2026, 11, 6),
      'on friday': d(2026, 11, 6),
      'wednesday': today,
      'last wednesday': d(2026, 11, 4),
      'on monday': d(2026, 11, 9),
      'on the 3rd': d(2026, 11, 3),
      'on the third': d(2026, 11, 3),
      'on the 20th': d(2026, 10, 20),
      '3rd of november': d(2026, 11, 3),
      '3 november': d(2026, 11, 3),
      'nov 3': d(2026, 11, 3),
      'november 3rd': d(2026, 11, 3),
      '3 nov 2025': d(2025, 11, 3),
      'twenty first of march': d(2026, 3, 21),
      '21st march': d(2026, 3, 21),
      '3/11': d(2026, 11, 3),
      '03/10/2026': d(2026, 10, 3),
      '5/6/25': d(2025, 6, 5),
    };
    cases.forEach((text, expected) {
      test('"$text"', () {
        final s = first(text);
        expect(s, isNotNull);
        expect(s!.isSingleDay, isTrue, reason: '${s.from} to ${s.to}');
        expect(s.from, expected);
      });
    });

    test('a day later in the year than today names last year', () {
      final s = first('25 december')!;
      expect(s.from, d(2025, 12, 25));
      expect(s.yearInferredBack, isTrue);
    });

    test('a day already past this year does not shift', () {
      final s = first('5 march')!;
      expect(s.from, d(2026, 3, 5));
      expect(s.yearInferredBack, isFalse);
    });

    test('an impossible date is not a date', () {
      expect(first('31 february'), isNull);
    });
  });

  group('periods', () {
    void check(String text, DateTime from, DateTime to, TimeSpanKind kind) {
      test('"$text"', () {
        final s = first(text);
        expect(s, isNotNull);
        expect(s!.from, from);
        expect(s.to, to);
        expect(s.kind, kind);
      });
    }

    check('this week', d(2026, 11, 9), d(2026, 11, 15), TimeSpanKind.week);
    check('last week', d(2026, 11, 2), d(2026, 11, 8), TimeSpanKind.week);
    check('this month', d(2026, 11, 1), d(2026, 11, 30), TimeSpanKind.month);
    check('last month', d(2026, 10, 1), d(2026, 10, 31), TimeSpanKind.month);
    check('this quarter', d(2026, 10, 1), d(2026, 12, 31), TimeSpanKind.quarter);
    check('last quarter', d(2026, 7, 1), d(2026, 9, 30), TimeSpanKind.quarter);
    check('this year', d(2026, 1, 1), d(2026, 12, 31), TimeSpanKind.year);
    check('last year', d(2025, 1, 1), d(2025, 12, 31), TimeSpanKind.year);
    check(
      'this financial year',
      d(2026, 4, 1),
      d(2027, 3, 31),
      TimeSpanKind.financialYear,
    );
    check(
      'last financial year',
      d(2025, 4, 1),
      d(2026, 3, 31),
      TimeSpanKind.financialYear,
    );
    check('this fy', d(2026, 4, 1), d(2027, 3, 31), TimeSpanKind.financialYear);
    check('last 7 days', d(2026, 11, 5), today, TimeSpanKind.rolling);
    check('past 30 days', d(2026, 10, 13), today, TimeSpanKind.rolling);
    check('last three months', d(2026, 8, 12), today, TimeSpanKind.rolling);
    check('past week', d(2026, 11, 5), today, TimeSpanKind.rolling);
    check('in october', d(2026, 10, 1), d(2026, 10, 31), TimeSpanKind.month);
    check('in december', d(2025, 12, 1), d(2025, 12, 31), TimeSpanKind.month);
    check('october 2025', d(2025, 10, 1), d(2025, 10, 31), TimeSpanKind.month);
    check('in 2025', d(2025, 1, 1), d(2025, 12, 31), TimeSpanKind.year);
    check('since monday', d(2026, 11, 9), today, TimeSpanKind.since);
    check('since 1st october', d(2026, 10, 1), today, TimeSpanKind.since);
    check('since last month', d(2026, 10, 1), today, TimeSpanKind.since);
    check(
      'from 1 october to 15 october',
      d(2026, 10, 1),
      d(2026, 10, 15),
      TimeSpanKind.range,
    );
    check(
      'between 3rd and 5th of october',
      d(2026, 10, 3),
      d(2026, 10, 5),
      TimeSpanKind.range,
    );
    check('year to date', d(2026, 1, 1), today, TimeSpanKind.toDate);
    check('month to date', d(2026, 11, 1), today, TimeSpanKind.toDate);
    check('all time', d(2000, 1, 1), today, TimeSpanKind.allTime);
  });

  group('not dates', () {
    test('amounts and quantities are not dates', () {
      expect(first('spent 250 on lunch'), isNull);
      expect(first('2 coffees for 300'), isNull);
      expect(first('I may spend more'), isNull);
    });

    test('a modal "may" is not a month', () {
      expect(first('i may buy it'), isNull);
    });
  });

  group('inside a sentence', () {
    test('reports the tokens it used', () {
      const text = 'spent 250 on lunch last friday at swiggy';
      final tokens = tokenize(text);
      final s = findTimeSpans(tokens, enPack, now).single;
      expect(s.text(text, tokens), 'last friday');
      expect(s.from, d(2026, 11, 6));
    });

    test('finds a date and a period in one sentence', () {
      final spans = findTimeSpans(
        tokenize('yesterday i spent more than in october'),
        enPack,
        now,
      );
      expect(spans, hasLength(2));
      expect(spans[0].from, d(2026, 11, 10));
      expect(spans[1].kind, TimeSpanKind.month);
    });
  });

  group('month boundaries', () {
    test('end of month rolls back safely', () {
      final s = first('a month ago', at: DateTime(2026, 3, 31))!;
      expect(s.from, d(2026, 2, 28));
    });

    test('january looks back into december', () {
      final s = first('last month', at: DateTime(2027, 1, 15))!;
      expect(s.from, d(2026, 12, 1));
      expect(s.to, d(2026, 12, 31));
    });

    test('first quarter of the year looks back to the last quarter', () {
      final s = first('last quarter', at: DateTime(2027, 2, 10))!;
      expect(s.from, d(2026, 10, 1));
      expect(s.to, d(2026, 12, 31));
    });

    test('the financial year in January started last April', () {
      final s = first('this financial year', at: DateTime(2027, 1, 20))!;
      expect(s.from, d(2026, 4, 1));
      expect(s.to, d(2027, 3, 31));
    });
  });
}
