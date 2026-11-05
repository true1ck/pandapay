import '../contract/enums.dart';
import '../contract/event.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import '../contract/interfaces.dart';
import '../contract/rule_bundle.dart';
import 'link_context.dart';
import 'receipt_policy.dart';

/// What a link rule means to the matching code. Link rules only set
/// parameters (contracts: "The matching algorithm is code"); the behaviour
/// that differs per rule is chosen from the rule's event type and leg roles,
/// never from its id.
enum LinkRuleKind {
  /// `ipo_application`: hold placed, then released, converted or debited.
  ipo,

  /// `subscription_charge`: a debit to its mandate.
  mandateCharge,

  /// `card_bill_payment`: bank debit and card "payment received".
  cardBill,

  /// `wallet_topup`: bank or card debit and the wallet credit.
  walletTopup,

  /// `refund`: a refund credit to its purchase.
  refund,

  /// `own_transfer`: debit and credit between two own accounts.
  ownTransfer,

  /// A `duplicate_notice` leg that must be `evidenceOnly` (`LINK-RECEIPT`).
  receipt,

  /// A `duplicate_notice` leg on a normal debit (`LINK-DUP-NOTIFY`).
  duplicateNotice,

  /// Any other rule: joined on its parameters only.
  generic,
}

/// How [RuleDrivenLinker] reads a link rule.
LinkRuleKind linkRuleKindOf(LinkRule rule) {
  for (final leg in rule.legs) {
    if (leg.role == LegRole.duplicateNotice) {
      return leg.match.evidenceOnly == true
          ? LinkRuleKind.receipt
          : LinkRuleKind.duplicateNotice;
    }
  }
  return switch (rule.eventType) {
    EventType.ipoApplication => LinkRuleKind.ipo,
    EventType.subscriptionCharge => LinkRuleKind.mandateCharge,
    EventType.cardBillPayment => LinkRuleKind.cardBill,
    EventType.walletTopup => LinkRuleKind.walletTopup,
    EventType.refund => LinkRuleKind.refund,
    EventType.ownTransfer => LinkRuleKind.ownTransfer,
    _ => LinkRuleKind.generic,
  };
}

/// Debit purposes a mandate can charge. Investment (SIP), EMI (loan), card
/// bills, top-ups and transfers keep their own event types.
const Set<MovementPurpose> mandateChargePurposes = {
  MovementPurpose.purchase,
  MovementPurpose.unknown,
  MovementPurpose.billPayment,
  MovementPurpose.p2p,
};

/// The WP-05 event linker: joins the facts that describe one real-world thing
/// into one [Event], driven by the bundle's link rules.
///
/// - Facts are processed in a fixed order: `observedAt` (receipt order, so a
///   batch equals the same messages one at a time), then `factId`. Only `movement`, `hold` and `mandate` facts take part.
/// - For each fact the link rules are tried by priority. A rule whose other
///   leg is found exactly once joins it; two or more give an `ambiguous` event
///   and a [ReviewItem]; none moves on to the next rule. A fact no rule joins
///   gets the first rule that lets it stand alone (`singleLeg`), or else a
///   one-leg event typed by its purpose and direction.
/// - `evidenceOnly` receipts never make an event; they join the debit they
///   confirm as `duplicate_notice` (`LINK-RECEIPT`).
/// - The anchor (first leg) never changes, `user_confirmed` events are never
///   touched, and legs only grow.
class RuleDrivenLinker implements EventLinker {
  RuleDrivenLinker({
    Iterable<SenderEntry> senders = const [],
    Iterable<CounterpartyPurpose> counterpartyPurposes = const [],
    DateTime Function()? clock,
  }) : partialWalletIssuers = {
         for (final s in senders)
           if (s.walletSpendVisibility == WalletSpendVisibility.partial &&
               s.issuerSlug != null)
             s.issuerSlug!,
       },
       _topups = [
         for (final c in counterpartyPurposes)
           if (c.purpose == MovementPurpose.walletTopup &&
               c.targetInstrument?.issuerSlug != null)
             _TopupTarget(
               vpa: c.vpaPattern == null
                   ? null
                   : RegExp(c.vpaPattern!, caseSensitive: false),
               name: c.namePattern == null
                   ? null
                   : RegExp(c.namePattern!, caseSensitive: false),
               issuerSlug: c.targetInstrument!.issuerSlug!,
             ),
       ],
       _clock = clock ?? (() => DateTime.now().toUtc());

  /// A linker that knows the bundle's wallets and top-up payees.
  factory RuleDrivenLinker.fromBundle(
    RuleBundle bundle, {
    DateTime Function()? clock,
  }) => RuleDrivenLinker(
    senders: bundle.senders,
    counterpartyPurposes: bundle.counterpartyPurposes,
    clock: clock,
  );

  /// Wallet issuers with `walletSpendVisibility: partial` (Amazon Pay): a
  /// top-up is a purchase at the wallet's merchant, and the wallet's own
  /// payment messages are wallet activity only.
  final Set<String> partialWalletIssuers;
  final List<_TopupTarget> _topups;
  final DateTime Function() _clock;

  @override
  LinkResult link({
    required List<Fact> incoming,
    required LinkContext context,
    required List<LinkRule> rules,
  }) => _Run(this, context, rules, _clock(), incoming).link(incoming);

  /// Turns `awaiting_leg` events whose rule window has passed into `complete`
  /// ones, and (with a [RuleLinkContext]) raises a review item for each
  /// receipt that [reviewReceipts] would.
  LinkResult expire({
    required DateTime now,
    required LinkContext context,
    required List<LinkRule> rules,
  }) => _Run(this, context, rules, now.toUtc(), const []).expire();

  /// The receipt question and nothing else (no event is changed): one review
  /// item for each receipt that has no funding debit, is from the current IST
  /// calendar month and has waited [kReceiptWaitPeriod]. Receipts from an
  /// earlier month are skipped silently. Needs a [RuleLinkContext] (a plain
  /// context cannot tell which receipts are already joined).
  ///
  /// [alreadyRaised] holds the review ids and dedupe keys that exist already,
  /// in any status, so a receipt that was asked about, answered or dismissed is
  /// never asked about again.
  LinkResult reviewReceipts({
    required DateTime now,
    required LinkContext context,
    required List<LinkRule> rules,
    Set<String> alreadyRaised = const {},
  }) => _Run(
    this,
    context,
    rules,
    now.toUtc(),
    const [],
  ).reviewReceipts(alreadyRaised);
}

class _TopupTarget {
  _TopupTarget({this.vpa, this.name, required this.issuerSlug});
  final RegExp? vpa;
  final RegExp? name;
  final String issuerSlug;
}

/// A candidate for the other leg: an event to extend, or a fact to join.
class _Cand {
  _Cand.event(String this.eventId, this.fact, this.role);
  _Cand.fact(this.fact, this.role) : eventId = null;
  final String? eventId;

  /// The fact that matched the other leg.
  final Fact fact;

  /// The role that fact plays.
  final LegRole role;
}

const _day = Duration(days: 1);

/// Index ranges are widened by this much: a printed date without a time, or
/// a message received late, may sit up to a day or so from the other leg.
const _slack = Duration(days: 2);

/// Facts kept sorted by `effectiveAt`, then `factId`, for window queries.
class _Timeline {
  final _items = <Fact>[];

  void add(Fact f) {
    if (_items.isEmpty || _Run._order(_items.last, f) <= 0) {
      _items.add(f);
      return;
    }
    var lo = 0;
    var hi = _items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_Run._order(_items[mid], f) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _items.insert(lo, f);
  }

  /// Facts with `effectiveAt` in `[from, to]`, oldest first.
  Iterable<Fact> range(DateTime from, DateTime to) sync* {
    var lo = 0;
    var hi = _items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_items[mid].effectiveAt.isBefore(from)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (
      var i = lo;
      i < _items.length && !_items[i].effectiveAt.isAfter(to);
      i++
    ) {
      yield _items[i];
    }
  }
}

const _moneyRoles = {
  LegRole.debitLeg,
  LegRole.creditLeg,
  LegRole.charge,
  LegRole.reversal,
};

/// One link (or expire) call.
class _Run {
  _Run(
    this.linker,
    this.context,
    List<LinkRule> rules,
    this.now,
    List<Fact> incoming,
  ) : rules = [...rules]
        ..sort((a, b) {
          final c = b.priority.compareTo(a.priority);
          return c != 0 ? c : a.id.compareTo(b.id);
        }),
      complete = context is RuleLinkContext,
      idByFact = context is RuleLinkContext
          ? context.instrumentIdByFactId
          : const {} {
    for (final r in this.rules) {
      kinds[r] = linkRuleKindOf(r);
    }
    final incomingIds = {for (final f in incoming) f.factId};
    final recent = [
      for (final f in context.recentFacts)
        if (!incomingIds.contains(f.factId)) f,
    ]..sort(_order);
    for (final f in recent) {
      facts[f.factId] = f;
    }
    final known = <Event>[
      ...context.openEvents,
      if (context case final RuleLinkContext c) ...c.knownEvents,
    ];
    for (final e in known) {
      if (events.containsKey(e.eventId)) continue;
      events[e.eventId] = e;
      preexisting.add(e.eventId);
      _mapLegs(e);
    }
    for (final e in events.values) {
      _countRefund(e);
    }
    for (final f in recent) {
      processed.add(f.factId);
      _index(f);
    }
  }

