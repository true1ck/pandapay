// CCR-006 / CCR-007: a bill notice that names only a month, and what a rule can
// say a bill is. Every value is invented.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/src/sms_v2/engine/transforms.dart'
    show parseMonthEnd;
import 'package:test/test.dart';

Directory _fixtures() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final c = Directory('${dir.path}/contracts/sms/v2/fixtures/valid/fact');
    if (c.existsSync()) return c;
    dir = dir.parent;
  }
  throw StateError('fixtures not found above ${Directory.current.path}');
}

Map<String, Object?> _fixture(String name) =>
    (jsonDecode(File('${_fixtures().path}/$name.json').readAsStringSync()) as Map)
        .cast<String, Object?>();

Map<String, Object?> _bill({
  Map<String, Object?> attrs = const {'dueDate': '2026-09-30'},
  List<Map<String, Object?>> amounts = const [],
}) =>
    {..._fixture('bill_due.month_only'), 'attrs': attrs, 'amounts': amounts};

const _due = {'role': 'due_total', 'minor': 100000, 'unit': 'INR'};

/// The error codes reading [json] as a fact is refused with ([] when valid).
List<String> _refusals(Map<String, Object?> json) {
  try {
    Fact.fromJson(json);
    return const [];
  } on ContractException catch (e) {
    return [for (final x in e.errors) x.code];
  }
}

void main() {
  group('the contract', () {
    test('the month-only fixture is valid and keeps its flags through a round trip', () {
      final f = Fact.fromJson(_fixture('bill_due.month_only')) as BillDueFact;
      expect(f.validate().ok, isTrue);
      expect(f.dueMonthOnly, isTrue);
      expect(f.billKind, 'insurance');
      expect(f.amounts, isEmpty);
      final again = Fact.fromJson(f.toJson()) as BillDueFact;
      expect(again.dueMonthOnly, isTrue);
      expect(again.billKind, 'insurance');
      expect(again.dueDate, f.dueDate);
    });

    test('a month-only notice may also print an amount', () {
      final f = Fact.fromJson(
        _bill(attrs: const {'dueDate': '2026-09-30', 'dueMonthOnly': true}, amounts: [_due]),
      );
      expect(f.validate().ok, isTrue);
    });

    test('a dated bill still needs an amount', () {
      expect(
        _refusals(_bill(attrs: const {'dueDate': '2026-09-30'})),
        contains('fact.bill_due.amount_required'),
      );
    });

    test('a dated bill with only a minimum due is still a bill', () {
      final f = Fact.fromJson(
        _bill(amounts: const [
          {'role': 'due_minimum', 'minor': 5000, 'unit': 'INR'},
        ]),
      );
      expect(f.validate().ok, isTrue);
    });

    test('the flag can only be true', () {
      expect(
        _refusals(_bill(
          attrs: const {'dueDate': '2026-09-30', 'dueMonthOnly': false},
          amounts: [_due],
        )),
        contains('fact.bill_due.dueMonthOnly_invalid'),
      );
    });

    test('a month-only bill still needs its (month-end) date', () {
      expect(
        _refusals(_bill(attrs: const {'dueMonthOnly': true})),
        contains('fact.bill_due.dueDate_required'),
      );
    });

    for (final kind in ['utility', 'telecom', 'insurance', 'loan', 'rent', 'education', 'tax']) {
      test('billKind $kind is allowed', () {
        final f = Fact.fromJson(
          _bill(attrs: {'dueDate': '2026-09-30', 'billKind': kind}, amounts: [_due]),
        );
        expect(f.validate().ok, isTrue);
      });
    }

    test('an unknown billKind is refused', () {
      expect(
        _refusals(_bill(
          attrs: const {'dueDate': '2026-09-30', 'billKind': 'spaceship'},
          amounts: [_due],
        )),
        contains('fact.bill_due.billKind_invalid'),
      );
    });

    test('the insurance purpose is allowed on an attempt and a movement', () {
      for (final base in ['attempt.scheduled_debit', 'movement.card_spend']) {
        final json = _fixture(base);
        json['attrs'] = {...(json['attrs'] as Map).cast<String, Object?>(), 'purpose': 'insurance'};
        expect(Fact.fromJson(json).validate().ok, isTrue, reason: base);
      }
    });
  });

  group('month-end dates', () {
    DateTime? read(String s, [List<String> formats = const ['MM/yyyy', 'MM-yyyy', 'MMM yyyy', 'MMM-yyyy']]) =>
        parseMonthEnd(s, formats);
    // The engine keeps dates as midnight in India, stored as UTC.
    DateTime ist(int y, int m, int d) =>
        DateTime.utc(y, m, d).subtract(const Duration(hours: 5, minutes: 30));

    test('numeric months', () {
      expect(read('09/2026'), ist(2026, 9, 30));
      expect(read('9/2026'), ist(2026, 9, 30));
      expect(read('09-2026'), ist(2026, 9, 30));
      expect(read('01/2027'), ist(2027, 1, 31));
    });

    test('month names, short or full, any case', () {
      expect(read('Sep 2026'), ist(2026, 9, 30));
      expect(read('September 2026'), ist(2026, 9, 30));
      expect(read('SEPTEMBER 2026'), ist(2026, 9, 30));
      expect(read('dec 2026'), ist(2026, 12, 31));
    });

    test('leap years and the year end', () {
      expect(read('02/2028'), ist(2028, 2, 29));
      expect(read('02/2027'), ist(2027, 2, 28));
      expect(read('12/2026'), ist(2026, 12, 31));
    });

    test('anything that is not a month and a year is not a date', () {
      for (final bad in ['13/2026', '00/2026', 'Sept 26', '2026', 'soon', '', '09/0026', '09/3000']) {
        expect(read(bad), isNull, reason: bad);
      }
    });
  });
}
