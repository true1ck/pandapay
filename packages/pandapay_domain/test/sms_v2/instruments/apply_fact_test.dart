import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart';

DateTime _d(String s) => DateTime.parse(s).toUtc();

void main() {
  Instrument card() => instrument(kind: InstrumentKind.creditCard, mask: '5678');

  group('balance_snapshot', () {
    test('sets available_credit and its time', () {
      final i = applyFactToInstrument(
        card(),
        balance('available_credit', 4500000, asOf: '2026-11-01T10:00:00Z'),
      );
      expect(i.availableMinor, 4500000);
      expect(i.availableAt, _d('2026-11-01T10:00:00Z'));
    });

    test('available_balance goes to available* too', () {
      final acct = instrument(kind: InstrumentKind.bankAccount, mask: '1234');
      final i = applyFactToInstrument(
        acct,
        balance(
          'available_balance',
          1234500,
          asOf: '2026-11-01T10:00:00Z',
          instrument: mention(kind: InstrumentKind.bankAccount, mask: '1234'),
        ),
      );
      expect(i.availableMinor, 1234500);
    });

    test('snapshot ordering follows asOf, not arrival order', () {
      final newer = balance('available_credit', 300, asOf: '2026-11-03T10:00:00Z');
      final older = balance(
        'available_credit',
        100,
        asOf: '2026-11-01T10:00:00Z',
        observedAt: '2026-11-05T10:00:00Z',
      );
      // newer arrives first, the older one arrives later (for example a replay).
      var i = applyFactToInstrument(card(), newer);
      i = applyFactToInstrument(i, older);
      expect(i.availableMinor, 300);
      expect(i.availableAt, _d('2026-11-03T10:00:00Z'));
      // reverse arrival order gives the same answer
      var j = applyFactToInstrument(card(), older);
      j = applyFactToInstrument(j, newer);
      expect(j.availableMinor, 300);
    });

    test('an equal asOf does not replace the stored value', () {
      var i = applyFactToInstrument(
        card(),
        balance('available_credit', 300, asOf: '2026-11-03T10:00:00Z'),
      );
      i = applyFactToInstrument(i, balance('available_credit', 999, asOf: '2026-11-03T10:00:00Z'));
      expect(i.availableMinor, 300);
    });

    test('a zero balance is a real balance', () {
      var i = applyFactToInstrument(
        card(),
        balance('available_credit', 300, asOf: '2026-11-01T10:00:00Z'),
      );
      i = applyFactToInstrument(i, balance('available_credit', 0, asOf: '2026-11-02T10:00:00Z'));
      expect(i.availableMinor, 0);
    });

    test('points_balance updates points* by time and leaves available* alone', () {
      var i = applyFactToInstrument(
        card(),
        balance('available_credit', 700, asOf: '2026-11-01T10:00:00Z'),
      );
      i = applyFactToInstrument(
        i,
        balance('points_balance', 1200, asOf: '2026-11-02T10:00:00Z', unit: 'POINTS'),
      );
      expect(i.pointsBalance, 1200);
      expect(i.pointsAt, _d('2026-11-02T10:00:00Z'));
      expect(i.availableMinor, 700);
      // older points snapshot is ignored
      i = applyFactToInstrument(
        i,
        balance('points_balance', 50, asOf: '2026-10-01T10:00:00Z', unit: 'POINTS'),
      );
      expect(i.pointsBalance, 1200);
      // newer points snapshot wins
      i = applyFactToInstrument(
        i,
        balance('points_balance', 1500, asOf: '2026-11-04T10:00:00Z', unit: 'POINTS'),
      );
      expect(i.pointsBalance, 1500);
    });

    test('outstanding is not stored on the instrument', () {
      final i = applyFactToInstrument(
        card(),
        balance('outstanding', 55000, asOf: '2026-11-01T10:00:00Z'),
      );
      expect(i.availableMinor, isNull);
      expect(i.evidenceCount, 1);
    });
  });

  group('limit_change', () {
    test('an SMS limit is stored with source sms', () {
      final i = applyFactToInstrument(
        card(),
        limit(10000000, at: '2026-11-01T08:00:00Z', reason: 'assigned'),
      );
      expect(i.creditLimitMinor, 10000000);
      expect(i.creditLimitSource, CreditLimitSource.sms);
      expect(i.creditLimitAt, _d('2026-11-01T08:00:00Z'));
    });

    test('a limit enhancement updates an SMS-learned limit and keeps history', () {
      final first = applyFact(
        card(),
        limit(10000000, at: '2026-10-01T08:00:00Z', reason: 'assigned'),
      );
      final second = applyFact(
        first.instrument,
        limit(30000000, at: '2026-11-01T08:00:00Z'),
        limitHistory: first.limitHistory,
      );
      expect(second.instrument.creditLimitMinor, 30000000);
      expect(second.instrument.creditLimitSource, CreditLimitSource.sms);
      expect(second.limitHistory.map((r) => r.minor), [10000000, 30000000]);
      expect(second.limitHistory.last.previousMinor, 10000000);
      expect(second.limitHistory.last.reason, LimitChangeReason.increase);
    });

    test('a user-entered limit is never overwritten', () {
      final user = card().copyWith(
        creditLimitMinor: 20000000,
        creditLimitSource: CreditLimitSource.user,
        creditLimitAt: _d('2026-10-01T00:00:00Z'),
      );
      final r = applyFact(user, limit(50000000, at: '2026-11-01T08:00:00Z'));
      expect(r.instrument.creditLimitMinor, 20000000);
      expect(r.instrument.creditLimitSource, CreditLimitSource.user);
      expect(r.limitHistory, isEmpty);
      // other bookkeeping still runs
      expect(r.instrument.evidenceCount, 1);
    });

    test('history keeps only the last five changes', () {
      var update = InstrumentUpdate(card(), const []);
      for (var m = 1; m <= 7; m++) {
        update = applyFact(
          update.instrument,
          limit(m * 100000, at: '2026-0$m-01T08:00:00Z'),
          limitHistory: update.limitHistory,
        );
      }
      expect(update.limitHistory.length, maxLimitHistory);
      expect(update.limitHistory.first.minor, 300000);
      expect(update.limitHistory.last.minor, 700000);
      expect(update.instrument.creditLimitMinor, 700000);
    });

    test('an older limit message does not roll the limit back', () {
      var i = applyFactToInstrument(card(), limit(30000000, at: '2026-11-01T08:00:00Z'));
      i = applyFactToInstrument(i, limit(10000000, at: '2026-09-01T08:00:00Z', reason: 'assigned'));
      expect(i.creditLimitMinor, 30000000);
    });

    test('the same limit again adds no history entry', () {
      final a = applyFact(card(), limit(10000000, at: '2026-10-01T08:00:00Z', reason: 'assigned'));
      final b = applyFact(
        a.instrument,
        limit(10000000, at: '2026-11-01T08:00:00Z', reason: 'assigned'),
        limitHistory: a.limitHistory,
      );
      expect(b.limitHistory.length, 1);
    });

    test('LimitChangeRecord round-trips through JSON', () {
      final r = LimitChangeRecord(
        minor: 5,
        previousMinor: 3,
        at: _d('2026-11-01T08:00:00Z'),
        reason: LimitChangeReason.decrease,
      );
      expect(LimitChangeRecord.fromJson(r.toJson()).toJson(), r.toJson());
    });
  });

  group('instrument_hint', () {
    test('adds the product name once', () {
      var i = applyFactToInstrument(
        card(),
        hint(
          'product_name',
          at: '2026-11-01T08:00:00Z',
          instrument: mention(product: 'Regalia Gold'),
        ),
      );
      i = applyFactToInstrument(
        i,
        hint(
          'product_name',
          at: '2026-11-02T08:00:00Z',
          instrument: mention(product: 'regalia gold'),
        ),
      );
      expect(i.aliases.productNames, ['Regalia Gold']);
    });

    test('adds a linked UPI ID once, lower case', () {
      final h = hint(
        'linked_upi',
        at: '2026-11-01T08:00:00Z',
        counterparty: {'name': null, 'vpa': 'Ravi@OkAxis', 'kind': 'own', 'accountMask': null},
      );
      var i = applyFactToInstrument(
        instrument(kind: InstrumentKind.bankAccount, issuer: 'axis', mask: '1234'),
        h,
      );
      i = applyFactToInstrument(i, h);
      expect(i.aliases.vpas, ['ravi@okaxis']);
    });

    test('other hints add no alias', () {
      final i = applyFactToInstrument(card(), hint('card_issued', at: '2026-11-01T08:00:00Z'));
      expect(i.aliases.productNames, isEmpty);
      expect(i.aliases.vpas, isEmpty);
    });
  });

  group('bookkeeping on every fact', () {
    test('lastSeenAt moves forward, evidenceCount counts', () {
      var i = card();
      i = applyFactToInstrument(i, movement(at: '2026-11-03T10:00:00Z'));
      i = applyFactToInstrument(i, movement(at: '2026-11-05T10:00:00Z'));
      i = applyFactToInstrument(i, movement(at: '2026-11-04T10:00:00Z'));
      expect(i.evidenceCount, 3);
      expect(i.lastSeenAt, _d('2026-11-05T10:00:00Z'));
    });

    test('firstSeenAt moves back for an older fact', () {
      final i = applyFactToInstrument(card(), movement(at: '2026-10-01T10:00:00Z'));
      expect(i.firstSeenAt, _d('2026-10-01T10:00:00Z'));
    });

    test('is pure: the input instrument is unchanged', () {
      final before = card();
      final snapshot = before.toJson();
      applyFactToInstrument(before, balance('available_credit', 5, asOf: '2026-11-01T10:00:00Z'));
      expect(before.toJson(), snapshot);
    });

    test('the sender brand is added once as an alias', () {
      var i = applyFactToInstrument(
        card(),
        movement(at: '2026-11-01T10:00:00Z'),
        senderBrand: 'HDFCBK',
      );
      i = applyFactToInstrument(i, movement(at: '2026-11-02T10:00:00Z'), senderBrand: 'HDFCBK');
      i = applyFactToInstrument(i, movement(at: '2026-11-03T10:00:00Z'), senderBrand: 'HDFCCC');
      expect(i.aliases.senders, ['HDFCBK', 'HDFCCC']);
    });

    test('the result is a valid contract instrument', () {
      final i = applyFactToInstrument(
        card(),
        balance('available_credit', 5, asOf: '2026-11-01T10:00:00Z'),
      );
      expect(i.validate().ok, isTrue, reason: '${i.validate().errors}');
    });
  });
}