  final RuleDrivenLinker linker;
  final LinkContext context;
  final List<LinkRule> rules;
  final DateTime now;
  final bool complete;
  final Map<String, String> idByFact;
  // Identity: contract values hash by canonical JSON, which is slow.
  final kinds = Map<LinkRule, LinkRuleKind>.identity();

  final facts = <String, Fact>{};
  final events = <String, Event>{};
  final preexisting = <String>{};
  final changed = <String>{};

  /// Fact id to the event it is a leg of (every role except `original`, which
  /// may be shared by several events).
  final eventOfFact = <String, String>{};
  final processed = <String>{};
  final thisRun = <String>{};

  final byAmount = <int, List<Fact>>{};
  final byType = <FactType, _Timeline>{};
  final byInstrument = <String, _Timeline>{};

  /// Facts by instrument and counterparty name key (`<instrumentId>|<key>`).
  final byInstrumentParty = <String, _Timeline>{};

  /// Mandates by name keys ([_partyKeys]) and by reference (`R:<value>`).
  final mandatesByKey = <String, _Timeline>{};

  /// Non-receipt debits by counterparty name key and by `R:<mandateRef>`, so a
  /// mandate that arrives after its charges can find them.
  final debitsByKey = <String, _Timeline>{};

  /// Purchase fact id to the refunds already linked to it.
  final refunded = <String, int>{};
  final reviews = <String, ReviewItem>{};
  final ambiguousReceipts = <String>{};
  final pendingIpoMandates = <MandateFact>[];
  final _instCache = <String, Instrument?>{};

  static int _order(Fact a, Fact b) {
    final c = a.effectiveAt.compareTo(b.effectiveAt);
    return c != 0 ? c : a.factId.compareTo(b.factId);
  }

  /// The order facts are linked in: the order messages are received, which is
  /// the order live capture sees them in. A printed date (a day, or a day and
  /// time) can put a later message before an earlier one, so ordering a batch
  /// by it would link a history differently from the same messages one at a
  /// time. Ties go by fact id.
  static int _arrival(Fact a, Fact b) {
    final c = a.observedAt.compareTo(b.observedAt);
    return c != 0 ? c : a.factId.compareTo(b.factId);
  }

  // --------------------------------------------------------------- public

  LinkResult link(List<Fact> incoming) {
    final seen = <String>{};
    final sorted = [
      for (final f in incoming)
        if (seen.add(f.factId)) f,
    ]..sort(_arrival);
    for (final f in sorted) {
      facts[f.factId] = f;
    }
    for (final f in sorted) {
      if (eventOfFact.containsKey(f.factId)) {
        _done(f); // already a leg: re-running changes nothing
        continue;
      }
      _process(f);
    }
    _attachIpoMandates();
    return _result();
  }

  LinkResult expire() {
    for (final e in [...events.values]) {
      if (e.status != EventStatus.awaitingLeg) continue;
      final rule = _ruleById(e.linkRuleId);
      final hours = rule?.join.windowHours ?? 504;
      final anchor = facts[e.eventId];
      final at = anchor == null ? e.occurredAt : _latest(anchor);
      if (now.difference(at) > _hours(hours)) {
        _put(e.copyWith(status: EventStatus.complete));
      }
    }
    if (complete) _raiseReceiptReviews(const {});
    return _result();
  }

  LinkResult reviewReceipts(Set<String> alreadyRaised) {
    if (complete) _raiseReceiptReviews(alreadyRaised);
    return _result();
  }

  LinkResult _result() {
    final created = <Event>[];
    final updated = <Event>[];
    for (final id in changed) {
      (preexisting.contains(id) ? updated : created).add(events[id]!);
    }
    return LinkResult(
      created: created,
      updated: updated,
      ambiguous: [...reviews.values],
    );
  }

  // ------------------------------------------------------------ processing

  void _process(Fact f) {
    switch (f) {
      case MovementFact(evidenceOnly: true):
        if (f.direction == Direction.debit) _processReceipt(f);
        _done(f);
        return;
      case MandateFact():
        if (_isIpoMandate(f)) pendingIpoMandates.add(f);
        _done(f);
        _lateMandate(f);
        return;
      case MovementFact() || HoldFact():
        break;
      default:
        _done(f);
        return;
    }

    // A debit for a receipt the user already confirmed is that same payment.
    if (f is MovementFact &&
        f.direction == Direction.debit &&
        f.evidenceOnly != true &&
        _lateFundingDebit(f)) {
      _done(f);
      return;
    }

    // 0. Legs that arrived before this one (see [_lateHold], [_lateOriginal]).
    if (f is HoldFact && _lateHold(f)) {
      _done(f);
      return;
    }
    if (f is MovementFact) _lateOriginal(f);

    // 1. Pair rules, by priority: join the one other leg that is found.
    for (final rule in rules) {
      final kind = kinds[rule]!;
      if (kind == LinkRuleKind.receipt || kind == LinkRuleKind.duplicateNotice)
        continue;
      for (final leg in rule.legs) {
        if (leg.role == LegRole.original)
          continue; // shared references never search
        if (!_legMatches(rule, leg, f)) continue;
        final cands = _candidates(rule, leg, f);
        if (cands.isEmpty) continue;
        final narrowed = _narrow(rule, f, cands);
        // Several mandates of one merchant (a notice with a reference and one
        // without, or two references) are not an ambiguity about the money: the
        // debit is a charge either way. `_mandateCandidates` lists the most
        // recently active mandate first, so the debit joins that one and keeps
        // its charge leg and its ledger row.
        final eventId =
            narrowed.length == 1 || kind == LinkRuleKind.mandateCharge
            ? _join(rule, leg.role, f, narrowed.first)
            : _ambiguous(rule, leg.role, f, narrowed);
        _afterMoney(f, eventId);
        _done(f);
        return;
      }
    }

    // 2. A second notice of a payment already seen (bank and UPI app, a
    //    registrar and the bank, a broker and the bank).
    if (f is MovementFact) {
      for (final rule in rules) {
        if (kinds[rule] != LinkRuleKind.duplicateNotice) continue;
        final cands = _duplicateCandidates(rule, f);
        if (cands.isEmpty) continue;
        final narrowed = _narrow(rule, f, cands);
        if (narrowed.length == 1) {
          _joinDuplicate(rule, f, narrowed.single);
        } else {
          _ambiguous(
            rule,
            f.direction == Direction.debit
                ? LegRole.debitLeg
                : LegRole.creditLeg,
            f,
            narrowed,
          );
        }
        _done(f);
        return;
      }
    }

    // 3. The first rule that lets this leg stand alone.
    for (final rule in rules) {
      for (final leg in rule.legs) {
        if (!_legMatches(rule, leg, f) || !_standsAlone(rule, leg.role, f))
          continue;
        final status = switch (rule.singleLeg) {
          SingleLeg.awaitingLeg => EventStatus.awaitingLeg,
          _ => EventStatus.complete,
        };
        final legs = [EventLeg(factId: f.factId, role: leg.role)];
        final e = _build(f.factId, _typeFor(rule, legs), status, legs, rule.id);
        _put(e);
        if (rule.singleLeg == SingleLeg.review) _singleLegReview(rule, f, e);
        _afterMoney(f, e.eventId);
        _done(f);
        return;
      }
    }

    // 4. No rule: one event typed by purpose and direction.
    final fb = _fallback(f);
    if (fb != null) {
      final legs = [EventLeg(factId: f.factId, role: fb.role)];
      final e = _build(f.factId, fb.type, fb.status, legs, null);
      _put(e);
      _afterMoney(f, e.eventId);
    }
    _done(f);
  }

  void _done(Fact f) {
    if (processed.add(f.factId)) _index(f);
    thisRun.add(f.factId);
  }

  void _index(Fact f) {
    byType.putIfAbsent(f.factType, _Timeline.new).add(f);
    final a = _principal(f);
    if (a != null) byAmount.putIfAbsent(a, () => []).add(f);
    final i = _instId(f);
    if (i != null) {
      byInstrument.putIfAbsent(i, _Timeline.new).add(f);
      for (final k in _partyKeys(_party(f))) {
        byInstrumentParty.putIfAbsent('$i|$k', _Timeline.new).add(f);
      }
    }
    if (f is MandateFact) {
      for (final k in {
        ..._partyKeys(_party(f)),
        for (final r in f.references.values) 'R:$r',
      }) {
        mandatesByKey.putIfAbsent(k, _Timeline.new).add(f);
      }
    }
    if (f is MovementFact &&
        f.direction == Direction.debit &&
        f.evidenceOnly != true) {
      for (final k in {
        ..._partyKeys(_party(f)),
        if (f.mandateRef != null) 'R:${f.mandateRef}',
      }) {
        debitsByKey.putIfAbsent(k, _Timeline.new).add(f);
      }
    }
  }

  void _mapLegs(Event e) {
    for (final l in e.legs) {
      if (l.role == LegRole.original) continue;
      eventOfFact.putIfAbsent(l.factId, () => e.eventId);
    }
  }

