/// The solver pack: all vocabulary, weights and thresholds the evidence solver
/// uses. The kernel (`evidence_solver.dart`) holds no wording; without a pack it
/// can decide nothing. In production the pack is a signed section of the rule
/// bundle served by the API.
library;

import 'solver_text.dart';

/// One phrase of a lexicon with its optional attributes.
class LexEntry {
  LexEntry(
    this.phrase, {
    this.role,
    this.kind,
    this.side,
    this.weight = 1.0,
    this.cue = false,
  });

  final Phrase phrase;

  /// For the kind lexicons (`walletTopup`, `cardPayment`, ...): this phrase
  /// states that the movement happened, so it is a completion cue by itself.
  /// Phrases without it only name the kind of a movement some other word completes.
  final bool cue;

  /// For `amountRole`: the role the amount takes.
  final String? role;

  /// For `instrumentKind`: the instrument kind the cue names.
  final String? kind;

  /// For `amountRole`: `left` (cue before the amount, default) or `right`.
  final String? side;
  final double weight;
}

/// Lexicons the kernel reads. A pack must define each (possibly empty).
const solverLexiconNames = <String>[
  'debit', // completed money-out wording
  'credit', // completed money-in wording
  'billerReceived', // "we received your payment": the biller was paid, i.e. money out for the user
  'negator', // single words that void a nearby completed cue ("not debited")
  'futureMarker', // "will", "shall": a verb after these has not happened, up to six tokens on
  'conditional', // "when you", "if you": wording AFTER a cue that makes it a promise, not an event
  'undo', // "refunded", "reversed": a charge in the same sentence that was taken back
  'reminderWord', // "reminder": the message nudges about something, it does not report an event
  'failed',
  'scheduled', // "will be debited", mandate set-ups
  'promo',
  'billDue',
  'amountRole', // cue -> what the next amount means (balance, limit, due, ...)
  'cardPayment',
  'ownTransfer',
  'walletTopup',
  'investment',
  'completionOther', // "successful", "done": completion without a direction
  'debitIntent', // recharge, premium, toll: purposes that imply money out
  'holdForReview', // loan disbursal, reversal, dispute: never auto-accepted
  'instrumentKind', // which kind of instrument a nearby mask belongs to
  'maskOtherDebit', // words before a mask that mark the OTHER party's account on a debit
  'maskOtherCredit',
  'ownMarker', // "your", "my": a mask after these is the user's own even after "to"
  'payeeDebit',
  'payeeCredit',
  'partyStop',
  'partyLead',
  'nonParty',
  'rail',
  'security', // OTP / PIN / CVV wording; only read when nothing completed
  'notice', // order / hold / request notices: no money moved
  'paidReceipt', // a biller's "paid" receipt, e-bill or renewal notice
  'billNoun', // bill, premium, membership, invoice ...
  'recurring', // subscription, renewal, autopay, membership ...
  'mandateSetup',
  'mandateEnd', // entries carry kind: revoked | paused | expired | resumed
  'frequency', // entries carry kind: monthly | yearly | quarterly | weekly | daily | once
  'generated', // "statement generated", "bill is ready"
  'dateRole', // entries carry role: due | statement | paid
  'relativeDay', // entries carry kind: days from today as a number
  'purposeCue', // entries carry kind: a MovementPurpose wire value
  'mandateRefCue', // "mandate id", "umrn": the next token is the reference
  'billerStop', // generic words that are not a biller's name
  'merchantCue', // words before the merchant a mandate or subscription is for
  'loanWord',
  'financialWord', // payment, transaction, card, account ...: a "failed" notice with these is about money
  'coinRedemption', // reward coins / points redeemed: shown in activity, never counted
  'dividendNotice', // "dividend": with only per-share amounts it is an announcement, not money received
  'perShare', // "per share": marks an amount as per-share
  'holdRelease', // "blocked amount ... now available": a hold released (entries carry kind: a hold purpose)
  'pendingRequest', // "we have received your request": nothing has moved yet
  'coinRedemption', // reward coins / points redeemed: shown in activity, never counted
  'dividendNotice', // "dividend": with only per-share amounts it is an announcement, not money received
  'perShare', // "per share": marks an amount as per-share
  'holdRelease', // "blocked amount ... now available": a hold released (entries carry kind: a hold purpose)
  'pendingRequest', // "we have received your request": nothing has moved yet
  'nonMoneyUnit', // "points", "coins": completed wording about something that is not money
];

