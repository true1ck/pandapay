/// The evidence solver (tier 2): reads one SMS the way a person does, without
/// knowing the bank's template. It looks for independent pieces of evidence
/// (a completed-money cue, an amount and what it means, an instrument, a
/// counterparty, dates and what each date is for), checks that they agree, and
/// either accepts the reading or leaves it as a candidate for review.
///
/// This file is mechanism only. Every word it recognises and every threshold
/// comes from the [SolverPack].
library;

import 'dart:math' as math;

import 'solver_pack.dart';
import 'solver_text.dart';

enum SolverRead {
  /// Money out / money in that really moved.
  debit,
  credit,

  /// Card bill settled: the credit leg on the card, or the debit that funds it.
  cardPayment,
  ownTransfer,
  walletTopup,
  investment,

  /// A bill or statement waiting to be paid, or a reminder of one.
  billDue,

  /// A biller's receipt / e-bill for something already paid. Evidence only.
  billReceipt,

  /// A debit that is going to happen (autopay notice, upcoming renewal).
  scheduled,

  /// A standing instruction set up, changed or ended.
  mandate,

  /// Reward coins / points redeemed for value: activity only, never spending.
  redemption,

  /// Money that was blocked (an IPO application) is available again.
  holdRelease,

  /// "We have received your request": acknowledged, nothing has moved yet.
  requestPending,
  balance,
  failed,
  promo,
  info,
  unclear,
}

enum SolverVerdict {
  /// Confident enough to act on without asking.
  accept,

  /// Not confident: goes on to review / the AI drafter.
  candidate,
}

class SolverDecision {
  const SolverDecision({
    required this.read,
    required this.verdict,
    required this.score,
    this.minor,
    this.unit,
    this.originalMinor,
    this.originalUnit,
    this.mask,
    this.instrumentKind,
    this.party,
    this.partyIsVpa = false,
    this.debitDirection,
    this.evidenceOnly = false,
    this.rail,
    this.purpose,
    this.dueMinorMinimum,
    this.dueDate,
    this.statementDate,
    this.scheduledDate,
    this.billerName,
    this.mandatePhase,
    this.mandatePurpose,
    this.frequency,
    this.oneTime,
    this.mandateRef,
    this.consumerRef,
    this.recurring = false,
    this.ownMasks = const [],
    this.attemptStatus,
    this.failureWasDeclined = false,
    this.reasons = const [],
  });

  final SolverRead read;
  final SolverVerdict verdict;

  /// 0..1 for movements; 1 for accepted non-money reads.
  final double score;

  /// The counted amount (INR minor units for a movement).
  final int? minor;
  final String? unit;

  /// For a foreign-currency spend: the amount in the foreign currency.
  final int? originalMinor;
  final String? originalUnit;

  /// Last digits of the instrument mask, if one was found.
  final String? mask;

  /// `bank_account`, `credit_card`, `debit_card`, `prepaid_card`, `wallet`, or null.
  final String? instrumentKind;
  final String? party;
  final bool partyIsVpa;

  /// True for money out, false for money in, null when there is no direction.
  final bool? debitDirection;

  /// A receipt that never counts as money by itself.
  final bool evidenceOnly;

  /// Contract wire values: `upi`, `card`, `imps`, `neft`, `rtgs`, `cheque`,
  /// `nach`, `wallet`, `cash`.
  final String? rail;

  /// A `MovementPurpose` wire value, when the wording says why.
  final String? purpose;

  /// Bills: the minimum due (the total is [minor]).
  final int? dueMinorMinimum;
  final SolverDate? dueDate;
  final SolverDate? statementDate;

  /// A date a scheduled debit is due.
  final SolverDate? scheduledDate;
  final String? billerName;

  /// A `MandatePhase` wire value for a mandate read.
  final String? mandatePhase;
  final String? mandatePurpose;
  final String? frequency;
  final bool? oneTime;
  final String? mandateRef;

  /// The biller's customer / consumer number a bill payment names ("for XX1234567").
  /// Used to chain the payment to the bill it settles.
  final String? consumerRef;

  /// The wording marks this as a recurring charge (subscription, renewal, autopay).
  final bool recurring;

  /// Last digits of the user's own accounts in an own transfer, from then to.
  final List<String> ownMasks;

  /// `failed`, `declined` for a failed attempt.
  final String? attemptStatus;
  final bool failureWasDeclined;

  /// Why, in order: the audit trail for shadow runs and admin review.
  final List<String> reasons;

  bool get accepted => verdict == SolverVerdict.accept;

  /// Whether this reading would change spending / income totals.
  bool get countsInTotals =>
      accepted &&
      !evidenceOnly &&
      (read == SolverRead.debit || read == SolverRead.credit);

  @override
  String toString() =>
      '${read.name}/${verdict.name} score=${score.toStringAsFixed(2)} amt=$minor mask=$mask party=$party';
}

class _Hit {
  _Hit(this.start, this.end, this.entry);
  final int start;
  final int end;
  final LexEntry entry;
}

class _Cue {
  _Cue(this.start, this.end, this.debit, this.how, {this.bank = false});
  final int start;
  final int end;
  final bool debit;

  /// `debit`, `credit`, `biller`, `receipt`, `implied`, `kind`.
  final String how;

  /// A verb only a bank uses ("debited from"): the message is a bank alert.
  final bool bank;
}

class _DateAt {
  _DateAt(this.index, this.date, this.role);
  final int index;
  final SolverDate date;
  final String? role;
}

class EvidenceSolver {
  EvidenceSolver(this.pack);

  final SolverPack pack;

  /// Longest text the solver reads. A real SMS (even a 10-part concatenation)
  /// is under this; anything longer is read up to the limit, which also bounds
  /// the cost of a hostile message.
  static const maxBody = 2000;

  /// Reads [body]. [observedAt] (UTC) is the day the message arrived; dates with
  /// no year and words like "today" are read against it.
  ///
  /// [senderBrand] is the normalised sender header (for example a biller's short
  /// code). It is only ever a last-resort name for a biller the text does not name.
  SolverDecision solve(
    String body, {
    DateTime? observedAt,
    String? senderBrand,
    String? senderKind,
  }) {
    final capped = body.length > maxBody ? body.substring(0, maxBody) : body;
    final text = SolverText.parse(capped);
    return _Run(
      pack,
      text,
      observedAt ?? DateTime.now().toUtc(),
      senderBrand,
      senderKind,
    ).run();
  }
}

const _istOffset = Duration(hours: 5, minutes: 30);

class _Run {
  _Run(this.pack, this.text, this.observedAt, this.senderBrand, this.senderKind)
    : toks = text.toks;

  final String? senderBrand;

  /// What the sender registry says the sender is (`wallet`, `bank`, ...), or null.
  final String? senderKind;

  final SolverPack pack;
  final SolverText text;
  final DateTime observedAt;
  final List<Tok> toks;
  final Map<String, List<_Hit>> _cache = {};
  final List<String> reasons = [];