  void _put(Event e) {
    events[e.eventId] = e;
    changed.add(e.eventId);
    _mapLegs(e);
  }

  void _countRefund(Event e) {
    if (e.type != EventType.refund) return;
    final originals = [
      for (final l in e.legs)
        if (l.role == LegRole.original) l.factId,
    ];
    if (originals.isEmpty) return;
    var sum = 0;
    for (final l in e.legs) {
      if (l.role != LegRole.reversal) continue;
      final f = facts[l.factId];
      sum += (f == null ? null : _principal(f)) ?? 0;
    }
    for (final o in originals) {
      refunded.update(o, (v) => v + sum, ifAbsent: () => sum);
    }
  }

  // -------------------------------------------------------------- matching

  bool _legMatches(LinkRule rule, LinkLeg leg, Fact f) {
    final m = leg.match;
    if (m.factType != null && f.factType != m.factType) return false;
    if (m.direction != null) {
      if (f is! MovementFact || f.direction != m.direction) return false;
    }
    if (m.purpose != null) {
      final p = switch (f) {
        MovementFact() => f.purpose.wire,
        HoldFact() => f.purpose.wire,
        _ => null,
      };
      if (p == null || !m.purpose!.contains(p)) return false;
    }
    if (m.instrumentKind != null) {
      final k = _instKind(f);
      if (k == null || !m.instrumentKind!.contains(k)) return false;
    }
    if (m.phase != null) {
      if (f is! HoldFact || !m.phase!.contains(f.phase)) return false;
    }
    if (m.evidenceOnly != null) {
      final ev = f is MovementFact && f.evidenceOnly == true;
      if (ev != m.evidenceOnly) return false;
    }
    if (kinds[rule] == LinkRuleKind.mandateCharge &&
        leg.role == LegRole.charge) {
      if (f is! MovementFact || f.direction != Direction.debit) return false;
      if (!mandateChargePurposes.contains(f.purpose)) return false;
      if (f.mandateRef == null && _party(f) == null) return false;
    }
    return true;
  }

  List<_Cand> _candidates(LinkRule rule, LinkLeg leg, Fact f) {
    final kind = kinds[rule]!;
    if (kind == LinkRuleKind.mandateCharge) return _mandateCandidates(rule, f);
    final role = leg.role;
    final placed = rule.legs
        .where((l) => l.role == LegRole.holdPlaced)
        .toList();
    final List<LinkLeg> others;
    if (placed.isNotEmpty) {
      // Hold rules: every later leg relates to the placed hold.
      others = role == LegRole.holdPlaced ? const [] : placed;
    } else {
      others = [
        for (final l in rule.legs)
          if (l.role != role) l,
      ];
    }
    for (final other in others) {
      for (final stage in _pool(rule, other, f)) {
        final found = _scan(rule, role, f, other, stage);
        if (found.isNotEmpty) return found;
      }
    }
    return const [];
  }

  /// The candidates among [pool] for the [other] leg of [rule].
  List<_Cand> _scan(
    LinkRule rule,
    LegRole role,
    Fact f,
    LinkLeg other,
    Iterable<Fact> pool,
  ) {
    final byEvent = <String, _Cand>{};
    final loose = <_Cand>[];
    for (final g in pool) {
      if (g.factId == f.factId || g.sourceKey == f.sourceKey) continue;
      if (!processed.contains(g.factId)) continue;
      if (!_legMatches(rule, other, g)) continue;
      if (!_within(f, g, rule.join.windowHours)) continue;
      if (!_amountOk(rule, role, f, other.role, g)) continue;
      if (rule.join.reference == ReferenceMode.require && !_sharesRef(f, g))
        continue;
      if (!_pairOk(rule, role, f, other.role, g)) continue;
      if (other.role == LegRole.original) {
        loose.add(_Cand.fact(g, other.role));
        continue;
      }
      final eventId = eventOfFact[g.factId];
      if (eventId != null) {
        if (byEvent.containsKey(eventId)) continue;
        if (!_joinable(rule, events[eventId]!, role)) continue;
        byEvent[eventId] = _Cand.event(eventId, g, other.role);
      } else if (_usableLoose(g)) {
        loose.add(_Cand.fact(g, other.role));
      }
    }
    return byEvent.isNotEmpty ? [...byEvent.values] : loose;
  }

  /// Facts that may be the other leg, from an index by amount, or by time
  /// inside the rule's window (never all pairs). Stages are tried in order
  /// until one yields a candidate.
  List<Iterable<Fact>> _pool(LinkRule rule, LinkLeg other, Fact f) {
    final kind = kinds[rule]!;
    final from = f.effectiveAt.subtract(_hours(rule.join.windowHours) + _slack);
    final to = f.effectiveAt.add(_slack);
    Iterable<Fact> range(_Timeline? t) =>
        t == null ? const [] : t.range(from, to);
    final i = _instId(f);
    final keys = _partyKeys(_party(f));
    final a = _principal(f);
    if (kind == LinkRuleKind.ipo) {
      // The hold with the same issue first, then any hold in the window.
      return [
        if (i != null)
          for (final k in keys) range(byInstrumentParty['$i|$k']),
        range(byType[FactType.hold]),
      ];
    }
    final ft = other.match.factType;
    if (ft != null && ft != FactType.movement) return [range(byType[ft])];
    final tol = rule.join.amountTolerancePct ?? 0;
    if (tol == 0 && a != null) return [byAmount[a] ?? const []];
    if (kind == LinkRuleKind.refund) {
      if (i == null) return const []; // a refund needs its card or account
      // The same merchant (any amount up to the purchase), then the same
      // amount. A refund that names no merchant links only on the exact
      // amount: "some purchase above the refund" is a guess.
      return [
        for (final k in keys) range(byInstrumentParty['$i|$k']),
        if (a != null) byAmount[a] ?? const [],
      ];
    }
    return [range(byType[FactType.movement])];
  }

  /// A processed fact that is not a leg of any event we know.
  bool _usableLoose(Fact g) {
    if (complete || thisRun.contains(g.factId)) return true;
    // A plain LinkContext does not list complete events, so a recent money
    // fact may already be joined; only facts that never make an event of
    // their own are safe to use.
    return (g is MovementFact && g.evidenceOnly == true) || g is MandateFact;
  }

  bool _joinable(LinkRule rule, Event e, LegRole role) {
    if (e.status == EventStatus.userConfirmed ||
        e.status == EventStatus.ambiguous)
      return false;
    if (role != LegRole.duplicateNotice && e.legs.any((l) => l.role == role))
      return false;
    if (e.linkRuleId == rule.id) return true;
    return e.linkRuleId == null && e.legs.length == 1;
  }

  bool _amountOk(
    LinkRule rule,
    LegRole role,
    Fact f,
    LegRole otherRole,
    Fact g,
  ) {
    final pa = _priced(f);
    final pb = _priced(g);
    final tol = rule.join.amountTolerancePct ?? 0;
    // Amounts in different units (paise against cents) never compare. An
    // "up to" rule treats that as an unknown amount, except a refund: a
    // foreign-only refund is not shown to be part of an INR purchase.
    if (pa != null && pb != null && pa.unit != pb.unit) {
      return tol >= 100 && kinds[rule] != LinkRuleKind.refund;
    }
    if (pa == null || pb == null) return tol >= 100;
    final a = pa.minor;
    final b = pb.minor;
    if (tol >= 100) {
      // "Up to": the dependent leg is at most the reference leg.
      if (_isReference(otherRole)) return b >= a;
      if (_isReference(role)) return a >= b;
      return true;
    }
    if (tol == 0) return a == b;
    return (a - b).abs() * 100 <= (a > b ? a : b) * tol;
  }

  static bool _isReference(LegRole r) =>
      r == LegRole.holdPlaced || r == LegRole.original;

  bool _pairOk(LinkRule rule, LegRole role, Fact f, LegRole otherRole, Fact g) {
    final kind = kinds[rule]!;
    switch (kind) {
      case LinkRuleKind.cardBill:
        final (d, c) = _debitCredit(role, f, g);
        if (_sameInstrument(d, c)) return false;
        return _maskOk(d.counterparty?.accountMask, _inst(c)?.maskDigits);
      case LinkRuleKind.walletTopup:
        final (d, c) = _debitCredit(role, f, g);
        final target = _topupIssuer(d);
        final into = _inst(c)?.issuerSlug ?? c.instrument?.issuerSlug;
        return target == null || into == null || target == into;
      case LinkRuleKind.ownTransfer:
        final (d, c) = _debitCredit(role, f, g);
        if (_sameInstrument(d, c)) return false;
        if (!_maskOk(d.counterparty?.accountMask, _inst(c)?.maskDigits))
          return false;
        if (!_maskOk(c.counterparty?.accountMask, _inst(d)?.maskDigits))
          return false;
        return _isOwnDebit(d) || _isOwnCredit(c);
      case LinkRuleKind.refund:
        final refund = otherRole == LegRole.original ? f : g;
        final purchase = otherRole == LegRole.original ? g : f;
        final ri = _instId(refund);
        final pi = _instId(purchase);
        if (ri == null || pi == null || ri != pi) return false;
        if (!_namesCompatible(_party(refund), _party(purchase))) return false;
        if (purchase.effectiveAt.isAfter(refund.effectiveAt) &&
            purchase.observedAt.isAfter(refund.observedAt)) {
          return false;
        }
        final cap = _principal(purchase);
        final amount = _principal(refund) ?? 0;
        if (cap != null && (refunded[purchase.factId] ?? 0) + amount > cap)
          return false;
        return true;
      case LinkRuleKind.ipo:
        final fi = _instId(f);
        final gi = _instId(g);
        if (fi != null && gi != null && fi != gi) return false;
        return _namesCompatible(_party(f), _party(g));
      default:
        return true;
    }
  }

