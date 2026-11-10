// Lane X: a bill-payment receipt with no funding debit.
//
// Earlier month: skipped silently. Current month, after the wait: one review
// item. A funding debit (before or after) joins the receipt and nothing is
// asked. Every test pins "now" with the linker's injectable clock.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// 12 Nov 2026, 12:00 IST.
final _now = DateTime.utc(2026, 11, 12, 6, 30);

MovementFact _receipt(
  String at, {
  int minor = 125000,
  String app = 'YES Bank',
  String? sourceKey,
}) => debit(
  'card_payment',
  minor,
  at: at,
  counterparty: party(name: app, kind: 'own', mask: '9876'),
  evidenceOnly: true,
  sourceKey: sourceKey,
);

MovementFact _funding(String at, {int minor = 125000}) => debit(
  'card_payment',
  minor,
  at: at,
  inst: hdfcAcct,
  counterparty: party(name: 'YES Bank', kind: 'own', mask: '9876'),
);

/// Links [facts] in order, one call each (like live capture), then asks the
/// receipt question at [now].
({LinkResult link, LinkResult review, List<Event> events}) _run(
  List<Fact> facts, {
  DateTime? now,
  Set<String> alreadyRaised = const {},
}) {
  final linker = testLinker(now: now ?? _now);
  final rules = baselineLinkRules();
  final store = MemoryEvents();
  final seen = <Fact>[];
  var last = const LinkResult(created: [], updated: [], ambiguous: []);
  for (final f in facts) {
    last = linker.link(
      incoming: [f],
      context: RuleLinkContext(
        recentFacts: List.of(seen),
        openEvents: store.open,
        instrumentsById: allInstruments,
        knownEvents: store.all,
      ),
      rules: rules,
    );
    store.apply(last);
    seen.add(f);
  }
  final review = linker.reviewReceipts(
    now: now ?? _now,
    context: RuleLinkContext(
      recentFacts: seen,
      openEvents: store.open,
      instrumentsById: allInstruments,
      knownEvents: store.all,
    ),
    rules: rules,
    alreadyRaised: alreadyRaised,
  );
  return (link: last, review: review, events: store.all);
}

int _moneyOf(Iterable<Event> events, Iterable<Fact> facts) {
  final byId = {for (final f in facts) f.factId: f};
  final projector = DefaultLedgerProjector();
  return events
      .expand((e) => projector.project(e, byId, allInstruments, null))
      .fold(0, (s, r) => s + r.amountMinor);
}