  SolverParams get p => pack.params;

  /// The sender's local day when the message arrived.
  DateTime get _today {
    final l = observedAt.add(_istOffset);
    return DateTime.utc(l.year, l.month, l.day);
  }

  List<_Hit> hits(String name) => _cache.putIfAbsent(name, () {
    final out = <_Hit>[];
    for (final e in pack.lex(name)) {
      for (final h in e.phrase.findAll(toks)) {
        out.add(_Hit(h.start, h.end, e));
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  });

  bool same(int a, int b) => toks[a].sentence == toks[b].sentence;

  /// Bill wording that says something is still OWED ("is due", "overdue", "pay by"),
  /// as opposed to nouns that also appear in receipts ("bill of Rs 499 ... paid").
  List<_Hit> _strongDue() => hits('billDue').where((h) {
    final s = h.entry.phrase.source;
    return s.contains('due') ||
        s.contains('payable') ||
        s.contains('pay') ||
        s.contains('renew') ||
        s.contains('expir');
  }).toList();

  bool _voided(_Hit h) {
    final from = math.max(0, h.start - 3);
    for (final n in hits('negator')) {
      if (n.start >= from && n.end <= h.start && same(n.start, h.start)) {
        return true;
      }
    }
    // "will be Dr. from A/C XX1 and Cr. to X": one "will" governs both verbs (up to eight tokens).
    final farFrom = math.max(0, h.start - 8);
    for (final n in hits('futureMarker')) {
      if (n.start >= farFrom && n.end <= h.start && same(n.start, h.start)) {
        return true;
      }
    }
    // "credited ... when you spend Rs 5,000": a promise, not an event.
    for (final n in hits('conditional')) {
      if (n.start >= h.end && n.start - h.end <= 8 && same(h.start, n.start)) {
        return true;
      }
    }
    return false;
  }

  SolverDecision run() {
    final amts = [
      for (var i = 0; i < toks.length; i++)
        if (toks[i].kind == TokKind.amt) i,
    ];
    final role = _roles(amts);
    // "Rs 2.50 per share" is a rate, never an amount received or paid: the amount
    // right before "per share" is marked so no later step can pick it as the money.
    for (final h in hits('perShare')) {
      final before = amts.where((a) => a < h.start && h.start - a <= 3).toList();
      if (before.isNotEmpty) role[before.last] = 'per_share';
    }
    final eligible = [
      for (final a in amts)
        if (role[a] == null || role[a] == 'fee') a,
    ];
    final payable = [
      for (final a in eligible)
        if (role[a] != 'fee') a,
    ];

    final failed = hits('failed');
    final debit = hits('debit').where((h) => !_voided(h)).toList();
    final credit = hits('credit').where((h) => !_voided(h)).toList();
    final biller = hits('billerReceived').where((h) => !_voided(h)).toList();
    final paidReceipt = hits('paidReceipt').where((h) => !_voided(h)).toList();
    final completionOther = hits('completionOther');
    final debitIntent = hits('debitIntent');

    // "Funds of Rs 9,000 were transferred to your bank account" is money IN: a
    // directional verb followed by "to" + the user's own account word flips.
    bool toOwnAccount(_Hit h) {
      if (h.entry.kind != 'directional') return false;
      // "transferred to your own account X from Y" is an own transfer, handled below.
      if (hits('ownTransfer').isNotEmpty) return false;
      var i = h.end;
      if (i < toks.length && toks[i].kind == TokKind.amt) i++;
      if (i + 1 >= toks.length || toks[i].kind != TokKind.word) return false;
      final w = toks[i].lower;
      if (w != 'to' && w != 'into') return false;
      final owned = hits('ownMarker').any((m) => m.start == i + 1);
      return owned &&
          hits('instrumentKind').any(
            (k) =>
                k.start >= i + 2 && k.start <= i + 3 && k.entry.kind != 'phone',
          );
    }

    final cues = <_Cue>[
      for (final h in debit)
        _Cue(
          h.start,
          h.end,
          !toOwnAccount(h),
          toOwnAccount(h) ? 'credit' : 'debit',
          bank: h.entry.kind == 'bank',
        ),
      for (final h in credit) _Cue(h.start, h.end, false, 'credit'),
      for (final h in biller) _Cue(h.start, h.end, true, 'biller'),
      for (final h in paidReceipt) _Cue(h.start, h.end, true, 'receipt'),
      // "Your deposit of Rs X was processed": the provider confirms money it took.
      for (final h in hits('investment'))
        if (h.entry.kind == 'confirm') _Cue(h.start, h.end, true, 'receipt'),
    ];
    // "Recharge ... successful": a purpose that means money out, completed by a
    // word with no direction of its own. Always offered; the nearest cue wins.
    if (completionOther.isNotEmpty) {
      for (final h in debitIntent) {
        cues.add(_Cue(h.start, h.end, true, 'implied'));
      }
    }
    // Wording that itself says a specific kind of movement happened
    // ("added to your wallet") is a completion cue.
    {
      for (final name in const [
        'walletTopup',
        'cardPayment',
        'ownTransfer',
        'investment',
      ]) {
        for (final h in hits(name)) {
          if (!h.entry.cue || _voided(h)) continue;
          if (name == 'investment' && completionOther.isEmpty) continue;
          cues.add(_Cue(h.start, h.end, true, 'kind'));
        }
      }
    }

    // 1. Failed attempts never move money.
    // A failed cue wins over any completed-looking word: when the message says it
    // failed, no money moved ("debit failed", "withdrawal could not be processed").
    if (failed.isNotEmpty) {
      reasons.add('failed cue "${_s(failed.first)}"');
      // "reversed to your card for failed transaction": money may be coming back
      // that was counted earlier. Never written as a plain failure.
      final hold = hits('holdForReview');
      if (hold.isNotEmpty) {
        reasons.add('review-only wording "${_s(hold.first)}"');
        return _done(SolverRead.failed, SolverVerdict.candidate, 0.4);
      }
      return _failed(failed.first, eligible, role);
    }

    // 1b. Reward coins redeemed: money-shaped, but not money out of an account.
    final redeem = hits('coinRedemption');
    if (redeem.isNotEmpty && payable.isNotEmpty && toks[payable.first].unit == 'INR') {
      reasons.add('redemption: "${_s(redeem.first)}"');
      return _done(SolverRead.redemption, SolverVerdict.accept, 1, amount: toks[payable.first]);
    }

    // 1c. A dividend announcement that states only per-share amounts: the amount
    // received is in the bank's own credit alert, so this one is not money.
    final perShare = hits('perShare');
    if (hits('dividendNotice').isNotEmpty &&
        perShare.isNotEmpty &&
        amts.every((a) => role[a] == 'per_share')) {
      reasons.add('dividend announcement with per-share amounts only');
      return _done(SolverRead.info, SolverVerdict.accept, 1);
    }

    // 1d. Blocked money available again (an IPO that was not allotted).
    final release = hits('holdRelease');
    if (release.isNotEmpty && payable.isNotEmpty && toks[payable.first].unit == 'INR') {
      reasons.add('hold released: "${_s(release.first)}"');
      return _done(
        SolverRead.holdRelease,
        SolverVerdict.accept,
        1,
        amount: toks[payable.first],
        purpose: release.first.entry.kind ?? 'other',
      );
    }

    // 1e. "We have received your request": acknowledged, nothing has moved yet.
    final pending = hits('pendingRequest');
    if (pending.isNotEmpty &&
        payable.isNotEmpty &&
        toks[payable.first].unit == 'INR' &&
        !cues.any((c) => c.how == 'debit' || c.how == 'credit' || c.how == 'biller')) {
      reasons.add('request acknowledged: "${_s(pending.first)}"');
      return _done(
        SolverRead.requestPending,
        SolverVerdict.accept,
        1,
        amount: toks[payable.first],
        purpose: hits('investment').isNotEmpty ? 'investment' : 'purchase',
      );
    }

    // 2. Nothing completed: notices about what will, or did not yet, happen. A
    // receipt-style word beside a due notice is not a completion either: the
    // bill path decides (and distrusts a message that reports both).
    final hasHardCue = cues.any(
      (c) =>
          c.how == 'debit' ||
          c.how == 'credit' ||
          c.how == 'biller' ||
          c.how == 'kind',
    );
    if (cues.isEmpty || (!hasHardCue && _strongDue().isNotEmpty)) {
      final r = _notCompleted(amts, role, eligible, payable);
      if (r != null) return r;
    }

    // 3. Something completed.
    if (cues.isNotEmpty) {
      return _completed(cues, eligible, role, amts);
    }

    // 4. Security wording with nothing completed: never review material.
    final security = hits('security');
    if (security.isNotEmpty) {
      final codeFollows = security.any((h) {
        for (var i = h.end; i < toks.length && i <= h.end + 5; i++) {
          final t = toks[i];
          if ((t.kind == TokKind.num || t.kind == TokKind.ref) &&
              RegExp(r'^\d{4,8}$').hasMatch(t.text)) {
            return true;
          }
        }
        return false;
      });
      // A security footer ("Never share OTP") on a real amount notice does not
      // make it ignorable: only a message carrying a code, or no money, does.
      if (codeFollows || payable.isEmpty) {
        reasons.add('security wording "${_s(security.first)}"');
        return _done(SolverRead.info, SolverVerdict.accept, 1);
      }
      reasons.add('security footer on an amount notice: left for review');
      return _done(SolverRead.unclear, SolverVerdict.candidate, 0.2);
    }

    // 5. Promotions need positive evidence; checked before balances because an
    // offer often quotes "up to Rs X".
    final promo = hits('promo');
    if (promo.isNotEmpty) {
      reasons.add('promo cue "${_s(promo.first)}"');
      return _done(SolverRead.promo, SolverVerdict.accept, 1);
    }

    // 6. Only balances / limits (or fees quoted in passing).
    if (amts.isNotEmpty && payable.isEmpty) {
      final isBalance = role.values.any(
        (r) => r == 'balance' || r == 'credit_avail' || r == 'credit_limit',
      );
      reasons.add(
        isBalance
            ? 'amounts are balances or limits'
            : 'amounts are fees or notes, nothing completed',
      );
      final balanceAmt = amts.where((a) => role[a] == 'balance').toList();
      final m = _mask(null, amts.first);
      return _done(
        isBalance ? SolverRead.balance : SolverRead.info,
        SolverVerdict.accept,
        1,
        amount: balanceAmt.length == 1 ? toks[balanceAmt.first] : null,
        mask: m,
      );
    }

    // 7. Nothing to count: no amount means no money to lose.
    if (amts.isEmpty) {
      reasons.add('no amount');
      return _done(SolverRead.info, SolverVerdict.accept, 1);
    }

    // An amount, no cue we know: never drop it silently.
    reasons.add('amount without a known cue');
    return _done(SolverRead.unclear, SolverVerdict.candidate, 0.2);
  }

  // ---- failed ----

  SolverDecision _failed(_Hit cue, List<int> eligible, Map<int, String> role) {
    final declined = _s(cue).toLowerCase().contains('declin');
    final amt = eligible.isEmpty ? null : toks[eligible.first];
    final m = _mask(true, eligible.isEmpty ? null : eligible.first);
    // "Declined for security reasons" with no amount is a fraud-prevention alert, not
    // a payment that failed.
    if ((amt == null || amt.unit != 'INR') &&
        hits('notice').any((n) => _s(n).toLowerCase().contains('security'))) {
      reasons.add('a declined notice for security reasons, no amount: an alert');
      return _done(SolverRead.info, SolverVerdict.accept, 1);
    }
    // A report or an application status mentions cards and credit without being a
    // payment: nothing to review when no amount is printed.
    if ((amt == null || amt.unit != 'INR') && hits('nonMoneyUnit').isNotEmpty) {
      reasons.add('a failed notice about a report or application, not a payment');
      return _done(SolverRead.info, SolverVerdict.accept, 1);
    }
    if ((amt == null || amt.unit != 'INR') && hits('financialWord').isEmpty) {
      // "We couldn't deliver your package": a failure of something that is not a
      // payment. Nothing financial to review.
      reasons.add('a failed notice with no payment wording: not financial');
      return _done(SolverRead.info, SolverVerdict.accept, 1);
    }
    if (amt == null || amt.unit != 'INR') {
      // A failed-payment notice with no printed amount is financial: it stays in
      // review rather than being ignored or given an invented amount.
      reasons.add(
        'failed notice without a printed rupee amount: left for review',
      );
      return _done(SolverRead.failed, SolverVerdict.candidate, 0.5, mask: m);
    }
    return _done(
      SolverRead.failed,
      SolverVerdict.accept,
      1,
      amount: amt,
      mask: m,
      attemptStatus: declined ? 'declined' : 'failed',
    );
  }

  // ---- nothing completed ----

  SolverDecision? _notCompleted(
    List<int> amts,
    Map<int, String> role,
    List<int> eligible,
    List<int> payable,
  ) {
    final mandateEnd = hits('mandateEnd');
    final mandateSetup = hits('mandateSetup');
    final upcoming = hits('scheduled');
    final notice = hits('notice');
    final billDue = hits('billDue');
    final generated = hits('generated');
    final recurring = hits('recurring');
    final paid = hits('paidReceipt');

    // A mandate ended: cancelled, revoked, expired, paused.
    if (mandateEnd.isNotEmpty) {
      final h = mandateEnd.first;
      reasons.add('mandate ended: "${_s(h)}"');
      return _done(
        SolverRead.mandate,
        SolverVerdict.accept,
        1,
        mandatePhase: h.entry.kind ?? 'revoked',
        mandateRef: _mandateRef(),
        party: _merchantNear(h.start),
        mandatePurpose: _mandatePurpose(recurring.isNotEmpty),
      );
    }

    // A mandate set up or awaiting approval.
    if (mandateSetup.isNotEmpty) {
      final h = mandateSetup.first;
      reasons.add('mandate set-up: "${_s(h)}"');
      final amt = payable.isEmpty ? null : toks[payable.first];
      final party = _merchantNear(h.start);
      final freq = _frequency();
      final enough = party != null || amt != null || recurring.isNotEmpty;
      return _done(
        SolverRead.mandate,
        enough ? SolverVerdict.accept : SolverVerdict.candidate,
        enough ? 1 : 0.4,
        amount: amt != null && amt.unit == 'INR' ? amt : null,
        mandatePhase: 'created',
        mandateRef: _mandateRef(),
        party: party,
        frequency: freq.$1,
        oneTime: freq.$2,
        mandatePurpose: _mandatePurpose(recurring.isNotEmpty),
      );
    }

    // A paid bill / e-bill: the receipt for something already settled.
    final billNoun = hits('billNoun');
    if (paid.isNotEmpty &&
        billNoun.isNotEmpty &&
        payable.isNotEmpty &&
        billDue.isEmpty) {
      // Handled as a completed receipt (cue added below by the caller).
      return null;
    }

    // A bill / statement / reminder waiting to be paid. "Expires on" alone is a
    // bill only for something that is billed (a membership, policy, plan): a
    // wallet balance that expires is not.
    final billCues = [
      for (final h in billDue)
        if (!h.entry.phrase.source.contains('expir') || billNoun.isNotEmpty) h,
    ];
    if (billCues.isNotEmpty || (generated.isNotEmpty && billNoun.isNotEmpty)) {
      return _billDue(
        amts,
        role,
        billCues.isNotEmpty ? billCues.first : generated.first,
        paid.isNotEmpty,
      );
    }

    // "Fund requested by X. On approval, Rs 500 will be debited": someone is
    // asking you for money. Nothing is scheduled and nothing is owed yet.
    if (notice.any((n) => _s(n).toLowerCase().contains('request'))) {
      reasons.add(
        'a money request, not a scheduled debit: "${_s(notice.firstWhere((n) => _s(n).toLowerCase().contains('request')))}"',
      );
      return _done(SolverRead.info, SolverVerdict.accept, 1);
    }

    // A debit that is going to happen.
    if (upcoming.isNotEmpty) {
      final h = upcoming.first;
      reasons.add('upcoming debit: "${_s(h)}"');
      if (payable.isEmpty) {
        reasons.add('upcoming debit without a printed amount: left for review');
        return _done(SolverRead.scheduled, SolverVerdict.candidate, 0.5);
      }
      final amt = toks[payable.first];
      if (amt.unit != 'INR') return null;
      final dates = _dates();
      // The date an upcoming debit happens on. A hyphenated "auto-debited on"
      // reads as a payment date, so any role except a statement or billing
      // period date is accepted here, preferring one marked as a due date.
      final due =
          dates.where((d) => d.role == 'due').map((d) => d.date).firstOrNull ??
          dates
              .where((d) => d.role != 'statement' && d.role != 'period')
              .map((d) => d.date)
              .firstOrNull ??
          _relativeDay();
      final said = _s(h).toLowerCase();
      final coming = said.contains('credit') || said.contains('refund');
      return _done(
        SolverRead.scheduled,
        SolverVerdict.accept,
        1,
        amount: amt,
        mask: _mask(!coming, payable.first),
        party: _merchantNear(h.start),
        scheduledDate: due,
        purpose: _purpose(!coming, null),
        recurring: recurring.isNotEmpty,
        debit: !coming,
      );
    }

    // Order / hold / request notices: no money moved.
    if (notice.isNotEmpty) {
      reasons.add('notice: "${_s(notice.first)}"');
      return _done(SolverRead.info, SolverVerdict.accept, 1);
    }
    return null;
  }

  // ---- bills ----

  SolverDecision _billDue(
    List<int> amts,
    Map<int, String> role,
    _Hit cue,
    bool alsoPaid,
  ) {
    reasons.add('bill cue "${_s(cue)}"');
    final money = [
      for (final a in amts)
        if (role[a] == null ||
            role[a] == 'due_total' ||
            role[a] == 'due_min' ||
            role[a] == 'fee')
          a,
    ];
    if (money.isEmpty) {
      // A due or renewal reminder that prints no amount holds no money and cannot
      // become a bill record, so there is nothing for a person to review.
      reasons.add('a due notice with no amount: nothing to record');
      return _done(SolverRead.info, SolverVerdict.accept, 1);
    }
    final totals = money.where((a) => role[a] == 'due_total').toList();
    final bare = money
        .where((a) => role[a] == null || role[a] == 'fee')
        .toList();
    final mins = money.where((a) => role[a] == 'due_min').toList();
    final totalIdx = totals.isNotEmpty
        ? totals.first
        : (bare.isNotEmpty ? bare.first : null);
    final Tok? total = totalIdx == null ? null : toks[totalIdx];
    final Tok? minimum = mins.isEmpty ? null : toks[mins.first];
    if (total == null) {
      reasons.add('only a minimum due is stated');
      return _done(SolverRead.billDue, SolverVerdict.candidate, 0.4);
    }
    final counted = total;
    if (counted.unit != 'INR') {
      reasons.add('bill amount is not in rupees');
      return _done(SolverRead.billDue, SolverVerdict.candidate, 0.3);
    }
    // A message that both reports a payment and a new bill is not trusted.
    if (alsoPaid) {
      reasons.add('reports a payment and a bill together');
      return _done(
        SolverRead.billDue,
        SolverVerdict.candidate,
        0.4,
        amount: counted,
      );
    }

    final dates = _dates(preferFuture: true);
    SolverDate? due = dates
        .where((d) => d.role == 'due')
        .map((d) => d.date)
        .firstOrNull;
    SolverDate? statement = dates
        .where((d) => d.role == 'statement')
        .map((d) => d.date)
        .firstOrNull;
    if (due == null) {
      // One undated date next to a due word is the due date; "today"/"tomorrow" too.
      final loose = dates.where((d) => d.role == null).toList();
      if (loose.length == 1 && statement == null) {
        due = loose.first.date;
      } else if (loose.length == 1 && statement != null) {
        due = loose.first.date;
      }
      due ??= _relativeDay();
    }
    if (due == null) {
      reasons.add('bill without a readable due date');
      // The account is kept so a caller with history can match the statement.
      final undatedMask = _mask(null, totalIdx ?? mins.first);
      return _done(
        SolverRead.billDue,
        SolverVerdict.candidate,
        0.5,
        amount: counted,
        mask: undatedMask,
        statementDate: statement,
      );
    }
    if (statement == null && hits('generated').isNotEmpty) {
      // "Your bill is ready": with no date printed, it was generated the day it arrived.
      final t = _today;
      statement = SolverDate(t.year, t.month, t.day);
      reasons.add('generated date taken from the day the notice arrived');
    }
    if (statement != null && statement == due) statement = null;
    final m = _mask(null, totalIdx ?? mins.first);
    var kind = m?.$2;
    // Only credit cards send statements with a minimum due.
    if (minimum != null && (kind == null || kind == 'card')) {
      kind = 'credit_card';
    }
    return _done(
      SolverRead.billDue,
      SolverVerdict.accept,
      1,
      amount: counted,
      mask: m == null ? null : (m.$1, kind),
      dueMinorMinimum: minimum?.minor,
      dueDate: due,
      statementDate: statement,
      billerName: _billerName(),
    );
  }

  // ---- completed money ----

  SolverDecision _completed(
    List<_Cue> cues,
    List<int> eligibleIn,
    Map<int, String> role,
    List<int> amts,
  ) {
    if (amts.isEmpty) {
      if (hits('nonMoneyUnit').isNotEmpty) {
        reasons.add('wording about points, a report or an application, not money');
        return _done(SolverRead.info, SolverVerdict.accept, 1);
      }
      // Receipt-style or purpose-only wording ("we acknowledge the receipt of your
      // application") with no amount is not money wording at all.
      if (cues.every((c) => c.how == 'receipt' || c.how == 'implied' || c.how == 'kind')) {
        reasons.add('receipt-style wording with no amount: not money');
        return _done(SolverRead.info, SolverVerdict.accept, 1);
      }
      // "Your account has been debited" with no amount is financial: review it.
      reasons.add(
        'completed money wording but no printed amount: left for review',
      );
      return _done(SolverRead.unclear, SolverVerdict.candidate, 0.3);
    }
    var eligible = eligibleIn;
    final receiptish = cues.any((c) => c.how == 'biller' || c.how == 'receipt');
    if (receiptish) {
      // A receipt quotes the bill amount ("bill of Rs 499 has been paid").
      eligible = [
        ...eligible,
        for (final a in amts)
          if (role[a] == 'due_total') a,
      ]..sort();
    }
    if (eligible.isEmpty) {
      reasons.add('completed cue but no payable amount');
      return _done(SolverRead.unclear, SolverVerdict.candidate, 0.3);
    }

    // The cue and amount that sit closest together, preferring the same sentence.
    _Cue? best;
    int? bestAmt;
    var bestD = 1 << 30;
    for (final c in cues) {
      for (final a in eligible) {
        final d = _dist(c, a);
        if (d < bestD) {
          bestD = d;
          best = c;
          bestAmt = a;
        }
      }
    }
    final cue = best!;
    final amtIdx = bestAmt!;
    final crossSentence = bestD >= 20;
    final span = crossSentence ? bestD - 20 : bestD;
    if (span > p.maxCueDistance) {
      reasons.add('completed cue is $span tokens from the amount');
      return _done(SolverRead.unclear, SolverVerdict.candidate, 0.3);
    }

    var other = 1 << 30;
    for (final c in cues) {
      if (c.debit != cue.debit) other = math.min(other, _dist(c, amtIdx));
    }
    final ambiguous = other < (1 << 30) && other - bestD < p.directionMargin;
    // "Refund of Rs X ... transferred / processed": the money comes BACK, however
    // the verb reads. Only a bank alert that names the account is trusted as a
    // real debit.
    // The refund word must sit right before the amount ("Refund of Rs X"); a
    // later "will be refunded if cancelled" about a debit is a promise, not this.
    final comesBack = hits('purposeCue').any(
      (h) =>
          (h.entry.kind == 'refund' || h.entry.kind == 'reversal') &&
          h.end <= amtIdx &&
          amtIdx - h.end <= 3 &&
          same(h.start, amtIdx),
    );
    final realBankDebit =
        cue.debit && cue.bank && _mask(true, amtIdx) != null;
    final flipped = cue.debit && comesBack && !realBankDebit;
    final debitDir = flipped ? false : cue.debit;
    if (flipped) {
      reasons.add('refund / reversal wording: a credit, not a debit');
    }

    final ownT = hits('ownTransfer');
    final wallet = hits('walletTopup');
    final cardPay = hits('cardPayment');
    final invest = hits('investment');
    // A credit that mentions a loan may be a disbursal, not income: review-only for credits.
    final hold = hits('holdForReview')
        .where((h) => h.entry.kind != 'credit' || !debitDir)
        .toList();
    final recurring = hits('recurring');
    final billNoun = hits('billNoun');
    final paidWords =
        hits('paidReceipt').isNotEmpty || hits('billerReceived').isNotEmpty;

    var amtTok = toks[amtIdx];
    int? origMinor;
    String? origUnit;
    if (amtTok.unit != 'INR') {
      final inr = _inrNear(amtIdx);
      if (inr == null) {
        reasons.add('foreign amount without a printed INR amount');
        return _done(
          SolverRead.unclear,
          SolverVerdict.candidate,
          0.4,
          amount: amtTok,
        );
      }
      origMinor = amtTok.minor;
      origUnit = amtTok.unit;
      amtTok = toks[inr];
    }

    final mask = _mask(debitDir, amtIdx);
    final party = _party(debitDir, amtIdx);
    // A subscription / mandate debit must name its merchant, or every unnamed one
    // would merge into a single "Unknown service" in the subscriptions list.
    (String, bool)? merchantParty = party;
    if (merchantParty == null &&
        (recurring.isNotEmpty || _mandateRef() != null)) {
      final m = _merchantNear(cue.start);
      if (m != null) merchantParty = (m, false);
    }
    final rail = hits('rail').isNotEmpty;
    final owns = hits('ownMarker');
    final named =
        senderKind == 'wallet' ||
        hits('instrumentKind').any(
      (k) =>
          k.entry.kind != 'phone' &&
          owns.any(
            (m) =>
                m.end <= k.start &&
                k.start - m.end <= 1 &&
                same(m.start, k.start),
          ),
    );
    final purposeWire = _purpose(debitDir, amtIdx);

    SolverRead kind;
    var evidenceOnly = false;
    if (ownT.isNotEmpty) {
      kind = SolverRead.ownTransfer;
      reasons.add('own-account wording "${_s(ownT.first)}"');
    } else if (wallet.isNotEmpty) {
      kind = SolverRead.walletTopup;
      reasons.add('wallet / margin top-up wording "${_s(wallet.first)}"');
    } else if (cardPay.isNotEmpty) {
      kind = SolverRead.cardPayment;
      reasons.add('card bill payment wording "${_s(cardPay.first)}"');
    } else if (invest.isNotEmpty) {
      kind = SolverRead.investment;
      reasons.add('investment wording "${_s(invest.first)}"');
    } else {
      kind = debitDir ? SolverRead.debit : SolverRead.credit;
    }
    var conflict = false;
    final undone = hits('undo').where((u) => same(u.start, amtIdx)).toList();
    if (kind == SolverRead.debit &&
        cue.how == 'debit' &&
        undone.any((u) => u.start > cue.end)) {
      conflict = true;
      reasons.add(
        'a charge that the same message says was taken back: "${_s(undone.first)}"',
      );
    }

    // The biller says it RECEIVED a payment on the user's card: that is the
    // card bill being paid, never a purchase.
    if (kind == SolverRead.debit && cue.how == 'biller' && mask?.$2 == 'card' ||
        kind == SolverRead.debit &&
            cue.how == 'biller' &&
            mask?.$2 == 'credit_card') {
      kind = SolverRead.cardPayment;
      reasons.add('biller received a payment on a card: card bill payment');
    }
    // A biller's receipt / e-bill: the debit is a separate bank alert, so this
    // never counts as money on its own. A bank-voice alert (a bank verb with the
    // account named) is the real debit and is not a receipt.
    final bankVoice = cue.bank && mask != null;
    // A provider's confirmation of a deposit / purchase is evidence of money out,
    // not a second debit: the bank's own alert (when there is one) is the debit.
    if (kind == SolverRead.investment && cue.how == 'receipt' && !bankVoice) {
      evidenceOnly = true;
      reasons.add('investment confirmation: evidence only, never counted by itself');
    }
    // A phrase that explicitly says a payment was received / already paid / has a
    // receipt is a receipt by itself; a plain "paid" needs a bill word beside it.
    final explicitReceipt = cue.how == 'biller' || cue.how == 'receipt';
    if (kind == SolverRead.debit &&
        !bankVoice &&
        (explicitReceipt ||
            (paidWords &&
                cue.how == 'debit' &&
                !cue.bank &&
                (billNoun.isNotEmpty ||
                    recurring.isNotEmpty ||
                    purposeWire == 'bill_payment' ||
                    purposeWire == 'emi')))) {
      kind = SolverRead.billReceipt;
      evidenceOnly = true;
      reasons.add('biller receipt: evidence only, never counted by itself');
    }
    // Two different accounts of the user's own are a move between own accounts.
    if ((kind == SolverRead.debit || kind == SolverRead.credit) &&
        _ownMasks().length >= 2) {
      kind = SolverRead.ownTransfer;
      reasons.add('two of the user\'s own accounts are named: own transfer');
    }
    // Kind wording that points the other way from a stated direction is not trusted.
    if ((kind == SolverRead.walletTopup || kind == SolverRead.cardPayment) &&
        cue.how == 'credit') {
      conflict = true;
      reasons.add('${kind.name} wording conflicts with a stated credit');
    }

    var score = 0.0;
    score += 0.40;
    reasons.add('${cue.how} cue at token ${cue.start}');
    score += crossSentence ? 0.10 : 0.25;
    reasons.add(
      'amount ${amtTok.minor} ${crossSentence ? "in another sentence" : "next to the cue"}',
    );
    if (!ambiguous) {
      score += 0.15;
    } else {
      reasons.add(
        'opposite direction cue is only ${other - bestD} tokens further',
      );
    }
    if (mask != null || party != null) {
      score += 0.15;
    } else if (named) {
      score += 0.10;
      reasons.add('own instrument named without digits');
    }
    if (rail) score += 0.05;
    if (cue.how == 'implied') score -= 0.05;

    // "get a voucher when your loan is credited! offer valid till today": a
    // promotion that merely contains the word. Only a bank-voice alert (a bank
    // verb with the account named) is trusted to carry an offer footer.
    // A weak marketing word ("claim now", "click to check") beside a credit to the
    // user's own named wallet is a footer, not a promotion.
    final strongPromo = [
      for (final h in hits('promo'))
        if (!(h.entry.kind == 'weak' && named && !debitDir)) h,
    ];
    if ((kind == SolverRead.debit || kind == SolverRead.credit) &&
        !bankVoice &&
        strongPromo.isNotEmpty) {
      conflict = true;
      reasons.add(
        'promotional wording beside the cue: "${_s(strongPromo.first)}"',
      );
    }

    // A reminder nudges; it does not report an event ("Reminder: Rs X was paid ... by 20-11").
    if ((kind == SolverRead.debit || kind == SolverRead.credit) &&
        hits('reminderWord').any((r) => same(r.start, amtIdx))) {
      conflict = true;
      reasons.add('reminder wording: not an event');
    }
    // A one-time mandate debit is a hold (an IPO block, a one-off authorisation),
    // not a spend: never counted without a person looking.
    final oneTimeMandate = _frequency().$2 == true && recurring.isNotEmpty;
    if (oneTimeMandate &&
        (kind == SolverRead.debit || kind == SolverRead.billReceipt)) {
      conflict = true;
      reasons.add('one-time mandate: a hold, not a spend');
    }
    // A purpose-only cue ("payment of ... successful") with no account or payee
    // is too thin to count: "card payment" could be the bill or a purchase.
    if (cue.how == 'implied' &&
        (kind == SolverRead.debit || kind == SolverRead.credit) &&
        mask == null &&
        party == null) {
      conflict = true;
      reasons.add('inferred from purpose only, with no instrument or payee');
    }

    var verdict = SolverVerdict.accept;
    if (score < p.accept) verdict = SolverVerdict.candidate;
    if (ambiguous || conflict) verdict = SolverVerdict.candidate;
    // A message that reports a payment AND announces a new bill is two stories.
    // Writing it as a receipt alone would lose the bill, so it goes to review.
    if (kind == SolverRead.billReceipt && _strongDue().isNotEmpty) {
      verdict = SolverVerdict.candidate;
      reasons.add('reports a payment and a new bill together');
    }
    if (mask == null && party == null && !rail && !named && !evidenceOnly) {
      verdict = SolverVerdict.candidate;
      reasons.add('no instrument, counterparty or rail');
    }
    if (hold.isNotEmpty) {
      verdict = SolverVerdict.candidate;
      reasons.add('review-only wording "${_s(hold.first)}"');
    }

    final freq = _frequency();
    final recur = recurring.isNotEmpty;
    final moneyKind = kind;
    // A subscription / mandate charge carries its mandate reference.
    final mandateRef = _mandateRef();
    String? mandatePurpose;
    if (moneyKind == SolverRead.debit || moneyKind == SolverRead.billReceipt) {
      if (recur || mandateRef != null) mandatePurpose = _mandatePurpose(recur);
    }

    return SolverDecision(
      read: kind,
      verdict: verdict,
      score: score.clamp(0, 1).toDouble(),
      minor: amtTok.minor,
      unit: amtTok.unit,
      originalMinor: origMinor,
      originalUnit: origUnit,
      mask: mask?.$1,
      instrumentKind:
          _instrumentWire(mask?.$2, kind) ?? (senderKind == 'wallet' ? 'wallet' : null),
      party: merchantParty?.$1,
      partyIsVpa: merchantParty?.$2 ?? false,
      debitDirection: kind == SolverRead.cardPayment && cue.how == 'biller'
          ? false
          : debitDir,
      evidenceOnly: evidenceOnly,
      rail: _rail(mask?.$2),
      purpose: purposeWire,
      dueDate: null,
      scheduledDate: null,
      mandatePurpose: mandatePurpose,
      frequency: freq.$1,
      oneTime: freq.$2,
      mandateRef: mandateRef,
      consumerRef: kind == SolverRead.billReceipt ? _consumerRef() : null,
      recurring: recur,
      ownMasks: kind == SolverRead.ownTransfer ? _ownMasks() : const [],
      billerName: kind == SolverRead.billReceipt ? _billerName() : null,
      reasons: reasons,
    );
  }

  String? _instrumentWire(String? kind, SolverRead read) {
    switch (kind) {
      case 'bank':
        return 'bank_account';
      case 'credit_card':
      case 'debit_card':
      case 'prepaid_card':
      case 'wallet':
        return kind;
      default:
        return null;
    }
  }

  // ---- wording -> contract values ----

  /// Why money moved, from the purpose words nearest the amount; null when the
  /// wording does not say.
  String? _purpose(bool debit, int? amtIdx) {
    final ph = hits('purposeCue');
    if (ph.isEmpty) return null;
    _Hit? best;
    var bestD = 1 << 30;
    for (final h in ph) {
      final d = amtIdx == null ? h.start : (h.start - amtIdx).abs();
      if (d < bestD) {
        bestD = d;
        best = h;
      }
    }
    return best?.entry.kind;
  }

  String? _rail(String? instrumentKind) {
    final rh = hits('rail').where((h) => h.entry.kind != null).toList();
    if (rh.isNotEmpty) return rh.first.entry.kind;
    if (instrumentKind == 'wallet') return 'wallet';
    if (instrumentKind == 'credit_card' ||
        instrumentKind == 'debit_card' ||
        instrumentKind == 'prepaid_card' ||
        instrumentKind == 'card') {
      return 'card';
    }
    return null;
  }

  (String?, bool?) _frequency() {
    final fh = hits('frequency');
    if (fh.isEmpty) return (null, null);
    final k = fh.first.entry.kind;
    if (k == 'once') return (null, true);
    return (k, false);
  }

  String _mandatePurpose(bool recurring) {
    if (hits('loanWord').isNotEmpty) return 'loan';
    if (hits('investment').isNotEmpty) return 'sip';
    if (recurring) return 'subscription';
    if (hits('billNoun').isNotEmpty) return 'bill';
    return 'other';
  }

  /// A long number right after "for" ("payment of INR 927 for XX60008413407"):
  /// the biller's consumer number, digits only.
  String? _consumerRef() {
    final id = RegExp(r'^(?:[xX*]{1,8})?(\d{6,})$');
    for (var i = 0; i + 1 < toks.length; i++) {
      if (toks[i].kind != TokKind.word || toks[i].lower != 'for') continue;
      var j = i + 1;
      // "for XX1234567" may be tokenised as the mask letters, then the number.
      final m = id.firstMatch(toks[j].text);
      if (m != null) return m.group(1);
      if (j + 1 < toks.length && RegExp(r'^[xX*]+$').hasMatch(toks[j].text)) {
        final n = RegExp(r'^(\d{6,})$').firstMatch(toks[j + 1].text);
        if (n != null) return n.group(1);
      }
    }
    return null;
  }

  String? _mandateRef() {
    for (final h in hits('mandateRefCue')) {
      var i = h.end;
      if (i < toks.length &&
          (toks[i].kind == TokKind.num || toks[i].kind == TokKind.ref) &&
          same(h.start, i)) {
        return toks[i].text;
      }
    }
    return null;
  }

  // ---- dates ----

  List<_DateAt> _dates({bool preferFuture = true}) {
    final out = <_DateAt>[];
    final roles = hits('dateRole');
    for (var i = 0; i < toks.length; i++) {
      if (toks[i].kind != TokKind.date) continue;
      final d = parseSolverDate(
        toks[i].text,
        _today,
        preferFuture: preferFuture,
      );
      if (d == null) continue;
      String? role;
      var bestGap = 1 << 30;
      for (final h in roles) {
        if (h.end > i || !same(h.end - 1, i)) continue;
        final gap = i - h.end;
        if (gap > 1) continue;
        if (gap < bestGap) {
          bestGap = gap;
          role = h.entry.role;
        }
      }
      out.add(_DateAt(i, d, role));
    }
    return out;
  }

  SolverDate? _relativeDay() {
    for (final h in hits('relativeDay')) {
      var kind = h.entry.kind ?? '';
      // "num@2": the number of days is the token two places into the phrase ("due in 3 days").
      if (kind.startsWith('num@')) {
        final at = h.start + (int.tryParse(kind.substring(4)) ?? -1);
        kind = at >= 0 && at < h.end ? toks[at].text : '';
      }
      final n = int.tryParse(kind);
      if (n == null || n < 0 || n > 365) continue;
      final d = _today.add(Duration(days: n));
      return SolverDate(d.year, d.month, d.day);
    }
    return null;
  }

  // ---- names ----

  /// The merchant a mandate or subscription is for: the words after a "for" /
  /// "to" / "of" next to the cue.
  String? _merchantNear(int cueIdx) {
    final cues = hits('merchantCue');
    final stop = {for (final h in hits('partyStop')) h.start};
    final nonParty = {for (final h in hits('nonParty')) h.start};
    final ordered = [...cues]
      ..sort(
        (a, b) => (a.start - cueIdx).abs().compareTo((b.start - cueIdx).abs()),
      );
    for (final c in ordered) {
      var i = c.end;
      final words = <String>[];
      while (i < toks.length &&
          words.length < p.partyMaxWords &&
          same(c.start, i)) {
        final t = toks[i];
        if (t.kind != TokKind.word || stop.contains(i)) break;
        if (words.isEmpty && nonParty.contains(i)) break;
        words.add(t.text);
        i++;
      }
      if (words.isNotEmpty) return words.join(' ');
    }
    return null;
  }

  /// The biller's name: the words just before the bill word ("... Energy bill").
  String? _billerName() {
    final nouns = hits('billNoun');
    if (nouns.isEmpty) return null;
    final generic = {for (final h in hits('billerStop')) h.start};
    final n = nouns.first;
    final words = <String>[];
    var i = n.start - 1;
    // Skip generic words right before the bill word ("electricity", "credit card").
    while (i >= 0 &&
        same(i, n.start) &&
        toks[i].kind == TokKind.word &&
        generic.contains(i)) {
      i--;
    }
    while (i >= 0 && words.length < 3 && same(i, n.start)) {
      final t = toks[i];
      if (t.kind != TokKind.word || generic.contains(i)) break;
      words.insert(0, t.text);
      i--;
    }
    if (words.isNotEmpty) return words.join(' ');
    return _brandName();
  }

  /// The sender header as a last-resort biller name (never a bare number).
  String? _brandName() {
    final b = senderBrand?.trim();
    if (b == null || b.length < 3 || RegExp(r'^\d+$').hasMatch(b)) return null;
    return b;
  }

  // ---- shared helpers ----

  int _dist(_Cue c, int a) {
    final d = a >= c.end ? a - c.end : (a < c.start ? c.start - 1 - a : 0);
    return d + (same(c.start, a) ? 0 : 20);
  }

  int? _inrNear(int a) {
    for (var i = a + 1; i < toks.length && i <= a + 12; i++) {
      if (toks[i].kind == TokKind.amt && toks[i].unit == 'INR') {
        final before = toks[i].start - 1;
        if (before >= 0 && text.body[before] == '(') return i;
      }
    }
    return null;
  }

  Map<int, String> _roles(List<int> amts) {
    final score = <int, Map<String, double>>{};
    for (final h in hits('amountRole')) {
      final role = h.entry.role;
      if (role == null) continue;
      final side = h.entry.side ?? 'left';
      for (final a in amts) {
        int? gap;
        if (side == 'left' && h.end <= a && same(h.end - 1, a)) {
          gap = a - h.end;
          if (amts.any((x) => x >= h.end && x < a)) gap = null;
          if (gap != null && gap > p.roleGap) gap = null;
        } else if (side == 'right' && h.start > a && same(a, h.start)) {
          gap = h.start - a - 1;
          if (amts.any((x) => x > a && x < h.start)) gap = null;
          if (gap != null && gap > 2) gap = null;
        }
        if (gap == null) continue;
        final s = h.entry.weight * (1 - 0.08 * gap) + 0.01 * (h.end - h.start);
        final m = score.putIfAbsent(a, () => {});
        m[role] = math.max(m[role] ?? 0, s);
      }
    }
    final out = <int, String>{};
    score.forEach((a, m) {
      final best = m.entries.reduce((x, y) => x.value >= y.value ? x : y);
      out[a] = best.key;
    });
    return out;
  }

  // ---- instrument ----

  (String, String?)? _mask(bool? debit, int? near) {
    final candidates = <(int, Tok, String?)>[];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (t.kind != TokKind.mask) continue;
      final kind = _kindOf(i);
      if (kind == 'phone') continue;
      if (debit != null && _isOtherSide(i, debit)) continue;
      candidates.add((i, t, kind));
    }
    if (candidates.isEmpty) return null;
    var pick = candidates.first;
    if (near != null) {
      pick = candidates.reduce(
        (x, y) => (x.$1 - near).abs() <= (y.$1 - near).abs() ? x : y,
      );
    }
    return (pick.$2.digits ?? '', pick.$3);
  }

  /// Digits of the user's own accounts, in the order they appear.
  List<String> _ownMasks() {
    final owns = hits('ownMarker');
    final out = <String>[];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (t.kind != TokKind.mask) continue;
      if (_kindOf(i) == 'phone') continue;
      final own = owns.any(
        (m) => m.end <= i && i - m.end <= 3 && same(m.start, i),
      );
      final d = t.digits ?? '';
      if (own && !out.contains(d)) out.add(d);
    }
    return out;
  }