  (Fact, Fact) _debitCredit(LegRole role, Fact f, Fact g) =>
      role == LegRole.debitLeg ? (f, g) : (g, f);

  /// The mandates a debit may charge: one candidate per mandate, active at
  /// the time of the debit. One-time, IPO, SIP and loan mandates never count.
  List<_Cand> _mandateCandidates(LinkRule rule, Fact f) {
    final m = f as MovementFact;
    final ref = m.mandateRef;
    final groups = <String, List<MandateFact>>{};
    final from = f.effectiveAt.subtract(_hours(rule.join.windowHours) + _slack);
    final to = f.effectiveAt.add(_day);
    final pool = <String, MandateFact>{
      for (final k in [..._partyKeys(_party(f)), if (ref != null) 'R:$ref'])
        for (final g in mandatesByKey[k]?.range(from, to) ?? const <Fact>[])
          g.factId: g as MandateFact,
    }.values.toList()..sort(_order);
    for (final g in pool) {
      if (!processed.contains(g.factId) || g.sourceKey == f.sourceKey) {
        continue;
      }
      if (_isIpoMandate(g) ||
          g.mandatePurpose == MandatePurpose.sip ||
          g.mandatePurpose == MandatePurpose.loan) {
        continue;
      }
      if (g.effectiveAt.isAfter(f.effectiveAt.add(_day))) continue;
      if (!_within(f, g, rule.join.windowHours)) continue;
      final refs = {...g.references.values};
      if (ref != null && refs.isNotEmpty) {
        if (!refs.contains(ref)) continue;
      } else if (!_sameParty(_party(g), _party(f))) {
        continue;
      }
      final key = refs.isNotEmpty
          ? 'ref:${(refs.toList()..sort()).first}'
          : 'name:${_key(_party(g))}';
      groups.putIfAbsent(key, () => []).add(g);
    }
    final out = <(DateTime, String, _Cand)>[];
    for (final group in groups.values) {
      group.sort(_order);
      final upTo = [
        for (final g in group)
          if (!g.effectiveAt.isAfter(f.effectiveAt.add(_day))) g,
      ];
      if (upTo.isEmpty) continue;
      final state = upTo.last.phase;
      if (state == MandatePhase.revoked ||
          state == MandatePhase.expired ||
          state == MandatePhase.paused) {
        continue;
      }
      final created = upTo.where((g) => g.phase == MandatePhase.created);
      final original = created.isNotEmpty ? created.first : upTo.last;
      int? ceiling;
      for (final g in upTo.reversed) {
        ceiling = g.amount(AmountRole.ceiling)?.minor;
        if (ceiling != null) break;
      }
      final posted = _principal(f);
      if (ceiling != null && posted != null && posted > ceiling) continue;
      out.add((
        upTo.last.effectiveAt,
        upTo.last.factId,
        _Cand.fact(original, LegRole.original),
      ));
    }
    // Most recently active mandate first (ties by fact id, so it is stable).
    out.sort((a, b) {
      final t = b.$1.compareTo(a.$1);
      return t != 0 ? t : b.$2.compareTo(a.$2);
    });
    return [for (final c in out) c.$3];
  }

  List<_Cand> _duplicateCandidates(LinkRule rule, MovementFact f) {
    final a = _principal(f);
    if (a == null) return const [];
    // The rule's own legs say which facts are notices and which are the money.
    final noticeLeg = rule.legs
        .where((l) => l.role == LegRole.duplicateNotice)
        .firstOrNull;
    final moneyLeg = rule.legs
        .where((l) => l.role != LegRole.duplicateNotice)
        .firstOrNull;
    if (noticeLeg == null ||
        moneyLeg == null ||
        !_legMatches(rule, noticeLeg, f)) {
      return const [];
    }
    final byEvent = <String, _Cand>{};
    for (final g in byAmount[a] ?? const <Fact>[]) {
      if (g is! MovementFact ||
          g.factId == f.factId ||
          g.sourceKey == f.sourceKey)
        continue;
      if (!processed.contains(g.factId)) continue;
      if (!_legMatches(rule, moneyLeg, g)) continue;
      if (!_within(f, g, rule.join.windowHours)) continue;
      final eventId = eventOfFact[g.factId];
      if (eventId == null || byEvent.containsKey(eventId)) continue;
      final e = events[eventId]!;
      if (e.status == EventStatus.userConfirmed ||
          e.status == EventStatus.ambiguous)
        continue;
      final gRole = e.legs.firstWhere((l) => l.factId == g.factId).role;
      if (gRole != LegRole.debitLeg &&
          gRole != LegRole.charge &&
          gRole != LegRole.creditLeg) {
        continue;
      }
      final fi = _instId(f);
      final gi = _instId(g);
      if (fi != null && gi != null && fi != gi) continue;
      final shared = _sharesRef(f, g);
      if (!shared && _conflictingRefs(f, g)) continue;
      // The same template on the same account twice is two real payments.
      if (!shared &&
          fi != null &&
          fi == gi &&
          f.provenance.ruleId == g.provenance.ruleId)
        continue;
      byEvent[eventId] = _Cand.event(eventId, g, gRole);
    }
    return [...byEvent.values];
  }

  /// Narrows candidates by shared reference, counterparty, exact amount and
  /// instrument; each step applies only when it keeps at least one.
  List<_Cand> _narrow(LinkRule rule, Fact f, List<_Cand> cands) {
    var list = cands;
    void step(bool Function(_Cand c) keep) {
      if (list.length < 2) return;
      final sub = [
        for (final c in list)
          if (keep(c)) c,
      ];
      if (sub.isNotEmpty) list = sub;
    }

    if (rule.join.reference != ReferenceMode.ignore) {
      step((c) => _candFacts(c).any((g) => _sharesRef(f, g)));
    }
    final p = _party(f);
    if (p != null)
      step((c) => _candFacts(c).any((g) => _sameParty(p, _party(g))));
    final a = _principal(f);
    if (a != null) step((c) => _principal(c.fact) == a);
    final i = _instId(f);
    if (i != null) step((c) => _instId(c.fact) == i);
    return list;
  }

  Iterable<Fact> _candFacts(_Cand c) sync* {
    yield c.fact;
    if (c.eventId == null) return;
    for (final l in events[c.eventId]!.legs) {
      final g = facts[l.factId];
      if (g != null && g.factId != c.fact.factId) yield g;
    }
  }

  // ----------------------------------------------------------- late arrivals
  //
  // The linker is incremental: a call sees the facts of earlier calls only as
  // stored events. When a fact that comes earlier in time arrives later than
  // facts that depend on it (a release, an allotment debit, a refund, a
  // charge), those facts already stand as events of their own. The three
  // functions below let the earlier fact join them, so one batch, one message
  // at a time and any arrival order end with the same legs. Money is never
  // moved: a fact is a money leg of one event only.

