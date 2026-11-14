import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay_domain/sms_v2.dart';

import 'adapters_test.dart' show fixture;

/// Lane V read-model checks that need shapes the golden scenarios cannot
/// produce (broker rails, month-boundary salary, reused mandate names).
String _id(int n) => n.toRadixString(16).padLeft(64, '0');

Fact movement(
  int n,
  String at, {
  required int minor,
  required String direction,
  String purpose = 'transfer',
  String? payer,
  String payerKind = 'merchant',
  Map<String, Object?>? instrument,
}) => fixture(
  'movement.upi_salary_credit',
  changes: {
    'factId': _id(n),
    'sourceKey': 'sms:lane-v:$n',
    'observedAt': at,
    'occurredAt': at,
    'counterparty': payer == null
        ? null
        : {'name': payer, 'vpa': null, 'kind': payerKind, 'accountMask': null},
    'amounts': [
      {'role': 'posted', 'minor': minor, 'unit': 'INR'},
    ],
    'attrs': {'direction': direction, 'purpose': purpose, 'rail': 'neft'},
    'instrument': ?instrument,
  },
);

Event event(
  Fact f,
  EventType type, {
  LegRole role = LegRole.creditLeg,
  List<EventLeg> extra = const [],
}) => Event(
  eventId: f.factId,
  type: type,
  status: EventStatus.complete,
  legs: [EventLeg(factId: f.factId, role: role), ...extra],
  confidence: .99,
  occurredAt: f.effectiveAt,
  amountMinor: f.amounts.first.minor,
);

Instrument broker(String slug, {int? balance}) => Instrument(
  instrumentId: '00000000-0000-4000-8000-0000000000${slug.length}1',
  kind: InstrumentKind.broker,
  issuerSlug: slug,
  status: InstrumentStatus.confirmed,
  displayName: slug,
  firstSeenAt: DateTime.utc(2026),
  lastSeenAt: DateTime.utc(2026),
  evidenceCount: 1,
  availableMinor: balance,
);