class SolverParams {
  const SolverParams({
    this.accept = 0.80,
    this.maxCueDistance = 8,
    this.directionMargin = 2,
    this.roleGap = 5,
    this.partyMaxWords = 5,
    this.enabled = true,
  });

  /// Minimum score for an automatic accept.
  final double accept;

  /// Largest token distance between a completed cue and its amount.
  final int maxCueDistance;

  /// A competing direction closer than this many tokens makes it ambiguous.
  final int directionMargin;

  /// Largest token gap between an amount-role cue and its amount.
  final int roleGap;
  final int partyMaxWords;

  /// The kill switch: a pack with `enabled: false` makes the solver inert.
  final bool enabled;

  factory SolverParams.fromJson(Map<String, dynamic> j) => SolverParams(
    accept: (j['accept'] as num?)?.toDouble() ?? 0.80,
    maxCueDistance: (j['maxCueDistance'] as num?)?.toInt() ?? 8,
    directionMargin: (j['directionMargin'] as num?)?.toInt() ?? 2,
    roleGap: (j['roleGap'] as num?)?.toInt() ?? 5,
    partyMaxWords: (j['partyMaxWords'] as num?)?.toInt() ?? 5,
    enabled: j['enabled'] != false,
  );
}

class SolverPack {
  SolverPack._(this.version, this.params, this._lex);

  static const schema = 'pandapay.sms.solver/1';

  final int version;
  final SolverParams params;
  final Map<String, List<LexEntry>> _lex;

  List<LexEntry> lex(String name) => _lex[name] ?? const [];

  /// Parses and checks a pack. Throws [FormatException] naming the problem.
  factory SolverPack.fromJson(Map<String, dynamic> j) {
    if (j['schema'] != schema) {
      throw FormatException('solver pack schema must be "$schema"');
    }
    final raw = j['lexicons'];
    if (raw is! Map) throw const FormatException('solver pack has no lexicons');
    final lex = <String, List<LexEntry>>{};
    for (final name in solverLexiconNames) {
      final list = raw[name];
      if (list == null) {
        throw FormatException('solver pack lexicon "$name" is missing');
      }
      if (list is! List) {
        throw FormatException('lexicon "$name" must be a list');
      }
      lex[name] = [
        for (final e in list)
          if (e is String)
            _entry(name, {'p': e})
          else
            _entry(name, (e as Map).cast<String, dynamic>()),
      ];
    }
    final unknown = raw.keys.where((k) => !solverLexiconNames.contains(k));
    if (unknown.isNotEmpty) {
      throw FormatException(
        'solver pack has unknown lexicons: ${unknown.join(', ')}',
      );
    }
    return SolverPack._(
      (j['version'] as num?)?.toInt() ?? 0,
      SolverParams.fromJson(
        (j['params'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      lex,
    );
  }

  static LexEntry _entry(String lexicon, Map<String, dynamic> e) {
    final p = e['p'];
    if (p is! String) {
      throw FormatException('lexicon "$lexicon": entry without "p"');
    }
    try {
      return LexEntry(
        Phrase.parse(p),
        role: e['role'] as String?,
        kind: e['kind'] as String?,
        side: e['side'] as String?,
        weight: (e['w'] as num?)?.toDouble() ?? 1.0,
        cue: e['cue'] == true,
      );
    } on FormatException catch (err) {
      throw FormatException('lexicon "$lexicon": ${err.message}');
    }
  }
}