  /// A hold placed after its release, converted or allotment debit already
  /// arrived. The hold joins the event of the dependents it matches (the
  /// event that holds the debit, else the first); a dependent that carries no
  /// money (a release) is added as a leg too. Returns whether it joined.
  bool _lateHold(HoldFact f) {
    if (f.phase != HoldPhase.placed) return false;
    final rule = _firstOf(LinkRuleKind.ipo);
    if (rule == null) return false;
    final held = _principal(f);
    final window = _hours(rule.join.windowHours);
    final from = f.effectiveAt.subtract(_slack);
    final to = f.effectiveAt.add(window + _slack);
    final found = <(Fact, LegRole)>[];
    for (final t in [byType[FactType.hold], byType[FactType.movement]]) {
      if (t == null) continue;
      for (final g in t.range(from, to)) {
        if (g.factId == f.factId || g.sourceKey == f.sourceKey) continue;
        if (!processed.contains(g.factId) || !_hasEvent(g)) continue;
        for (final leg in rule.legs) {
          if (leg.role == LegRole.holdPlaced || leg.role == LegRole.original)
            continue;
          if (!_legMatches(rule, leg, g)) continue;
          if (!_within(f, g, rule.join.windowHours)) continue;
          if (!_amountOk(rule, LegRole.holdPlaced, f, leg.role, g)) continue;
          if (!_pairOk(rule, LegRole.holdPlaced, f, leg.role, g)) continue;
          final e = events[eventOfFact[g.factId]!]!;
          if (!_standsWithoutHold(e)) continue;
          found.add((g, leg.role));
          break;
        }
      }
    }
    if (found.isEmpty) return false;
    found.sort((a, b) => _order(a.$1, b.$1));
    // The event that holds the money (the allotment debit) takes the hold;
    // a release alone is the base only when no debit is there. A second
    // dependent keeps the event it already has: a fact is a leg of one event.
    final chosen = [
      for (final c in found)
        if (held == null || (_principal(c.$1) ?? 0) <= held) c,
    ];
    if (chosen.isEmpty) return false;
    // Another open hold the first dependent could belong to: the same
    // ambiguity a batch reports, so leave the dependents as they are.
    final first = chosen.first;
    for (final h
        in byType[FactType.hold]?.range(
              first.$1.effectiveAt.subtract(window + _slack),
              first.$1.effectiveAt.add(_slack),
            ) ??
            const <Fact>[]) {
      if (h is! HoldFact || h.phase != HoldPhase.placed || h.factId == f.factId)
        continue;
      if (!processed.contains(h.factId) || eventOfFact[h.factId] == null)
        continue;
      if (h.sourceKey == f.sourceKey) continue;
      final he = events[eventOfFact[h.factId]!]!;
      if (he.status != EventStatus.awaitingLeg || he.legs.length != 1) continue;
      if (_within(h, first.$1, rule.join.windowHours) &&
          _amountOk(rule, LegRole.holdPlaced, h, first.$2, first.$1) &&
          _pairOk(rule, LegRole.holdPlaced, h, first.$2, first.$1)) {
        return false;
      }
    }
    final base = chosen.firstWhere(
      (c) => c.$2 == LegRole.debitLeg,
      orElse: () => chosen.first,
    );
    final be = events[eventOfFact[base.$1.factId]!]!;
    final legs = <EventLeg>[...be.legs];
    legs.add(EventLeg(factId: f.factId, role: LegRole.holdPlaced));
    _put(
      _build(
        be.eventId,
        _typeFor(rule, legs),
        _statusFor(rule, legs),
        legs,
        rule.id,
        prior: be,
      ),
    );
    return true;
  }

  /// An event a late hold may join: not settled by the user, no hold yet, and
  /// made only of the dependent itself and its duplicate notices.
  bool _standsWithoutHold(Event e) {
    if (e.status == EventStatus.userConfirmed ||
        e.status == EventStatus.ambiguous)
      return false;
    if (e.legs.any(
      (l) => l.role == LegRole.holdPlaced || l.role == LegRole.original,
    ))
      return false;
    final id = e.linkRuleId;
    if (id != null) {
      final r = _ruleById(id);
      final k = r == null ? null : kinds[r];
      if (k != LinkRuleKind.duplicateNotice && k != LinkRuleKind.receipt)
        return false;
    }
    return e.legs.where((l) => l.role != LegRole.duplicateNotice).length == 1;
  }

  bool _hasEvent(Fact g) => eventOfFact.containsKey(g.factId);

  /// A purchase that arrived after a refund of it: each refund that stands
  /// alone and fits (same card, merchant, at most the purchase) takes the
  /// purchase as its `original`. The purchase keeps its own event.
  void _lateOriginal(MovementFact f) {
    final rule = _firstOf(LinkRuleKind.refund);
    if (rule == null ||
        f.direction != Direction.debit ||
        f.evidenceOnly == true)
      return;
    final leg = rule.legs.where((l) => l.role == LegRole.original).firstOrNull;
    final reversal = rule.legs
        .where((l) => l.role == LegRole.reversal)
        .firstOrNull;
    if (leg == null || reversal == null || !_legMatches(rule, leg, f)) return;
    final i = _instId(f);
    final amount = _principal(f);
    if (i == null || amount == null) return;
    final window = _hours(rule.join.windowHours);
    final found = <Fact>[];
    final seen = <String>{};
    final pool = byType[FactType.movement]?.range(
      f.effectiveAt.subtract(_slack),
      f.effectiveAt.add(window + _slack),
    );
    for (final g in pool ?? const <Fact>[]) {
      if (g.factId == f.factId ||
          g.sourceKey == f.sourceKey ||
          !seen.add(g.factId))
        continue;
      if (!processed.contains(g.factId) || !_hasEvent(g)) continue;
      if (!_legMatches(rule, reversal, g)) continue;
      if (!_within(f, g, rule.join.windowHours)) continue;
      if (!_amountOk(rule, LegRole.original, f, LegRole.reversal, g)) continue;
      final e = events[eventOfFact[g.factId]!]!;
      if (!_joinable(rule, e, LegRole.original)) continue;
      found.add(g);
    }
    found.sort(_order);
    for (final g in found) {
      // `_pairOk` reads the running refunded total, so each join counts.
      if (!_pairOk(rule, LegRole.original, f, LegRole.reversal, g)) continue;
      _join(
        rule,
        LegRole.original,
        f,
        _Cand.event(eventOfFact[g.factId]!, g, LegRole.reversal),
      );
    }
  }

  /// A mandate that arrived after its charges: each charge that stands alone
  /// (or with duplicate notices) and whose best mandate is now known becomes
  /// `subscription_charge [charge, original]`.
  void _lateMandate(MandateFact m) {
    final rule = _firstOf(LinkRuleKind.mandateCharge);
    if (rule == null || _isIpoMandate(m)) return;
    if (m.mandatePurpose == MandatePurpose.sip ||
        m.mandatePurpose == MandatePurpose.loan)
      return;
    final leg = rule.legs.where((l) => l.role == LegRole.charge).firstOrNull;
    if (leg == null) return;
    final window = _hours(rule.join.windowHours);
    final from = m.effectiveAt.subtract(_slack);
    final to = m.effectiveAt.add(window + _slack);
    final charges = <String, MovementFact>{};
    for (final k in {
      ..._partyKeys(_party(m)),
      for (final r in m.references.values) 'R:$r',
    }) {
      for (final g in debitsByKey[k]?.range(from, to) ?? const <Fact>[]) {
        if (g is! MovementFact || g.sourceKey == m.sourceKey) continue;
        if (!processed.contains(g.factId) || !_hasEvent(g)) continue;
        charges[g.factId] = g;
      }
    }
    final ordered = charges.values.toList()..sort(_order);
    for (final g in ordered) {
      if (!_legMatches(rule, leg, g)) continue;
      final e = events[eventOfFact[g.factId]!]!;
      if (e.status == EventStatus.userConfirmed ||
          e.status == EventStatus.ambiguous)
        continue;
      if (e.legs.any(
        (l) => l.role == LegRole.original || l.role == LegRole.charge,
      ))
        continue;
      if (e.type == EventType.subscriptionCharge && e.legs.length == 1) {
        // already a charge with no mandate seen: it may take this one
      } else if (e.linkRuleId != null &&
          kinds[_ruleById(e.linkRuleId)] == null) {
        continue;
      }
      final role = e.legs.firstWhere((l) => l.factId == g.factId).role;
      if (role != LegRole.debitLeg) continue;
      if (e.legs.any(
        (l) => l.role != LegRole.debitLeg && l.role != LegRole.duplicateNotice,
      )) {
        continue;
      }
      final cands = _mandateCandidates(rule, g);
      if (cands.isEmpty) continue;
      final legs = <EventLeg>[
        for (final l in e.legs)
          if (l.factId == g.factId)
            EventLeg(factId: g.factId, role: LegRole.charge)
          else
            l,
        EventLeg(factId: cands.first.fact.factId, role: LegRole.original),
      ];
      _put(
        _build(
          e.eventId,
          _typeFor(rule, legs),
          EventStatus.complete,
          legs,
          rule.id,
          prior: e,
        ),
      );
    }
  }

  // ----------------------------------------------------------------- joins

  String _join(LinkRule rule, LegRole role, Fact f, _Cand c) {
    final newLeg = EventLeg(factId: f.factId, role: role);
    if (c.eventId != null) {
      final e = events[c.eventId]!;
      final legs = <EventLeg>[
        for (final l in e.legs)
          // A one-leg event made without a rule takes the role the rule gives it.
          if (e.linkRuleId == null &&
              e.legs.length == 1 &&
              l.factId == c.fact.factId)
            EventLeg(factId: l.factId, role: c.role)
          else
            l,
        newLeg,
      ];
      final joined = _build(
        e.eventId,
        _typeFor(rule, legs),
        _statusFor(rule, legs),
        legs,
        rule.id,
        prior: e,
      );
      _put(joined);
      if (kinds[rule] == LinkRuleKind.refund) _countRefund(joined);
      return joined.eventId;
    }
    final other = EventLeg(factId: c.fact.factId, role: c.role);
    // A shared reference (purchase, mandate) never anchors; otherwise the fact
    // seen first does.
    final legs = c.role == LegRole.original ? [newLeg, other] : [other, newLeg];
    final e = _build(
      legs.first.factId,
      _typeFor(rule, legs),
      _statusFor(rule, legs),
      legs,
      rule.id,
    );
    _put(e);
    if (kinds[rule] == LinkRuleKind.refund) {
      refunded.update(
        c.fact.factId,
        (v) => v + (_principal(f) ?? 0),
        ifAbsent: () => _principal(f) ?? 0,
      );
    }
    return e.eventId;
  }

