// Lane S: the linker's result does not depend on how the same facts are cut
// into batches, or on the order the batches arrive in. Synthetic facts only.
import 'dart:math';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart';

String _t(DateTime base, num hours) =>
    base.add(Duration(minutes: (hours * 60).round())).toIso8601String();

/// Several IPO applications of different issues on one account, with
/// overlapping windows (allotment, release, partial allotment, still open,
/// an application whose release arrives with no issue name), plus the other
/// families the linker knows.
///
/// With [hard] the corpus also holds two matches that only the whole picture
/// can settle: a second application of the same issue with a larger amount
/// (an allotment of the first also "fits" the second hold), and a release
/// that prints no issue (it fits every larger hold). One batch decides them
/// with every hold in view; a fact arriving before the hold that settles it
/// cannot know, and links to what it has; and a partial allotment, whose
/// debit and release can both arrive before the hold (the hold then joins the
/// debit's event and the release keeps its own). They are tested in batches
/// only.
List<Fact> corpus({int seed = 1, bool hard = true}) {
  final rnd = Random(seed);
  final base = DateTime.utc(2026, 10, 1, 4);
  final out = <Fact>[];
  // IPO applications: unique issue and amount per application.
  for (var k = 0; k < 8; k++) {
    final issue = 'ISSUE${String.fromCharCode(65 + k)} LTD';
    final amount = 1000000 + k * 25000;
    final t0 = rnd.nextInt(60) / 4;
    out.add(
      hold('placed', amount, at: _t(base, t0), inst: hdfcAcct, issue: issue),
    );
    // A partial allotment (debit and release) is a hard case: see [hard].
    switch (!hard && k % 4 == 2 ? 0 : k % 4) {
      case 0:
        out.add(
          debit(
            'investment',
            amount,
            at: _t(base, t0 + 30 + rnd.nextInt(8)),
            inst: hdfcAcct,
            counterparty: party(name: 'ISSUE${String.fromCharCode(65 + k)}'),
          ),
        );
      case 1:
        out.add(
          hold(
            'released',
            amount,
            at: _t(base, t0 + 31 + rnd.nextInt(8)),
            inst: hdfcAcct,
            issue: hard && k == 1 ? null : issue,
          ),
        );
      case 2:
        final part = amount ~/ 4;
        final when = t0 + 30 + rnd.nextInt(8);
        out.add(
          debit(
            'investment',
            part,
            at: _t(base, when),
            inst: hdfcAcct,
            counterparty: party(name: 'ISSUE${String.fromCharCode(65 + k)}'),
          ),
        );
        out.add(
          hold(
            'released',
            amount - part,
            at: _t(base, when + 0.5),
            inst: hdfcAcct,
            issue: issue,
          ),
        );
      default:
        break; // still open
    }
  }
  // A second application of the same issue and account, with its own amount.
  if (hard) {
    out.add(
      hold(
        'placed',
        1260000,
        at: _t(base, 3),
        inst: hdfcAcct,
        issue: 'ISSUEA LTD',
      ),
    );
    out.add(
      hold(
        'released',
        1260000,
        at: _t(base, 36),
        inst: hdfcAcct,
        issue: 'ISSUEA LTD',
      ),
    );
  }

  // Card bills, both orders.
  for (var k = 0; k < 4; k++) {
    final amount = 2000000 + k * 10000;
    final at = rnd.nextInt(200);
    final d = debit(
      'card_payment',
      amount,
      at: _t(base, at),
      inst: hdfcAcct,
      counterparty: party(kind: 'own', mask: '5678'),
    );
    final c = credit(
      'card_payment',
      amount,
      at: _t(base, at + 0.03 * (k.isEven ? 1 : -1)),
      inst: hdfcCard,
    );
    out.addAll([d, c]);
  }
  // Wallet top-up and spend.
  out.add(
    debit(
      'wallet_topup',
      50000,
      at: _t(base, 100),
      inst: hdfcCard,
      counterparty: party(vpa: 'addmoney@paytm'),
    ),
  );
  out.add(
    credit('wallet_topup', 50000, at: _t(base, 100.02), inst: paytmWallet),
  );
  // Purchases with a duplicate notice and a receipt, a refund.
  final shop = debit(
    'purchase',
    123400,
    at: _t(base, 120),
    inst: hdfcCard,
    counterparty: party(name: 'CAFE ONE'),
  );
  out.add(shop);
  out.add(
    debit(
      'purchase',
      123400,
      at: _t(base, 120.05),
      inst: hdfcCard,
      counterparty: party(vpa: 'cafe@upi'),
      ruleId: 'SYN-APP',
    ),
  );
  out.add(
    debit(
      'purchase',
      88000,
      at: _t(base, 140),
      inst: hdfcCard,
      counterparty: party(name: 'BOOK SHOP'),
    ),
  );
  out.add(
    debit(
      'purchase',
      88000,
      at: _t(base, 140.5),
      counterparty: party(name: 'BOOK SHOP'),
      evidenceOnly: true,
    ),
  );
  out.add(
    credit(
      'refund',
      88000,
      at: _t(base, 400),
      inst: hdfcCard,
      counterparty: party(name: 'BOOK SHOP'),
    ),
  );
  // A subscription: mandate then two charges.
  out.add(
    mandate(
      'created',
      at: _t(base, 50),
      merchant: 'STREAMCO',
      ceiling: 99900,
      inst: hdfcCard,
    ),
  );
  for (var m = 0; m < 2; m++) {
    out.add(
      debit(
        'purchase',
        49900,
        at: _t(base, 200 + m * 720),
        inst: hdfcCard,
        counterparty: party(name: 'STREAMCO'),
      ),
    );
  }
  // Own transfer and a payout.
  out.add(
    debit(
      'transfer',
      700000,
      at: _t(base, 150),
      inst: hdfcAcct,
      counterparty: party(kind: 'own', mask: '9999'),
    ),
  );
  out.add(credit('transfer', 700000, at: _t(base, 150.02), inst: hdfcSaving));
  out.add(credit('investment', 410000, at: _t(base, 160), inst: hdfcAcct));
  return out;
}