  String? _kindOf(int maskIdx) {
    String? kind;
    var bestGap = 1 << 30;
    var bestLen = 0;
    for (final h in hits('instrumentKind')) {
      if (h.end > maskIdx) continue;
      final gap = maskIdx - h.end;
      if (gap > 3) continue;
      final len = h.end - h.start;
      if (gap < bestGap || (gap == bestGap && len > bestLen)) {
        bestGap = gap;
        bestLen = len;
        kind = h.entry.kind;
      }
    }
    return kind;
  }

  bool _isOtherSide(int maskIdx, bool debit) {
    for (final h in hits(debit ? 'maskOtherDebit' : 'maskOtherCredit')) {
      if (h.end <= maskIdx &&
          maskIdx - h.end <= 2 &&
          same(h.end - 1, maskIdx)) {
        final own = hits(
          'ownMarker',
        ).any((m) => m.start >= h.end && m.end <= maskIdx);
        if (!own) return true;
      }
    }
    return false;
  }

  // ---- counterparty ----

  /// (name or VPA, isVpa).
  (String, bool)? _party(bool debit, int amtIdx) {
    final cues = hits(debit ? 'payeeDebit' : 'payeeCredit');
    final stop = {for (final h in hits('partyStop')) h.start};
    final nonParty = {for (final h in hits('nonParty')) h.start};
    final lead = {for (final h in hits('partyLead')) h.start};
    final ordered = [...cues]
      ..sort(
        (a, b) => (a.start - amtIdx).abs().compareTo((b.start - amtIdx).abs()),
      );
    for (final c in ordered) {
      var i = c.end;
      while (i < toks.length && lead.contains(i) && same(c.start, i)) {
        i++;
      }
      while (i < toks.length &&
          (toks[i].kind == TokKind.ref || toks[i].kind == TokKind.num) &&
          same(c.start, i)) {
        i++;
      }
      if (i >= toks.length || !same(c.start, i)) continue;
      if (toks[i].kind == TokKind.vpa) {
        return (toks[i].text.toLowerCase(), true);
      }
      final words = <String>[];
      while (i < toks.length &&
          words.length < p.partyMaxWords &&
          same(c.start, i)) {
        final t = toks[i];
        if (t.kind != TokKind.word || stop.contains(i)) break;
        if (words.isEmpty && nonParty.contains(i)) break;
        words.add(t.text);
        i++;
      }
      if (words.isNotEmpty) return (words.join(' '), false);
    }
    return null;
  }