  void _joinDuplicate(LinkRule rule, MovementFact f, _Cand c) {
    final e = events[c.eventId]!;
    final g = c.fact;
    // Keep the notice that names the account as the money leg.
    // Otherwise the one that comes first in time, so arrival order cannot
    // change which notice is the money.
    final gi = _instId(g), fi = _instId(f);
    final swap = (gi == null) != (fi == null) ? gi == null : _order(f, g) < 0;
    final legs = <EventLeg>[
      for (final l in e.legs)
        if (swap && l.factId == g.factId)
          EventLeg(factId: l.factId, role: LegRole.duplicateNotice)
        else
          l,
      EventLeg(factId: f.factId, role: swap ? c.role : LegRole.duplicateNotice),
    ];
    var type = e.type;
    if (type == EventType.unknown) type = _fallback(f)?.type ?? type;
    _put(
      _build(
        e.eventId,
        type,
        e.status,
        legs,
        e.linkRuleId ?? rule.id,
        prior: e,
      ),
    );
  }

  String _ambiguous(LinkRule rule, LegRole role, Fact f, List<_Cand> cands) {
    final kind = kinds[rule]!;
    final legs = [EventLeg(factId: f.factId, role: role)];
    final type =
        (kind == LinkRuleKind.receipt || kind == LinkRuleKind.duplicateNotice)
        ? (_fallback(f)?.type ?? EventType.unknown)
        : _typeFor(rule, legs);
    final e = _build(f.factId, type, EventStatus.ambiguous, legs, rule.id);
    _put(e);
    _ambiguousReview(rule, f, cands, eventId: e.eventId);
    return e.eventId;
  }

  void _ambiguousReview(
    LinkRule rule,
    Fact f,
    List<_Cand> cands, {
    String? eventId,
  }) {
    final id = 'link:ambiguous:${f.factId}';
    reviews[id] = ReviewItem(
      kind: ReviewKind.event,
      payload: {
        'reviewId': id,
        'reason': 'ambiguous_link',
        'eventId': eventId,
        'factId': f.factId,
        'linkRuleId': rule.id,
        'candidates': [
          for (final c in cands)
            {
              'eventId': c.eventId,
              'factId': c.fact.factId,
              'role': c.role.wire,
            },
        ],
      },
    );
  }

  void _singleLegReview(LinkRule rule, Fact f, Event e) {
    final id = 'link:single:${f.factId}';
    reviews[id] = ReviewItem(
      kind: ReviewKind.event,
      payload: {
        'reviewId': id,
        'reason': 'missing_leg',
        'eventId': e.eventId,
        'factId': f.factId,
        'linkRuleId': rule.id,
      },
    );
  }

  /// After a debit makes or joins an event, receipts already seen for it join
  /// as `duplicate_notice`.
  void _afterMoney(Fact f, String eventId) {
    if (f is! MovementFact ||
        f.direction != Direction.debit ||
        f.evidenceOnly == true)
      return;
    final rule = _firstOf(LinkRuleKind.receipt);
    final a = _principal(f);
    if (rule == null || a == null) return;
    final e = events[eventId]!;
    if (e.status == EventStatus.userConfirmed ||
        e.status == EventStatus.ambiguous)
      return;
    final role = e.legs
        .where((l) => l.factId == f.factId)
        .map((l) => l.role)
        .firstOrNull;
    if (role != LegRole.debitLeg && role != LegRole.charge) return;
    final receipts = <_Cand>[];
    for (final r in byAmount[a] ?? const <Fact>[]) {
      if (r is! MovementFact ||
          r.evidenceOnly != true ||
          r.direction != Direction.debit)
        continue;
      if (eventOfFact.containsKey(r.factId) ||
          ambiguousReceipts.contains(r.factId))
        continue;
      if (r.sourceKey == f.sourceKey || _isPartialWalletFact(r)) continue;
      if (!_within(f, r, rule.join.windowHours)) continue;
      receipts.add(_Cand.fact(r, LegRole.duplicateNotice));
    }
    if (receipts.isEmpty) return;
    var list = _narrow(rule, f, receipts);
    if (list.length > 1) {
      // Receipts never count, so the closest one is good enough.
      list = [...list]
        ..sort((x, y) {
          final c = _distance(f, x.fact).compareTo(_distance(f, y.fact));
          return c != 0 ? c : x.fact.factId.compareTo(y.fact.factId);
        });
    }
    final r = list.first.fact;
    final legs = [
      ...e.legs,
      EventLeg(factId: r.factId, role: LegRole.duplicateNotice),
    ];
    _put(
      _build(
        e.eventId,
        e.type,
        e.status,
        legs,
        e.linkRuleId ?? rule.id,
        prior: e,
      ),
    );
  }

  /// A debit that arrives after the user answered "Yes, I paid it" for its
  /// receipt is the same payment, which the confirmed event already counts: it
  /// becomes a one-leg `unknown` event (no money), so the payment counts once.
  /// The confirmed event itself is never changed (user_confirmed).
  bool _lateFundingDebit(MovementFact f) {
    final rule = _firstOf(LinkRuleKind.receipt);
    final a = _principal(f);
    if (rule == null || a == null) return false;
    for (final r in byAmount[a] ?? const <Fact>[]) {
      if (r is! MovementFact ||
          r.evidenceOnly != true ||
          r.direction != Direction.debit ||
          r.sourceKey == f.sourceKey ||
          !_within(f, r, rule.join.windowHours)) {
        continue;
      }
      final eventId = eventOfFact[r.factId];
      final e = eventId == null ? null : events[eventId];
      if (e == null || e.status != EventStatus.userConfirmed) continue;
      final confirmed = e.legs.any(
        (l) =>
            _moneyRoles.contains(l.role) &&
            facts[l.factId]?.provenance.ruleId == kReceiptConfirmedRuleId,
      );
      if (!confirmed) continue;
      _put(
        _build(f.factId, EventType.unknown, EventStatus.complete, [
          EventLeg(factId: f.factId, role: LegRole.duplicateNotice),
        ], rule.id),
      );
      return true;
    }
    return false;
  }

  /// A biller's or app's receipt: joins the debit it confirms, never makes an
  /// event of its own.
  void _processReceipt(MovementFact f) {
    if (_isPartialWalletFact(f))
      return; // wallet activity only: no event, no review
    final rule = _firstOf(LinkRuleKind.receipt);
    final a = _principal(f);
    if (rule == null || a == null) return;
    final byEvent = <String, _Cand>{};
    for (final g in byAmount[a] ?? const <Fact>[]) {
      if (g is! MovementFact ||
          g.direction != Direction.debit ||
          g.evidenceOnly == true)
        continue;
      if (!processed.contains(g.factId) || g.sourceKey == f.sourceKey) continue;
      if (!_within(f, g, rule.join.windowHours)) continue;
      final eventId = eventOfFact[g.factId];
      if (eventId == null || byEvent.containsKey(eventId)) continue;
      final e = events[eventId]!;
      if (e.status == EventStatus.userConfirmed ||
          e.status == EventStatus.ambiguous)
        continue;
      final role = e.legs.firstWhere((l) => l.factId == g.factId).role;
      if (role != LegRole.debitLeg && role != LegRole.charge) continue;
      byEvent[eventId] = _Cand.event(eventId, g, role);
    }
    if (byEvent.isEmpty) return; // [reviewReceipts] decides later

    final list = _narrow(rule, f, [...byEvent.values]);
    if (list.length > 1) {
      ambiguousReceipts.add(f.factId);
      _ambiguousReview(rule, f, list);
      return;
    }
    final e = events[list.single.eventId]!;
    final legs = [
      ...e.legs,
      EventLeg(factId: f.factId, role: LegRole.duplicateNotice),
    ];
    _put(
      _build(
        e.eventId,
        e.type,
        e.status,
        legs,
        e.linkRuleId ?? rule.id,
        prior: e,
      ),
    );
  }

  /// A receipt with no funding debit and no event, in arrival order.
  List<MovementFact> _unpaidReceipts() => [
    for (final f in facts.values)
      if (f is MovementFact &&
          f.evidenceOnly == true &&
          f.direction == Direction.debit &&
          !eventOfFact.containsKey(f.factId) &&
          !_isPartialWalletFact(f))
        f,
  ]..sort(_arrival);

  /// True when a non-receipt debit of the receipt's amount sits inside the
  /// join window, whatever event it is in (an ambiguous or confirmed one
  /// cannot take the receipt as a leg, but the payment is not missing).
  bool _hasFundingDebit(MovementFact r, LinkRule rule) {
    final a = _principal(r);
    if (a == null) return false;
    for (final g in byAmount[a] ?? const <Fact>[]) {
      if (g is MovementFact &&
          g.direction == Direction.debit &&
          g.evidenceOnly != true &&
          g.sourceKey != r.sourceKey &&
          _within(r, g, rule.join.windowHours)) {
        return true;
      }
    }
    return false;
  }

  void _raiseReceiptReviews(Set<String> alreadyRaised) {
    final rule = _firstOf(LinkRuleKind.receipt);
    if (rule == null) return;
    final keys = <String>{};
    for (final f in _unpaidReceipts()) {
      final disposition = receiptDisposition(receiptAt: _latest(f), now: now);
      if (disposition != ReceiptDisposition.review) continue;
      final id = 'link:receipt:${f.factId}';
      final key = receiptDedupeKey(f);
      if (alreadyRaised.contains(id) ||
          alreadyRaised.contains(key) ||
          alreadyRaised.contains('link:ambiguous:${f.factId}') ||
          ambiguousReceipts.contains(f.factId) ||
          !keys.add(key) ||
          _hasFundingDebit(f, rule)) {
        continue;
      }
      _receiptReview(f, key);
    }
  }