String _label(Map<String, int> index, Fact f) => '#${index[f.factId]}';

/// The events as a sorted list that ignores event ids: type, status, amount
/// and the (role, fact) pairs.
List<String> canon(Iterable<Event> events, List<Fact> facts) {
  final index = {for (var i = 0; i < facts.length; i++) facts[i].factId: i};
  final byId = {for (final f in facts) f.factId: f};
  return [
    for (final e in events)
      '${e.type.wire}|${e.status.wire}|${e.amountMinor}|'
          '${([for (final l in e.legs) '${l.role.wire}:${_label(index, byId[l.factId]!)}'])..sort()}',
  ]..sort();
}

/// The review ids raised for ambiguity: which facts were ambiguous.
List<String> ambiguousOf(Iterable<ReviewItem> reviews, List<Fact> facts) {
  final index = {for (var i = 0; i < facts.length; i++) facts[i].factId: i};
  return [
    for (final r in reviews)
      // A receipt-without-payment review depends on the clock, not on links.
      if (r.payload['reason'] == 'ambiguous_link')
        '${r.payload['reason']}:${index[r.payload['factId']]}',
  ]..sort();
}

/// Links [chunks] in order, as the pipeline does: each call sees every fact
/// seen before and the stored events.
({MemoryEvents store, List<ReviewItem> reviews}) run(List<List<Fact>> chunks) {
  final store = MemoryEvents();
  final seen = <Fact>[];
  final reviews = <String, ReviewItem>{};
  for (final chunk in chunks) {
    seen.addAll(
      chunk,
    ); // the pipeline's clock is the newest message it has seen
    final now = seen
        .map((f) => f.observedAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    seen.removeRange(seen.length - chunk.length, seen.length);
    final r = testLinker(now: now).link(
      incoming: chunk,
      context: RuleLinkContext(
        recentFacts: [...seen],
        openEvents: store.open,
        instrumentsById: allInstruments,
        knownEvents: store.all,
      ),
      rules: baselineLinkRules(),
    );
    store.apply(r);
    seen.addAll(chunk);
    for (final x in r.ambiguous) {
      reviews[x.payload['reviewId'] as String] = x;
    }
  }
  return (store: store, reviews: reviews.values.toList());
}

List<List<Fact>> rechunk(List<Fact> ordered, Random rnd, int maxSize) {
  final out = <List<Fact>>[];
  var i = 0;
  while (i < ordered.length) {
    final n = 1 + rnd.nextInt(maxSize);
    out.add(ordered.sublist(i, min(ordered.length, i + n)));
    i += n;
  }
  return out;
}

void main() {
  for (final seed in [1, 2, 3]) {
    final facts = corpus(seed: seed);
    final timeOrder = [...facts]
      ..sort((a, b) {
        final c = a.effectiveAt.compareTo(b.effectiveAt);
        return c != 0 ? c : a.factId.compareTo(b.factId);
      });
    final batch = run([facts]);
    final expected = canon(batch.store.all, facts);
    final expectedAmbiguous = ambiguousOf(batch.reviews, facts);

    group('seed $seed', () {
      test('the corpus links IPO applications and has no double counts', () {
        final ipo = batch.store.all
            .where((e) => e.type == EventType.ipoApplication)
            .toList();
        expect(ipo.length, greaterThanOrEqualTo(9));
        expect(ipo.where((e) => e.status == EventStatus.ambiguous), isEmpty);
        expect(
          doubleCounted(batch.store.all, {for (final f in facts) f.factId: f}),
          isEmpty,
        );
      });

      test('one at a time in time order equals one batch, ids included', () {
        final seq = run([
          for (final f in timeOrder) [f],
        ]);
        expect(canon(seq.store.all, facts), expected);
        expect(ambiguousOf(seq.reviews, facts), expectedAmbiguous);
        expect(
          {for (final e in seq.store.all) e.eventId},
          {for (final e in batch.store.all) e.eventId},
        );
      });

      test('the same facts re-chunked in time order give the same events', () {
        for (var k = 0; k < 12; k++) {
          final chunks = rechunk(timeOrder, Random(seed * 100 + k), 1 + k * 2);
          final r = run(chunks);
          expect(
            canon(r.store.all, facts),
            expected,
            reason: 'chunks of up to ${1 + k * 2}',
          );
          expect(ambiguousOf(r.reviews, facts), expectedAmbiguous);
        }
      });

      test('a shuffled batch gives the same events', () {
        for (var k = 0; k < 10; k++) {
          final shuffled = [...facts]..shuffle(Random(seed * 1000 + k));
          final r = run([shuffled]);
          expect(canon(r.store.all, facts), expected);
        }
      });

      // Arrival order: every match here is settled by the facts that make it.
      final clean = corpus(seed: seed, hard: false);
      final cleanExpected = canon(run([clean]).store.all, clean);

      test('shuffled facts one at a time give the same events', () {
        for (var k = 0; k < 10; k++) {
          final shuffled = [...clean]..shuffle(Random(seed * 2000 + k));
          final r = run([
            for (final f in shuffled) [f],
          ]);
          expect(
            canon(r.store.all, clean),
            cleanExpected,
            reason: 'shuffle $k',
          );
          expect(ambiguousOf(r.reviews, clean), isEmpty);
        }
      });

      test('shuffled facts in random chunks give the same events', () {
        for (var k = 0; k < 10; k++) {
          final shuffled = [...clean]..shuffle(Random(seed * 3000 + k));
          final r = run(rechunk(shuffled, Random(seed * 4000 + k), 3 + k));
          expect(
            canon(r.store.all, clean),
            cleanExpected,
            reason: 'shuffle $k',
          );
          expect(ambiguousOf(r.reviews, clean), isEmpty);
        }
      });
    });
  }
}