  // ---- results ----

  String _s(_Hit h) =>
      toks.sublist(h.start, h.end).map((t) => t.text).join(' ');

  SolverDecision _done(
    SolverRead read,
    SolverVerdict verdict,
    double score, {
    Tok? amount,
    (String, String?)? mask,
    String? party,
    String? purpose,
    String? mandatePhase,
    String? mandatePurpose,
    String? frequency,
    bool? oneTime,
    String? attemptStatus,
    int? dueMinorMinimum,
    SolverDate? dueDate,
    SolverDate? statementDate,
    SolverDate? scheduledDate,
    String? billerName,
    bool recurring = false,
    bool? debit,
    String? mandateRef,
  }) => SolverDecision(
    read: read,
    verdict: verdict,
    score: score,
    minor: amount?.minor,
    unit: amount?.unit,
    mask: mask?.$1,
    instrumentKind: _instrumentWire(mask?.$2, read),
    party: party,
    purpose: purpose,
    mandatePhase: mandatePhase,
    mandatePurpose: mandatePurpose,
    frequency: frequency,
    oneTime: oneTime,
    attemptStatus: attemptStatus,
    mandateRef: mandateRef,
    dueMinorMinimum: dueMinorMinimum,
    dueDate: dueDate,
    statementDate: statementDate,
    scheduledDate: scheduledDate,
    billerName: billerName,
    recurring: recurring,
    debitDirection:
        debit ??
        (read == SolverRead.failed || read == SolverRead.scheduled
            ? true
            : null),
    rail: read == SolverRead.scheduled || read == SolverRead.failed
        ? _rail(mask?.$2)
        : null,
    reasons: reasons,
  );
}