  void _receiptReview(MovementFact f, String dedupeKey) {
    final id = 'link:receipt:${f.factId}';
    final biller =
        f.counterparty?.name ?? f.instrument?.issuerSlug ?? 'a biller';
    final minor = _principal(f) ?? 0;
    final cardBill = f.purpose == MovementPurpose.cardPayment;
    reviews[id] = ReviewItem(
      kind: ReviewKind.event,
      payload: {
        'reviewId': id,
        'reason': kReceiptWithoutPaymentReason,
        'factId': f.factId,
        'dedupeKey': dedupeKey,
        'biller': biller,
        'amountMinor': minor,
        'receiptAt': _latest(f).toUtc().toIso8601String(),
        'cardBill': cardBill,
        'purpose': f.purpose.wire,
        'message': kReceiptReviewTextEn.question(
          cardBill: cardBill,
          amount: formatReceiptRupees(minor),
          date: formatReceiptDate(_latest(f)),
          app: biller,
        ),
      },
    );
  }

  /// One-time and IPO mandates join their hold's `ipo_application` event.
  void _attachIpoMandates() {
    for (final m in pendingIpoMandates) {
      Event? target;
      for (final e in events.values) {
        if (e.type != EventType.ipoApplication ||
            e.status == EventStatus.userConfirmed)
          continue;
        if (e.legs.any((l) => l.role == LegRole.original)) continue;
        final placedId = e.legs
            .where((l) => l.role == LegRole.holdPlaced)
            .map((l) => l.factId)
            .firstOrNull;
        final placed = placedId == null ? null : facts[placedId];
        if (placed == null) continue;
        final sameMessage = placed.sourceKey == m.sourceKey;
        final sameBlock =
            _instId(placed) != null &&
            _instId(placed) == _instId(m) &&
            _principal(placed) == m.amount(AmountRole.ceiling)?.minor &&
            _distance(placed, m) <= _day;
        if (sameMessage || sameBlock) {
          target = e;
          if (sameMessage) break;
        }
      }
      if (target == null) continue;
      final legs = [
        ...target.legs,
        EventLeg(factId: m.factId, role: LegRole.original),
      ];
      _put(
        _build(
          target.eventId,
          target.type,
          target.status,
          legs,
          target.linkRuleId,
          prior: target,
        ),
      );
    }
  }

  // ------------------------------------------------------------ event shape

  EventType _typeFor(LinkRule rule, List<EventLeg> legs) {
    if (rule.eventType == EventType.walletTopup && _intoPartialWallet(legs)) {
      return EventType.purchase; // Amazon Pay: the top-up is the spend
    }
    return rule.eventType;
  }

  EventStatus _statusFor(LinkRule rule, List<EventLeg> legs) {
    if (kinds[rule] != LinkRuleKind.ipo) return EventStatus.complete;
    int? held;
    var debited = 0;
    var released = 0;
    var any = false;
    for (final l in legs) {
      final f = facts[l.factId];
      if (f == null) continue;
      switch (l.role) {
        case LegRole.holdPlaced:
          held = f.amount(AmountRole.held)?.minor ?? _principal(f);
        case LegRole.debitLeg:
          debited += _principal(f) ?? 0;
          any = true;
        case LegRole.holdReleased:
          released +=
              f.amount(AmountRole.released)?.minor ?? _principal(f) ?? 0;
          any = true;
        default:
          break;
      }
    }
    if (held == null)
      return any ? EventStatus.complete : EventStatus.awaitingLeg;
    return debited + released >= held
        ? EventStatus.complete
        : EventStatus.awaitingLeg;
  }

  bool _standsAlone(LinkRule rule, LegRole role, Fact f) {
    switch (kinds[rule]!) {
      case LinkRuleKind.cardBill:
      case LinkRuleKind.walletTopup:
        return role == LegRole.debitLeg || role == LegRole.creditLeg;
      case LinkRuleKind.ipo:
        return role == LegRole.holdPlaced;
      case LinkRuleKind.ownTransfer:
        if (role == LegRole.debitLeg) return _isOwnDebit(f);
        if (role == LegRole.creditLeg) return _isOwnCredit(f);
        return false;
      case LinkRuleKind.mandateCharge:
      case LinkRuleKind.refund:
      case LinkRuleKind.receipt:
      case LinkRuleKind.duplicateNotice:
        return false; // the purpose typing below gives these their one-leg type
      case LinkRuleKind.generic:
        return role == rule.legs.first.role &&
            (role == LegRole.debitLeg ||
                role == LegRole.creditLeg ||
                role == LegRole.holdPlaced);
    }
  }

  /// A one-fact event typed by purpose and direction (WP-05 Build 4).
  ({EventType type, LegRole role, EventStatus status})? _fallback(Fact f) {
    const done = EventStatus.complete;
    switch (f) {
      case MovementFact(evidenceOnly: true):
        return null;
      case MovementFact():
        final debit = f.direction == Direction.debit;
        final role = debit ? LegRole.debitLeg : LegRole.creditLeg;
        if (debit &&
            f.mandateRef != null &&
            mandateChargePurposes.contains(f.purpose)) {
          return (
            type: EventType.subscriptionCharge,
            role: LegRole.charge,
            status: done,
          );
        }
        final type = switch (f.purpose) {
          MovementPurpose.purchase =>
            debit ? EventType.purchase : EventType.unknown,
          MovementPurpose.p2p => debit ? EventType.p2pOut : EventType.p2pIn,
          MovementPurpose.salary || MovementPurpose.interest =>
            debit ? EventType.unknown : EventType.income,
          MovementPurpose.refund || MovementPurpose.reversal =>
            debit ? EventType.unknown : EventType.refund,
          MovementPurpose.cashback =>
            debit ? EventType.unknown : EventType.cashback,
          MovementPurpose.atm =>
            debit ? EventType.atmWithdrawal : EventType.unknown,
          MovementPurpose.fee => debit ? EventType.fee : EventType.refund,
          MovementPurpose.emi => debit ? EventType.emi : EventType.unknown,
          MovementPurpose.billPayment =>
            debit ? EventType.billPayment : EventType.refund,
          MovementPurpose.tax =>
            debit ? EventType.billPayment : EventType.income,
          MovementPurpose.cardPayment => EventType.cardBillPayment,
          MovementPurpose.walletTopup =>
            _intoPartialWallet([EventLeg(factId: f.factId, role: role)])
                ? EventType.purchase
                : EventType.walletTopup,
          MovementPurpose.investment =>
            debit ? EventType.investment : EventType.investmentWithdrawal,
          MovementPurpose.dividend =>
            debit ? EventType.unknown : EventType.dividend,
          MovementPurpose.transfer =>
            debit
                ? (_isOwnDebit(f) ? EventType.ownTransfer : EventType.p2pOut)
                : (_isOwnCredit(f) ? EventType.ownTransfer : EventType.p2pIn),
          MovementPurpose.unknown => EventType.unknown,
        };
        return (type: type, role: role, status: done);
      case HoldFact():
        if (f.purpose != HoldPurpose.ipoAsba &&
            f.purpose != HoldPurpose.upiMandateBlock) {
          return null;
        }
        return switch (f.phase) {
          HoldPhase.placed => (
            type: EventType.ipoApplication,
            role: LegRole.holdPlaced,
            status: EventStatus.awaitingLeg,
          ),
          HoldPhase.released => (
            type: EventType.ipoApplication,
            role: LegRole.holdReleased,
            status: done,
          ),
          HoldPhase.converted => (
            type: EventType.ipoApplication,
            role: LegRole.holdConverted,
            status: EventStatus.awaitingLeg,
          ),
        };
      default:
        return null;
    }
  }

  /// Builds an event: amount and time from the earliest money leg (for an
  /// IPO, the debit only: the held amount is never the investment).
  Event _build(
    String eventId,
    EventType type,
    EventStatus status,
    List<EventLeg> legs,
    String? ruleId, {
    Event? prior,
  }) {
    Fact? money;
    var amount = 0;
    if (type == EventType.ipoApplication) {
      for (final l in legs) {
        if (l.role != LegRole.debitLeg) continue;
        final f = facts[l.factId];
        if (f == null) continue;
        amount += _principal(f) ?? 0;
        if (money == null || f.effectiveAt.isBefore(money.effectiveAt))
          money = f;
      }
    } else {
      for (final l in legs) {
        if (!_moneyRoles.contains(l.role)) continue;
        final f = facts[l.factId];
        if (f == null) continue;
        if (money == null || f.effectiveAt.isBefore(money.effectiveAt))
          money = f;
      }
      amount =
          (money == null ? null : _principal(money)) ?? prior?.amountMinor ?? 0;
    }
    final anchor = facts[eventId];
    final at =
        money?.effectiveAt ?? prior?.occurredAt ?? anchor?.effectiveAt ?? now;
    if (money == null && type != EventType.ipoApplication) {
      amount =
          prior?.amountMinor ??
          (anchor == null ? null : _principal(anchor)) ??
          0;
    }
    var confidence = 1.0;
    var seenAny = false;
    for (final l in legs) {
      final f = facts[l.factId];
      if (f == null) continue;
      seenAny = true;
      if (f.confidence < confidence) confidence = f.confidence;
    }
    if (!seenAny) confidence = prior?.confidence ?? 0;
    return Event(
      eventId: eventId,
      type: type,
      status: status,
      legs: legs,
      linkRuleId: ruleId,
      confidence: confidence.clamp(0.0, 1.0).toDouble(),
      occurredAt: at,
      amountMinor: amount,
    );
  }