void main() {
  final from = DateTime.utc(2026), to = DateTime.utc(2028);

  group('Money in salary detection', () {
    test('repeated payer is salary across an Indian month boundary', () {
      // 1 Nov and 2 Dec in India; the UTC months are October and December.
      final a = movement(
        1,
        '2026-10-31T18:30:00Z',
        minor: 6000000,
        direction: 'credit',
        payer: 'GLOBEX LTD',
      );
      final b = movement(
        2,
        '2026-12-01T18:30:00Z',
        minor: 6000000,
        direction: 'credit',
        payer: 'GLOBEX LTD',
      );
      final rows = moneyIn(
        [a, b],
        [event(a, EventType.income), event(b, EventType.income)],
        from,
        to,
      );
      expect(rows.map((r) => r.kind), ['salary', 'salary']);
    });

    test('month-end then early-month pay is within seven days', () {
      final a = movement(
        1,
        '2026-10-29T10:00:00Z',
        minor: 5000000,
        direction: 'credit',
        payer: 'GLOBEX LTD',
      );
      final b = movement(
        2,
        '2026-12-03T10:00:00Z',
        minor: 5000000,
        direction: 'credit',
        payer: 'GLOBEX LTD',
      );
      final mid = movement(
        3,
        '2026-11-30T10:00:00Z',
        minor: 5000000,
        direction: 'credit',
        payer: 'GLOBEX LTD',
      );
      final rows = moneyIn(
        [a, mid, b],
        [
          event(a, EventType.income),
          event(mid, EventType.income),
          event(b, EventType.income),
        ],
        from,
        to,
      );
      expect(rows.every((r) => r.kind == 'salary'), isTrue);
    });

    test('credits with no named payer are never grouped into salary', () {
      final a = movement(
        1,
        '2026-10-05T00:00:00Z',
        minor: 100000,
        direction: 'credit',
      );
      final b = movement(
        2,
        '2026-11-05T00:00:00Z',
        minor: 100000,
        direction: 'credit',
      );
      final rows = moneyIn(
        [a, b],
        [event(a, EventType.income), event(b, EventType.income)],
        from,
        to,
      );
      expect(rows.map((r) => r.kind), isNot(contains('salary')));
      expect(rows.map((r) => r.payer), everyElement('Unknown payer'));
    });

    test('salary the alert gave no employer for is still salary, named so', () {
      final a = movement(
        1,
        '2026-11-05T00:00:00Z',
        minor: 7000000,
        direction: 'credit',
        purpose: 'salary',
      );
      final rows = moneyIn([a], [event(a, EventType.income)], from, to);
      expect(rows.single.kind, 'salary');
      expect(rows.single.payer, 'Salary received');
    });

    test('a bank cashback credit with no payer reads "Cashback received"', () {
      final a = movement(
        1,
        '2026-11-09T10:37:00Z',
        minor: 12900,
        direction: 'credit',
        purpose: 'cashback',
      );
      final rows = moneyIn([a], [event(a, EventType.cashback)], from, to);
      expect(rows.single.kind, 'cashback');
      expect(rows.single.payer, 'Cashback received');
    });

    test('a payer seen once is not salary until confirmed once', () {
      final a = movement(
        1,
        '2026-11-05T00:00:00Z',
        minor: 7000000,
        direction: 'credit',
        payer: 'INITECH',
      );
      final events = [event(a, EventType.income)];
      expect(moneyIn([a], events, from, to).single.kind, 'other');
      expect(
        moneyIn(
          [a],
          events,
          from,
          to,
          confirmedSalaryPayers: {'INITECH'},
        ).single.kind,
        'salary',
      );
    });
  });

  test('money in separates refunds, dividends, cashback and people', () {
    final purchase = movement(
      1,
      '2026-11-01T10:00:00Z',
      minor: 49900,
      direction: 'debit',
      purpose: 'purchase',
      payer: 'SWIGGY',
    );
    final refund = movement(
      2,
      '2026-11-03T10:00:00Z',
      minor: 49900,
      direction: 'credit',
      purpose: 'refund',
    );
    final div = movement(
      3,
      '2026-11-15T10:00:00Z',
      minor: 120000,
      direction: 'credit',
      purpose: 'dividend',
      payer: 'ACME INDUSTRIES LTD',
    );
    final cash = movement(
      4,
      '2026-11-16T10:00:00Z',
      minor: 5000,
      direction: 'credit',
      purpose: 'cashback',
      payer: 'CRED',
    );
    final friend = movement(
      5,
      '2026-11-17T10:00:00Z',
      minor: 250000,
      direction: 'credit',
      purpose: 'p2p',
      payer: 'RAVI KUMAR',
      payerKind: 'person',
    );
    final own = movement(
      6,
      '2026-11-18T10:00:00Z',
      minor: 2000000,
      direction: 'credit',
    );
    final back = movement(
      7,
      '2026-11-19T10:00:00Z',
      minor: 800000,
      direction: 'credit',
      payer: 'UPSTOX',
    );
    final rows = moneyIn(
      [purchase, refund, div, cash, friend, own, back],
      [
        event(
          refund,
          EventType.refund,
          role: LegRole.reversal,
          extra: [EventLeg(factId: purchase.factId, role: LegRole.original)],
        ),
        event(div, EventType.dividend),
        event(cash, EventType.cashback),
        event(friend, EventType.p2pIn),
        event(own, EventType.ownTransfer),
        event(back, EventType.investmentWithdrawal),
      ],
      from,
      to,
    );
    expect(rows.map((r) => r.kind).toSet(), {
      'refund',
      'dividend',
      'cashback',
      'person',
    });
    expect(rows.length, 4);
    expect(rows.firstWhere((r) => r.kind == 'refund').payer, 'SWIGGY');
    expect(rows.firstWhere((r) => r.kind == 'refund').amountMinor, 49900);
  });

  group('Investments per platform', () {
    test('put in, taken out, net, balance and dividends sit on one platform', () {
      final upstoxAccount = {
        'kind': 'broker',
        'issuerSlug': 'upstox',
        'maskDigits': null,
        'maskLength': null,
        'productName': null,
        'raw': 'upstox',
      };
      final put = movement(
        1,
        '2026-11-02T10:00:00Z',
        minor: 500000,
        direction: 'debit',
        purpose: 'investment',
        payer: 'UPSTOX SECURITIES',
      );
      final out = movement(
        2,
        '2026-11-10T10:00:00Z',
        minor: 300000,
        direction: 'credit',
        purpose: 'investment',
        payer: 'UPSTOX',
        instrument: upstoxAccount,
      );
      final div = movement(
        3,
        '2026-11-15T10:00:00Z',
        minor: 120000,
        direction: 'credit',
        purpose: 'dividend',
      );
      final rows = investmentsSummary(
        [put, out, div],
        [
          event(put, EventType.investment, role: LegRole.debitLeg),
          event(out, EventType.investmentWithdrawal),
          event(div, EventType.dividend),
        ],
        [broker('upstox', balance: 1250050)],
      );
      final upstox = rows.singleWhere((r) => r.platform.contains('UPSTOX'));
      expect(upstox.putInMinor, 500000);
      expect(upstox.takenOutMinor, 300000);
      expect(upstox.netInvestedMinor, 200000);
      expect(upstox.balanceMinor, 1250050);
      expect(rows.where((r) => r.platform.contains('UPSTOX')).length, 1);
      // A dividend paid straight to the bank is not a platform named after
      // nothing, and an IPO issuer is not a platform either.
      expect(rows.map((r) => r.platform), isNot(contains('UNKNOWN SERVICE')));
      expect(
        rows.singleWhere((r) => r.platform == 'Dividends paid to bank')
            .dividendMinor,
        120000,
      );
    });

    test('an IPO allotment is listed under IPO allotments, not the issuer', () {
      final hold = fixture('hold.ipo_placed');
      final debit = movement(
        9,
        '2026-11-30T10:00:00Z',
        minor: 1425000,
        direction: 'debit',
        purpose: 'investment',
        payer: 'SYNTH IPO LTD',
      );
      final e = Event(
        eventId: hold.factId,
        type: EventType.ipoApplication,
        status: EventStatus.complete,
        legs: [
          EventLeg(factId: hold.factId, role: LegRole.holdPlaced),
          EventLeg(factId: debit.factId, role: LegRole.debitLeg),
        ],
        confidence: 1,
        occurredAt: debit.effectiveAt,
        amountMinor: 1425000,
      );
      final rows = investmentsSummary([hold, debit], [e], const []);
      expect(rows.single.platform, 'IPO allotments');
      expect(rows.single.putInMinor, 1425000);
      final ipo = ipoApplications([hold, debit], [e]).single;
      expect(ipo.status, 'allotted');
      expect(ipo.platform, isNull, reason: 'the issuer is not the platform');
      expect(ipo.appliedAt, hold.effectiveAt);
    });
  });

  group('Subscriptions', () {
    Fact mandate(String phase, String at, {bool withInstrument = true}) =>
        fixture(
          phase == 'created' ? 'mandate.subscription_created' : 'mandate.revoked',
          changes: {
            'factId': _id(phase == 'created' ? 21 : 22),
            'sourceKey': 'sms:lane-v:m$phase',
            'observedAt': at,
            'occurredAt': at,
            'counterparty': {
              'name': 'SYNTH TUBE',
              'vpa': null,
              'kind': 'merchant',
              'accountMask': null,
            },
            if (!withInstrument) 'instrument': null,
            'attrs': {
              'phase': phase,
              if (phase == 'created') 'frequency': 'monthly',
              'merchantName': 'SYNTH TUBE',
              'oneTime': false,
              'mandatePurpose': 'subscription',
            },
            'references': {'umrn': 'SYNUMRN0002'},
          },
        );

    test('a cancellation that omits the card still ends the same service', () {
      final setup = mandate('created', '2026-05-01T08:00:00Z', withInstrument: false);
      final revoked = mandate('revoked', '2026-06-20T08:00:00Z');
      final charge = fixture(
        'movement.card_spend',
        changes: {
          'factId': _id(23),
          'sourceKey': 'sms:lane-v:charge',
          'observedAt': '2026-06-01T08:00:00Z',
          'occurredAt': '2026-06-01T08:00:00Z',
          'counterparty': {
            'name': 'SYNTH TUBE',
            'vpa': null,
            'kind': 'merchant',
            'accountMask': null,
          },
        },
      );
      final e = event(
        charge,
        EventType.subscriptionCharge,
        role: LegRole.charge,
        extra: [EventLeg(factId: setup.factId, role: LegRole.original)],
      );
      final rows = subscriptionsFromLedger(
        [setup, revoked, charge],
        [e],
        now: DateTime.utc(2026, 7),
      );
      expect(rows.length, 1, reason: rows.map((r) => r.lifecycleStatus).join());
      expect(rows.single.lifecycleStatus, 'cancelled');
      expect(rows.single.typicalAmount.paise, 49900);
    });
  });
}