void main() {
  group('policy constants', () {
    test('the wait is 3 days and matches the LINK-RECEIPT window', () {
      expect(kReceiptWaitPeriod, const Duration(days: 3));
      final rule = baselineLinkRules().firstWhere(
        (r) => r.id == 'LINK-RECEIPT',
      );
      expect(rule.join.windowHours, kReceiptWaitPeriod.inHours);
    });

    test('the calendar month is read in IST (UTC+5:30)', () {
      expect(kIstUtcOffset, const Duration(hours: 5, minutes: 30));
      final now = DateTime.utc(2026, 11, 12);
      // 1 Nov 00:30 IST is still 31 Oct 19:00 UTC: November.
      expect(
        isEarlierCalendarMonthIst(DateTime.utc(2026, 10, 31, 19), now),
        isFalse,
      );
      // 31 Oct 23:30 IST: October.
      expect(
        isEarlierCalendarMonthIst(DateTime.utc(2026, 10, 31, 18), now),
        isTrue,
      );
      // 'now' on 1 Dec 00:30 IST (30 Nov 19:00 UTC): a November receipt is old.
      expect(
        isEarlierCalendarMonthIst(
          DateTime.utc(2026, 11, 20),
          DateTime.utc(2026, 11, 30, 19),
        ),
        isTrue,
      );
      expect(istMonthStart(now), DateTime.utc(2026, 10, 31, 18, 30));
    });

    test('disposition: wait, skip an old month, or review', () {
      final receiptAt = DateTime.utc(2026, 11, 5, 10);
      expect(
        receiptDisposition(
          receiptAt: receiptAt,
          now: receiptAt.add(const Duration(days: 3)),
        ),
        ReceiptDisposition.wait,
      );
      expect(
        receiptDisposition(
          receiptAt: receiptAt,
          now: receiptAt.add(const Duration(days: 3, minutes: 1)),
        ),
        ReceiptDisposition.review,
      );
      expect(
        receiptDisposition(
          receiptAt: DateTime.utc(2026, 10, 5),
          now: DateTime.utc(2026, 11, 12),
        ),
        ReceiptDisposition.skipOldMonth,
      );
      // A custom wait is injectable too.
      expect(
        receiptDisposition(
          receiptAt: receiptAt,
          now: receiptAt.add(const Duration(days: 1)),
          wait: const Duration(hours: 1),
        ),
        ReceiptDisposition.review,
      );
    });

    test('confirmed card bill receipts are card payments, never spending', () {
      expect(
        receiptConfirmedEventType(_receipt('2026-11-05T10:00:00Z')),
        EventType.cardBillPayment,
      );
    });
  });

  group('wording', () {
    test('one localisable constant set', () {
      expect(receiptReviewText('en'), same(kReceiptReviewTextEn));
      expect(receiptReviewText('en_IN'), same(kReceiptReviewTextEn));
      expect(receiptReviewText('xx'), same(kReceiptReviewTextEn));
      expect(kReceiptReviewTexts.keys, contains('en'));
      final t = kReceiptReviewTextEn;
      expect(t.yes, 'Yes, I paid it');
      expect(t.no, 'No, someone else paid it');
      expect(t.notSure, 'Not sure');
      expect(
        t.question(
          cardBill: true,
          amount: formatReceiptRupees(125000),
          date: formatReceiptDate(DateTime.utc(2026, 11, 5, 10)),
          app: 'Bill App',
        ),
        'Did you pay this bill? We found a receipt for a credit card bill '
        'payment of ₹1,250 on 5 Nov 2026 through Bill App, but no matching '
        'debit in your messages. Was this paid from one of your accounts?',
      );
    });

    test('rupee and date formats', () {
      expect(formatReceiptRupees(89900), '₹899');
      expect(formatReceiptRupees(89950), '₹899.50');
      expect(formatReceiptRupees(12500000), '₹1,25,000');
      expect(formatReceiptRupees(123456700), '₹12,34,567');
      // 31 Oct 19:00 UTC is 1 Nov in IST.
      expect(formatReceiptDate(DateTime.utc(2026, 10, 31, 19)), '1 Nov 2026');
    });
  });

  group('receipt with no funding debit', () {
    test('alone in an old month: skipped, no review, no event, no money', () {
      final r = _receipt('2026-10-20T10:00:00Z');
      final out = _run([r]);
      expect(out.events, isEmpty);
      expect(out.review.ambiguous, isEmpty);
      expect(out.link.ambiguous, isEmpty);
      expect(_moneyOf(out.events, [r]), 0);
    });

    test('alone in the current month: one review item, no money', () {
      final r = _receipt('2026-11-05T10:00:00Z');
      final out = _run([r]);
      expect(out.events, isEmpty);
      expect(_moneyOf(out.events, [r]), 0);
      final item = out.review.ambiguous.single;
      expect(item.kind, ReviewKind.event);
      expect(item.payload['reason'], 'receipt_without_payment');
      expect(item.payload['reviewId'], 'link:receipt:${r.factId}');
      expect(item.payload['factId'], r.factId);
      expect(item.payload['amountMinor'], 125000);
      expect(item.payload['cardBill'], isTrue);
      expect(
        item.payload['message'],
        'Did you pay this bill? We found a receipt for a credit card bill '
        'payment of ₹1,250 on 5 Nov 2026 through YES Bank, but no matching '
        'debit in your messages. Was this paid from one of your accounts?',
      );
    });

    test('inside the 3 day wait nothing is asked', () {
      final r = _receipt('2026-11-10T10:00:00Z');
      expect(_run([r]).review.ambiguous, isEmpty);
      // Exactly at the boundary still waits; a minute later asks.
      final edge = _run([r], now: DateTime.utc(2026, 11, 13, 10));
      expect(edge.review.ambiguous, isEmpty);
      final after = _run([r], now: DateTime.utc(2026, 11, 13, 10, 1));
      expect(after.review.ambiguous, hasLength(1));
    });

    test('a receipt from last month is skipped the day the month turns', () {
      final r = _receipt('2026-11-28T10:00:00Z');
      // 3 Dec: more than 3 days later, but November is now an earlier month.
      final out = _run([r], now: DateTime.utc(2026, 12, 3, 6));
      expect(out.review.ambiguous, isEmpty);
      // On 1 Dec 00:30 IST the same receipt is already an old one.
      expect(
        _run([r], now: DateTime.utc(2026, 11, 30, 19)).review.ambiguous,
        isEmpty,
      );
    });

    test('link() itself never raises the question', () {
      final r = _receipt('2026-11-05T10:00:00Z');
      expect(linkAll([r], linker: testLinker(now: _now)).ambiguous, isEmpty);
    });
  });

  group('receipt and funding debit', () {
    test('receipt then debit: one card payment, no review', () {
      final receipt = _receipt('2026-11-05T10:00:00Z');
      final pay = _funding('2026-11-05T10:03:00Z');
      final out = _run([receipt, pay]);
      expect(out.review.ambiguous, isEmpty);
      final events = out.events.where((e) => e.type != EventType.unknown);
      expect(events, hasLength(1));
      expect(events.single.type, EventType.cardBillPayment);
      expect(shape(events.single), contains('duplicate_notice'));
      expect(_moneyOf(out.events, [receipt, pay]), 125000);
      expect(
        doubleCounted(out.events, {receipt.factId: receipt, pay.factId: pay}),
        isEmpty,
      );
    });

    test('debit then receipt: one card payment, no review', () {
      final receipt = _receipt('2026-11-05T10:03:00Z');
      final pay = _funding('2026-11-05T10:00:00Z');
      final out = _run([pay, receipt]);
      expect(out.review.ambiguous, isEmpty);
      expect(out.events, hasLength(1));
      expect(out.events.single.type, EventType.cardBillPayment);
      expect(_moneyOf(out.events, [receipt, pay]), 125000);
    });

    test('a debit the receipt cannot join still means the money is seen', () {
      // The debit sits in an event the linker may not extend (here: its own
      // stored, user-confirmed event). The payment is not missing.
      final receipt = _receipt('2026-11-05T10:00:00Z');
      final pay = _funding('2026-11-05T10:03:00Z');
      final out = _run([pay, receipt]);
      final confirmed = out.events.single.copyWith(
        status: EventStatus.userConfirmed,
      );
      final again = testLinker(now: _now).reviewReceipts(
        now: _now,
        context: RuleLinkContext(
          recentFacts: [pay, receipt],
          openEvents: const [],
          instrumentsById: allInstruments,
          knownEvents: [
            confirmed.copyWith(
              legs: [
                for (final l in confirmed.legs)
                  if (l.factId != receipt.factId) l,
              ],
            ),
          ],
        ),
        rules: baselineLinkRules(),
      );
      expect(again.ambiguous, isEmpty);
    });

    test('a debit for a different amount does not satisfy the receipt', () {
      final receipt = _receipt('2026-11-05T10:00:00Z');
      final other = _funding('2026-11-05T10:03:00Z', minor: 99900);
      final out = _run([receipt, other]);
      expect(out.review.ambiguous, hasLength(1));
    });
  });

  group('no duplicate review items', () {
    test('re-processing the same receipt asks once', () {
      final r = _receipt('2026-11-05T10:00:00Z');
      final first = _run([r]).review.ambiguous.single;
      final ids = {
        first.payload['reviewId']! as String,
        first.payload['dedupeKey']! as String,
      };
      // The same facts again, with what is already raised remembered.
      expect(_run([r], alreadyRaised: ids).review.ambiguous, isEmpty);
      // And the same call twice raises the same id.
      final second = _run([r]).review.ambiguous.single;
      expect(second.payload['reviewId'], first.payload['reviewId']);
    });

    test('a receipt that arrives again (a second message) asks once', () {
      final a = _receipt('2026-11-05T10:00:00Z', sourceKey: 'sms:a');
      final b = _receipt('2026-11-05T10:20:00Z', sourceKey: 'sms:b');
      final out = _run([a, b]);
      final item = out.review.ambiguous.single;
      expect(item.payload['factId'], a.factId); // the earlier one
      // Remembering only the dedupe key keeps a late duplicate quiet too.
      final later = _run(
        [b],
        alreadyRaised: {item.payload['dedupeKey']! as String},
      );
      expect(later.review.ambiguous, isEmpty);
    });

    test('two real payments of different amounts are two questions', () {
      final a = _receipt('2026-11-05T10:00:00Z');
      final b = _receipt('2026-11-06T10:00:00Z', minor: 330000);
      expect(_run([a, b]).review.ambiguous, hasLength(2));
    });

    test('a receipt under an ambiguity review is not asked about again', () {
      final r = _receipt('2026-11-05T10:00:00Z');
      final out = _run([r], alreadyRaised: {'link:ambiguous:${r.factId}'});
      expect(out.review.ambiguous, isEmpty);
    });
  });

  group('after the user confirms', () {
    test('a funding debit that arrives later is the same payment', () {
      final receipt = _receipt('2026-11-05T10:00:00Z');
      // What "Yes, I paid it" stores: a user fact that counts, in a confirmed
      // event that also holds the receipt as a duplicate notice.
      final user = Fact.fromJson({
        ...receipt.toJson(),
        'factId': hex64('user|${receipt.factId}'),
        'sourceKey': 'correction:receipt:${receipt.factId}',
        'attrs': {
          ...(receipt.toJson()['attrs']! as Map).cast<String, Object?>(),
          'evidenceOnly': false,
        },
        'provenance': {
          ...receipt.provenance.toJson(),
          'engine': 'user',
          'ruleId': kReceiptConfirmedRuleId,
        },
      });
      final confirmed = Event(
        eventId: user.factId,
        type: EventType.cardBillPayment,
        status: EventStatus.userConfirmed,
        legs: [
          EventLeg(factId: user.factId, role: LegRole.debitLeg),
          EventLeg(factId: receipt.factId, role: LegRole.duplicateNotice),
        ],
        linkRuleId: 'LINK-RECEIPT',
        confidence: 1,
        occurredAt: receipt.effectiveAt,
        amountMinor: 125000,
      );
      final late = _funding('2026-11-08T09:00:00Z');
      final r = testLinker(now: _now).link(
        incoming: [late],
        context: RuleLinkContext(
          recentFacts: [receipt, user],
          openEvents: const [],
          instrumentsById: allInstruments,
          knownEvents: [confirmed],
        ),
        rules: baselineLinkRules(),
      );
      final created = eventsOf(r).single;
      expect(created.eventId, late.factId);
      expect(created.type, EventType.unknown);
      expect(
        _moneyOf([confirmed, ...eventsOf(r)], [receipt, user, late]),
        125000,
      );
    });
  });

  group('history replay', () {
    test('20,000 messages with many old receipts do not flood the user', () {
      // Eleven months of old receipts, plus a handful in the current month.
      final facts = <Fact>[];
      var i = 0;
      while (facts.length < 20000) {
        final day = DateTime.utc(2026, 1, 1).add(Duration(hours: 5 * i));
        final stamp = day.toIso8601String();
        if (i % 4 == 0) {
          facts.add(
            _receipt(stamp, minor: 100000 + i, sourceKey: 'sms:history:$i'),
          );
        } else {
          facts.add(
            debit(
              'purchase',
              5000 + i,
              at: stamp,
              inst: hdfcCard,
              counterparty: party(name: 'SHOP${i % 40}'),
            ),
          );
        }
        i++;
      }
      // Real "now" is the end of the replayed window.
      final now = facts
          .map((f) => f.observedAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final linker = testLinker(now: now);
      final rules = baselineLinkRules();
      final link = linker.link(
        incoming: facts,
        context: RuleLinkContext(
          recentFacts: const [],
          openEvents: const [],
          instrumentsById: allInstruments,
        ),
        rules: rules,
      );
      expect(link.ambiguous, isEmpty);
      final review = linker.reviewReceipts(
        now: now,
        context: RuleLinkContext(
          recentFacts: facts,
          openEvents: const [],
          instrumentsById: allInstruments,
          knownEvents: eventsOf(link),
        ),
        rules: rules,
      );
      final inMonth = facts.whereType<MovementFact>().where(
        (f) =>
            f.evidenceOnly == true &&
            !isEarlierCalendarMonthIst(f.effectiveAt, now) &&
            now.difference(f.effectiveAt) > kReceiptWaitPeriod,
      );
      expect(review.ambiguous.length, inMonth.length);
      // Only the newest month can ask; no more than one a receipt.
      expect(review.ambiguous.length, lessThan(40));
      for (final item in review.ambiguous) {
        expect(
          DateTime.parse(
            item.payload['receiptAt']! as String,
          ).isBefore(istMonthStart(now)),
          isFalse,
        );
      }
      // No money from any receipt.
      expect(
        eventsOf(link)
            .expand((e) => e.legs)
            .where((l) => moneyLegRoles.contains(l.role))
            .map((l) => facts.firstWhere((f) => f.factId == l.factId))
            .whereType<MovementFact>()
            .where((f) => f.evidenceOnly == true),
        isEmpty,
      );
    });
  });

  group('the same amount paid again and again', () {
    // Each payment sends a notice with its own reference and a debit alert.
    MovementFact notice(String at, String utr, {int minor = 40000000}) => debit(
      'p2p',
      minor,
      at: at,
      evidenceOnly: true,
      references: {'neftUtr': utr},
      sourceKey: 'notice-$utr',
    );
    MovementFact alert(String at, {int minor = 40000000}) =>
        debit('p2p', minor, at: at, inst: hdfcAcct, sourceKey: 'alert-$at');

    int noticesOn(Event e, Map<String, Fact> byId) => e.legs
        .where(
          (l) =>
              l.role == LegRole.duplicateNotice &&
              (byId[l.factId] as MovementFact).evidenceOnly == true,
        )
        .length;

    test('three payments on three days: three events, one notice each, counted three times', () {
      final facts = <Fact>[
        notice('2026-11-03T05:00:00Z', 'U1'),
        alert('2026-11-03T05:01:00Z'),
        notice('2026-11-04T05:00:00Z', 'U2'),
        alert('2026-11-04T05:01:00Z'),
        notice('2026-11-05T05:00:00Z', 'U3'),
        alert('2026-11-05T05:01:00Z'),
      ];
      final r = _run(facts);
      final byId = {for (final f in facts) f.factId: f};
      expect(r.events, hasLength(3));
      for (final e in r.events) {
        expect(noticesOn(e, byId), 1);
      }
      expect(_moneyOf(r.events, facts), 3 * 40000000);
      expect(r.review.ambiguous, isEmpty);
    });

    test('all three notices first, then the three alerts: still one notice each', () {
      final facts = <Fact>[
        notice('2026-11-03T05:00:00Z', 'U1'),
        notice('2026-11-04T05:00:00Z', 'U2'),
        notice('2026-11-05T05:00:00Z', 'U3'),
        alert('2026-11-03T05:01:00Z'),
        alert('2026-11-04T05:01:00Z'),
        alert('2026-11-05T05:01:00Z'),
      ];
      final r = _run(facts);
      final byId = {for (final f in facts) f.factId: f};
      expect(r.events, hasLength(3));
      expect(r.events.map((e) => noticesOn(e, byId)), everyElement(1));
      expect(_moneyOf(r.events, facts), 3 * 40000000);
    });

    test('two notices with the same reference are one payment told twice', () {
      final facts = <Fact>[
        alert('2026-11-03T05:01:00Z'),
        notice('2026-11-03T05:02:00Z', 'U1'),
        notice('2026-11-03T05:03:00Z', 'U1'),
      ];
      final r = _run(facts);
      final byId = {for (final f in facts) f.factId: f};
      expect(r.events, hasLength(1));
      expect(noticesOn(r.events.single, byId), 2);
      expect(_moneyOf(r.events, facts), 40000000);
    });

    test('a notice for a payment whose alert never came does not hide behind the first payment', () {
      final facts = <Fact>[
        notice('2026-11-03T05:00:00Z', 'U1'),
        alert('2026-11-03T05:01:00Z'),
        notice('2026-11-04T05:00:00Z', 'U2'), // its alert is missing
      ];
      final r = _run(facts, now: DateTime.utc(2026, 11, 12, 6, 30));
      final byId = {for (final f in facts) f.factId: f};
      expect(r.events, hasLength(1));
      expect(noticesOn(r.events.single, byId), 1);
      // The unpaid second notice is from this month and old enough: one question, no money.
      expect(r.review.ambiguous, hasLength(1));
      expect(_moneyOf(r.events, facts), 40000000);
    });
  });
}