  // --------------------------------------------------------------- helpers

  LinkRule? _ruleById(String? id) {
    if (id == null) return null;
    for (final r in rules) {
      if (r.id == id) return r;
    }
    return null;
  }

  LinkRule? _firstOf(LinkRuleKind kind) {
    for (final r in rules) {
      if (kinds[r] == kind) return r;
    }
    return null;
  }

  Instrument? _inst(Fact f) => _instCache.putIfAbsent(f.factId, () {
    final id = idByFact[f.factId];
    if (id != null) return context.instrumentsById[id];
    final m = f.instrument;
    if (m == null || m.issuerSlug == null) return null;
    if (m.maskDigits == null && m.kind == null) return null;
    Instrument? found;
    for (final i in context.instrumentsById.values) {
      if (i.issuerSlug != m.issuerSlug || i.status == InstrumentStatus.rejected)
        continue;
      if (m.kind != null && i.kind != m.kind) continue;
      if (m.maskDigits != null && i.maskDigits != m.maskDigits) continue;
      if (found != null) return null; // not unique
      found = i;
    }
    return found;
  });

  String? _instId(Fact f) => _inst(f)?.instrumentId;

  InstrumentKind? _instKind(Fact f) => _inst(f)?.kind ?? f.instrument?.kind;

  bool _sameInstrument(Fact a, Fact b) {
    final x = _instId(a);
    return x != null && x == _instId(b);
  }

  /// The destination named by [mask] is an own bank account (or the mask is
  /// not printed, or the account is not known).
  bool _maskOk(String? mask, String? instrumentMask) =>
      mask == null ||
      instrumentMask == null ||
      _maskMatch(mask, instrumentMask);

  static bool _maskMatch(String a, String b) => a.endsWith(b) || b.endsWith(a);

  bool _ownMask(String? mask, Fact f) {
    if (mask == null) return false;
    final self = _instId(f);
    for (final i in context.instrumentsById.values) {
      if (i.kind != InstrumentKind.bankAccount ||
          i.status == InstrumentStatus.rejected)
        continue;
      if (i.instrumentId == self || i.maskDigits == null) continue;
      if (_maskMatch(mask, i.maskDigits!)) return true;
    }
    return false;
  }

  bool _isOwnDebit(Fact d) =>
      d.counterparty?.kind == CounterpartyKind.own ||
      _ownMask(d.counterparty?.accountMask, d);

  bool _isOwnCredit(Fact c) => _isOwnDebit(c);

  bool _isIpoMandate(MandateFact m) =>
      m.oneTime == true || m.mandatePurpose == MandatePurpose.ipo;

  String? _topupIssuer(Fact d) {
    final cp = d.counterparty;
    if (cp == null) return null;
    for (final t in linker._topups) {
      if ((cp.vpa != null && (t.vpa?.hasMatch(cp.vpa!) ?? false)) ||
          (cp.name != null && (t.name?.hasMatch(cp.name!) ?? false))) {
        return t.issuerSlug;
      }
    }
    return null;
  }

  bool _intoPartialWallet(List<EventLeg> legs) {
    final partial = linker.partialWalletIssuers;
    if (partial.isEmpty) return false;
    for (final l in legs) {
      final f = facts[l.factId];
      if (f is! MovementFact || f.purpose != MovementPurpose.walletTopup)
        continue;
      final issuer = f.direction == Direction.debit
          ? _topupIssuer(f)
          : (_inst(f)?.issuerSlug ?? f.instrument?.issuerSlug);
      if (issuer != null && partial.contains(issuer)) return true;
    }
    return false;
  }

  bool _isPartialWalletFact(Fact f) {
    final issuer = _inst(f)?.issuerSlug ?? f.instrument?.issuerSlug;
    if (issuer == null || !linker.partialWalletIssuers.contains(issuer))
      return false;
    final k = _instKind(f);
    return k == null || k == InstrumentKind.wallet;
  }

  /// The amount a fact moves, with its unit.
  static ({String unit, int minor})? _priced(Fact f) {
    final a = switch (f) {
      MovementFact() => f.amount(AmountRole.posted),
      HoldFact() => f.amount(AmountRole.held) ?? f.amount(AmountRole.released),
      MandateFact() => f.amount(AmountRole.ceiling),
      AttemptFact() =>
        f.amount(AmountRole.posted) ?? f.amount(AmountRole.scheduled),
      _ => null,
    };
    return a == null ? null : (unit: a.unit, minor: a.minor);
  }

  /// The rupee amount (paise) a fact moves, or null. A foreign-only amount
  /// (CCR-004) is never paise: it cannot be compared with one, indexed beside
  /// one or become an event's amount.
  static int? _principal(Fact f) {
    final p = _priced(f);
    return p != null && p.unit == 'INR' ? p.minor : null;
  }

  static DateTime _latest(Fact f) =>
      f.effectiveAt.isAfter(f.observedAt) ? f.effectiveAt : f.observedAt;

  /// The smaller of the printed-time and the received-time distances: a
  /// printed date without a time (IST midnight) must not push two messages a
  /// minute apart outside a 10-minute window.
  static Duration _distance(Fact a, Fact b) {
    final x = a.effectiveAt.difference(b.effectiveAt).abs();
    final y = a.observedAt.difference(b.observedAt).abs();
    return x < y ? x : y;
  }

  static Duration _hours(num h) =>
      Duration(microseconds: (h * Duration.microsecondsPerHour).round());

  static bool _within(Fact a, Fact b, num hours) =>
      _distance(a, b) <= _hours(hours);

  static Set<String> _refs(Fact f) => {
    ...f.references.values,
    if (f is MovementFact && f.mandateRef != null) f.mandateRef!,
  };

  /// Both carry the same kind of reference (two UTRs, two transaction ids)
  /// and the values differ: two payments. References of different kinds (an
  /// application number and a bank reference) say nothing.
  static bool _conflictingRefs(Fact a, Fact b) {
    for (final e in a.references.entries) {
      final other = b.references[e.key];
      if (other != null && other != e.value) return true;
    }
    return false;
  }

  static bool _sharesRef(Fact a, Fact b) {
    final x = _refs(a);
    if (x.isEmpty) return false;
    return _refs(b).any(x.contains);
  }

  /// The other side's name: counterparty name or UPI handle, a mandate's
  /// merchant, or an IPO hold's issue.
  static String? _party(Fact f) {
    final cp = f.counterparty;
    final name = switch (f) {
      MandateFact() => f.merchantName ?? cp?.name,
      HoldFact() => f.issueName ?? cp?.name,
      _ => cp?.name,
    };
    if (name != null && name.trim().isNotEmpty) return name;
    final vpa = cp?.vpa;
    if (vpa != null && vpa.contains('@')) return vpa.split('@').first;
    return null;
  }

  static const _noise = {
    'LTD',
    'LIMITED',
    'PVT',
    'PRIVATE',
    'IPO',
    'INDIA',
    'IN',
    'THE',
    'CO',
    'INC',
  };

  static final _nonWord = RegExp(r'[^A-Z0-9]+');
  final _keys = <String, String>{};

  String _key(String? s) {
    if (s == null) return '';
    return _keys.putIfAbsent(s, () {
      final tokens = s
          .toUpperCase()
          .replaceAll(_nonWord, ' ')
          .trim()
          .split(' ')
          .where((t) => t.isNotEmpty && !_noise.contains(t))
          .toList();
      return tokens.join(' ');
    });
  }

  /// Index keys under which two names [_sameParty] would match share one.
  List<String> _partyKeys(String? name) {
    final k = _key(name);
    if (k.isEmpty) return const [];
    final compact = k.replaceAll(' ', '');
    return [
      'T:${k.split(' ').first}',
      'P:${compact.length > 5 ? compact.substring(0, 5) : compact}',
    ];
  }

  bool _sameParty(String? a, String? b) {
    final x = _key(a);
    final y = _key(b);
    if (x.isEmpty || y.isEmpty) return false;
    if (x == y) return true;
    final cx = x.replaceAll(' ', '');
    final cy = y.replaceAll(' ', '');
    if (cx == cy) return true;
    if (cx.length >= 5 &&
        cy.length >= 5 &&
        (cx.startsWith(cy) || cy.startsWith(cx)))
      return true;
    final fx = x.split(' ').first;
    final fy = y.split(' ').first;
    return fx.length >= 4 && fx == fy;
  }

  bool _namesCompatible(String? a, String? b) =>
      _key(a).isEmpty || _key(b).isEmpty || _sameParty(a, b);
}
