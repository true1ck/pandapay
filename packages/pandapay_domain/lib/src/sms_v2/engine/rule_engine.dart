import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../contract/currency.dart';
import '../contract/enums.dart';
import '../contract/errors.dart';
import '../contract/fact.dart';
import '../contract/interfaces.dart';
import '../contract/json_util.dart';
import '../contract/rule_bundle.dart';
import '../solver/evidence_solver.dart';
import '../solver/solver_facts.dart';
import '../template/skeleton.dart';
import 'compiled_bundle.dart';
import 'transforms.dart';

/// Counters the engine keeps. Never reset by the engine itself.
class EngineStats {
  int messages = 0;
  int matched = 0;
  int ignored = 0;
  int unknown = 0;

  /// Tier 2 (the evidence solver): readings accepted into facts, readings it
  /// was not sure of (left for review), and accepted readings that could not be
  /// written as valid facts.
  int solverAccepted = 0;

  /// A generic catch-all rule's plain debit/credit that the solver enriched with
  /// a merchant, a purpose or a mandate.
  int solverRefined = 0;
  int solverCandidates = 0;
  int solverRejected = 0;

  /// Unknown results by reason (`no_rule_matched`, `rule_emitted_invalid`,
  /// `bundle_refused`, `engine_error`).
  final Map<String, int> unknownReasons = {};

  /// Winning rule id to count (ignore rules included).
  final Map<String, int> ruleHits = {};

  /// Masks dropped because their span overlapped a date span.
  int maskDateOverlaps = 0;

  /// Emits dropped as invalid, by rule id.
  final Map<String, int> invalidEmits = {};

  void reset() {
    messages = matched = ignored = unknown = maskDateOverlaps = 0;
    solverAccepted = solverCandidates = solverRejected = 0;
    unknownReasons.clear();
    ruleHits.clear();
    invalidEmits.clear();
  }

  Map<String, Object?> toJson() => {
        'messages': messages,
        'matched': matched,
        'ignored': ignored,
        'unknown': unknown,
        'solverAccepted': solverAccepted,
        'solverCandidates': solverCandidates,
        'solverRejected': solverRejected,
        'unknownReasons': {...unknownReasons},
        'ruleHits': {...ruleHits},
        'maskDateOverlaps': maskDateOverlaps,
        'invalidEmits': {...invalidEmits},
      };
}

/// An [InterpretResult] with the detail the frozen result type has no room for.
/// A bill reminder the solver read (amount, maybe account) but that prints no due
/// date. It is unresolved here; a caller with the account's history may complete
/// it with `matchEarlierBill` and `completeBillFromHistory`.
class PendingBill {
  const PendingBill({
    required this.decision,
    required this.issuerSlug,
    required this.packVersion,
    required this.bundleVersion,
    required this.engineVersion,
    required this.appVersion,
  });

  final SolverDecision decision;
  final String? issuerSlug;
  final int packVersion;
  final int bundleVersion;
  final String engineVersion;
  final String appVersion;
}

/// A refund or reversal the solver read (amount, credit) but that names no
/// account. A caller with history may still link it to the one earlier spend of
/// that amount ([PendingBill] is the same idea for a bill with no due date).
class PendingRefund {
  const PendingRefund({
    required this.decision,
    required this.issuerSlug,
    required this.packVersion,
    required this.bundleVersion,
    required this.engineVersion,
    required this.appVersion,
  });

  final SolverDecision decision;
  final String? issuerSlug;
  final int packVersion;
  final int bundleVersion;
  final String engineVersion;
  final String appVersion;
}

class EngineOutcome {
  const EngineOutcome(
    this.result, {
    this.reason,
    this.winnerId,
    this.detail,
    this.pendingBill,
    this.pendingRefund,
  });

  /// Set when the message is a refund with an amount and no account.
  final PendingRefund? pendingRefund;

  /// Set when the message is a bill reminder with an amount and no due date.
  final PendingBill? pendingBill;

  final InterpretResult result;

  /// For unknown results: `no_rule_matched`, `rule_emitted_invalid`,
  /// `bundle_refused` or `engine_error`.
  final String? reason;

  /// The rule or ignore rule that matched, even when its emit was invalid.
  final String? winnerId;

  /// Human-readable detail for an invalid emit or a refused bundle.
  final String? detail;
}

class _Emitted implements Exception {
  _Emitted(this.message);
  final String message;
}

class _BundleSlot {
  _BundleSlot(this.compiled, this.error);
  final CompiledBundle? compiled;
  final BundleRefusedException? error;
}

const List<String> _defaultDateFormats = [
  'dd-MM-yyyy',
  'dd-MM-yy',
  'dd/MM/yyyy',
  'dd/MM/yy',
  'ddMMMyy',
  'dd-MMM-yy',
  'dd-MMM-yyyy',
  'dd MMM yyyy',
  'dd MMM yy',
  'yyyy-MM-dd:HH:mm:ss',
  'yyyy-MM-dd',
];

const _dateAttrKeys = {'dueDate', 'statementDate'};
const _instantAttrKeys = {'asOf', 'dueAt', 'expiresAt'};
const _purposeReplaceable = {'unknown', 'p2p', 'purchase', 'transfer'};
const _refFactTypes = {'movement', 'attempt', 'hold', 'mandate', 'bill_due'};

/// The one engine: turns a message and a rule bundle into facts. Pure Dart; no
/// bank-specific code. Never throws from [interpret].
class RuleEngine implements SmsInterpreter {
  RuleEngine({this.engineVersion = smsEngineVersion, EngineStats? stats})
      : stats = stats ?? EngineStats();

  final String engineVersion;
  final EngineStats stats;

  final Expando<_BundleSlot> _cache = Expando<_BundleSlot>('compiledBundle');

  /// The compiled form of [bundle], built once per bundle object. Throws
  /// [BundleRefusedException].
  CompiledBundle compiled(RuleBundle bundle) {
    var slot = _cache[bundle];
    if (slot == null) {
      try {
        slot = _BundleSlot(CompiledBundle.compile(bundle, engineVersion: engineVersion), null);
      } on BundleRefusedException catch (e) {
        slot = _BundleSlot(null, e);
      }
      _cache[bundle] = slot;
    }
    if (slot.error != null) throw slot.error!;
    return slot.compiled!;
  }

  @override
  InterpretResult interpret(SmsMessage message, RuleBundle bundle, {required String appVersion}) =>
      interpretDetailed(message, bundle, appVersion: appVersion).result;

  /// Like [interpret], with the reason for an unknown result and the winning
  /// rule id.
  EngineOutcome interpretDetailed(SmsMessage message, RuleBundle bundle, {required String appVersion}) {
    stats.messages++;
    var hash = '';
    try {
      hash = smsTemplateHash(smsTemplateBrand(message.sender), smsSkeleton(message.body));
    } catch (_) {
      // Leave the hash empty; the result is unknown anyway.
    }
    EngineOutcome unknown(String reason, {String? winner, String? detail}) {
      stats.unknown++;
      stats.unknownReasons[reason] = (stats.unknownReasons[reason] ?? 0) + 1;
      return EngineOutcome(
        InterpretResult(outcome: InterpretOutcome.unknown, facts: const [], templateHash: hash),
        reason: reason,
        winnerId: winner,
        detail: detail,
      );
    }

    try {
      final CompiledBundle cb;
      try {
        cb = compiled(bundle);
      } on BundleRefusedException catch (e) {
        return unknown('bundle_refused', detail: e.toString());
      }
      final brand = cb.normalize(message.sender).brand;
      final body = message.body;

      // 1. Ignore rules: a match produces one info fact and stops.
      for (final ig in cb.ignores) {
        final r = ig.rule;
        if (!(r.senders.contains('*') || r.senders.contains(brand))) continue;
        if (!ig.regex.hasMatch(body)) continue;
        final id = r.id;
        final fact = _infoFact(message, r, cb, appVersion);
        stats.ignored++;
        stats.ruleHits[id] = (stats.ruleHits[id] ?? 0) + 1;
        return EngineOutcome(
          InterpretResult(
            outcome: InterpretOutcome.ignored,
            facts: [fact],
            ruleId: id,
            ruleVersion: 0,
            templateHash: hash,
          ),
          winnerId: id,
        );
      }

      // 2. First matching rule wins.
      final lower = body.toLowerCase();
      for (final c in cb.rulesFor(brand)) {
        final th = c.templateHash;
        if (th != null && th != hash) continue;
        if (!c.passes(lower)) continue;
        final m = c.regex.firstMatch(body);
        if (m == null) continue;
        final id = c.rule.id;
        List<Fact> facts;
        try {
          facts = _build(c, m, message, cb, brand, appVersion);
        } on _Emitted catch (e) {
          stats.invalidEmits[id] = (stats.invalidEmits[id] ?? 0) + 1;
          return unknown('rule_emitted_invalid', winner: id, detail: '$id: ${e.message}');
        } on ContractException catch (e) {
          stats.invalidEmits[id] = (stats.invalidEmits[id] ?? 0) + 1;
          return unknown('rule_emitted_invalid', winner: id, detail: '$id: ${e.errors.take(3).join('; ')}');
        } on Error catch (e) {
          stats.invalidEmits[id] = (stats.invalidEmits[id] ?? 0) + 1;
          return unknown('rule_emitted_invalid', winner: id, detail: '$id: $e');
        }
        // A generic catch-all rule reads "debited from A/c ..." but keeps no
        // purpose or merchant. The solver may enrich THAT and nothing else.
        if (id.startsWith('GEN-')) {
          final refined = _refineGeneric(cb, facts, message, brand, appVersion);
          if (refined != null) {
            stats.solverRefined++;
            stats.matched++;
            stats.ruleHits['SOLVER-REFINED'] =
                (stats.ruleHits['SOLVER-REFINED'] ?? 0) + 1;
            return EngineOutcome(
              InterpretResult(
                outcome: InterpretOutcome.matched,
                facts: refined,
                ruleId: 'SOLVER-REFINED',
                ruleVersion: cb.solver!.pack.version,
                templateHash: hash,
              ),
              winnerId: 'SOLVER-REFINED',
            );
          }
        }
        stats.matched++;
        stats.ruleHits[id] = (stats.ruleHits[id] ?? 0) + 1;
        return EngineOutcome(
          InterpretResult(
            outcome: InterpretOutcome.matched,
            facts: facts,
            ruleId: id,
            ruleVersion: c.rule.version,
            templateHash: hash,
          ),
          winnerId: id,
        );
      }
      // 3. Tier 2: no rule matched, so read the message by its evidence. Only an
      // accepted reading becomes facts; anything less stays unknown and goes to
      // review / the AI drafter exactly as before.
      final solved = _solve(cb, message, brand, hash, appVersion);
      if (solved != null) return solved;
      return unknown('no_rule_matched');
    } catch (e) {
      return unknown('engine_error', detail: '$e');
    }
  }

  // ---- tier 2 ----

  /// Enriches a generic catch-all rule's reading, never replaces it: the rule's
  /// amount, direction, account and date stay; only a missing purpose, merchant
  /// and mandate come from the solver, and only when the solver independently read
  /// the same amount in the same direction. Anything else returns null and the
  /// rule's own facts stand exactly as before.
  List<Fact>? _refineGeneric(
    CompiledBundle cb,
    List<Fact> facts,
    SmsMessage msg,
    String brand,
    String appVersion,
  ) {
    final solver = cb.solver;
    if (solver == null) return null;
    final movements = facts.whereType<MovementFact>().toList();
    if (movements.length != 1) return null;
    final m = movements.single;
    if (m.purpose != MovementPurpose.unknown || m.evidenceOnly == true) {
      return null;
    }
    final posted = m.amounts.where((a) => a.role == AmountRole.posted);
    if (posted.isEmpty) return null;
    try {
      final d = solver.solve(
        msg.body,
        observedAt: msg.observedAt,
        senderBrand: brand,
        senderKind: cb.sendersByBrand[brand]?.issuerKind.wire,
      );
      if (!d.accepted ||
          (d.read != SolverRead.debit && d.read != SolverRead.credit) ||
          d.evidenceOnly ||
          d.unit != 'INR' ||
          d.minor != posted.first.minor ||
          d.debitDirection != (m.direction == Direction.debit)) {
        return null;
      }
      final adds =
          (d.purpose != null && d.purpose != 'unknown') ||
          d.party != null ||
          d.recurring ||
          d.mandateRef != null;
      if (!adds) return null;
      final built = SolverFacts.build(
        d,
        sourceKey: msg.sourceKey,
        observedAt: msg.observedAt,
        issuerSlug:
            m.instrument?.issuerSlug ??
            cb.sendersByBrand[brand]?.issuerSlug ??
            _plainIssuerSlug(brand),
        packVersion: solver.pack.version,
        bundleVersion: cb.bundle.bundleVersion,
        engineVersion: engineVersion,
        appVersion: appVersion,
        ruleIdOverride: 'SOLVER-REFINED',
      );
      if (built == null || built.ignored) return null;
      final out = <Fact>[];
      for (final f in built.facts) {
        final json = f.toJson();
        // The rule's own account and date win over the solver's.
        if (f is MovementFact || f is MandateFact) {
          if (m.instrument != null) json['instrument'] = m.instrument!.toJson();
        }
        if (f is MovementFact && m.occurredAt != null) {
          json['occurredAt'] = formatUtc(m.occurredAt!);
        }
        out.add(Fact.fromJson(json));
      }
      // Anything else the rule found (a balance, say) is kept.
      for (final f in facts) {
        if (f is! MovementFact) out.add(f);
      }
      return out;
    } on Object {
      return null;
    }
  }

  /// An issuer identity for a sender the registry does not know: its header in
  /// plain lower case ("NEWBNK" -> "newbnk"). Bills and card payments from the same
  /// header then share one identity, so a bill can be matched to its payment and
  /// a reminder to its statement, for banks no rule was ever written for. The
  /// app already gives an unrecognised issuer a plain slug the same way. A header
  /// that is only digits (a short code) names nobody.
  static String? _plainIssuerSlug(String brand) {
    final slug = brand.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    return slug.length < 3 || RegExp(r'^\d+$').hasMatch(slug) ? null : slug;
  }

  EngineOutcome? _solve(CompiledBundle cb, SmsMessage msg, String brand, String hash, String appVersion) {
    final solver = cb.solver;
    if (solver == null) return null;
    final SolverDecision decision;
    try {
      decision = solver.solve(
        msg.body,
        observedAt: msg.observedAt,
        senderBrand: brand,
        senderKind: cb.sendersByBrand[brand]?.issuerKind.wire,
      );
    } on Object {
      return null;
    }
    if (!decision.accepted) {
      stats.solverCandidates++;
      if (decision.read == SolverRead.billDue &&
          decision.dueDate == null &&
          decision.minor != null &&
          decision.unit == 'INR') {
        // Unresolved for now, but the amount and account are known: a caller
        // with history can still complete it. It counts as unknown exactly as
        // before, so a caller that ignores this stays unchanged.
        stats.unknown++;
        stats.unknownReasons['no_rule_matched'] =
            (stats.unknownReasons['no_rule_matched'] ?? 0) + 1;
        return EngineOutcome(
          InterpretResult(
            outcome: InterpretOutcome.unknown,
            facts: const [],
            templateHash: hash,
          ),
          reason: 'no_rule_matched',
          pendingBill: PendingBill(
            decision: decision,
            issuerSlug:
                cb.sendersByBrand[brand]?.issuerSlug ?? _plainIssuerSlug(brand),
            packVersion: solver.pack.version,
            bundleVersion: cb.bundle.bundleVersion,
            engineVersion: engineVersion,
            appVersion: appVersion,
          ),
        );
      }
      if (decision.read == SolverRead.credit &&
          (decision.purpose == 'refund' || decision.purpose == 'reversal') &&
          decision.minor != null &&
          decision.unit == 'INR' &&
          decision.mask == null &&
          decision.instrumentKind == null) {
        stats.unknown++;
        stats.unknownReasons['no_rule_matched'] =
            (stats.unknownReasons['no_rule_matched'] ?? 0) + 1;
        return EngineOutcome(
          InterpretResult(
            outcome: InterpretOutcome.unknown,
            facts: const [],
            templateHash: hash,
          ),
          reason: 'no_rule_matched',
          pendingRefund: PendingRefund(
            decision: decision,
            issuerSlug:
                cb.sendersByBrand[brand]?.issuerSlug ?? _plainIssuerSlug(brand),
            packVersion: solver.pack.version,
            bundleVersion: cb.bundle.bundleVersion,
            engineVersion: engineVersion,
            appVersion: appVersion,
          ),
        );
      }
      return null;
    }
    final SolverFactResult? built;
    try {
      built = SolverFacts.build(
        decision,
        sourceKey: msg.sourceKey,
        observedAt: msg.observedAt,
        issuerSlug: cb.sendersByBrand[brand]?.issuerSlug ?? _plainIssuerSlug(brand),
        packVersion: solver.pack.version,
        bundleVersion: cb.bundle.bundleVersion,
        engineVersion: engineVersion,
        appVersion: appVersion,
        refine: (facts) => _applyCounterpartyPurposes(facts, cb),
      );
    } on Object {
      stats.solverRejected++;
      return null;
    }
    if (built == null) {
      stats.solverRejected++;
      return null;
    }
    final id = built.ruleId;
    stats.ruleHits[id] = (stats.ruleHits[id] ?? 0) + 1;
    if (built.ignored) {
      stats.ignored++;
    } else {
      stats.matched++;
    }
    stats.solverAccepted++;
    return EngineOutcome(
      InterpretResult(
        outcome: built.ignored ? InterpretOutcome.ignored : InterpretOutcome.matched,
        facts: built.facts,
        ruleId: id,
        ruleVersion: solver.pack.version,
        templateHash: hash,
      ),
      winnerId: id,
    );
  }

  // ---- info fact for an ignore rule ----

  Fact _infoFact(SmsMessage msg, IgnoreRule r, CompiledBundle cb, String appVersion) {
    final json = <String, Object?>{
      'contractVersion': Fact.contractVersion,
      'factId': _factId(msg.sourceKey, r.id, 0),
      'sourceKey': msg.sourceKey,
      'factType': 'info',
      'observedAt': formatUtc(msg.observedAt),
      'occurredAt': null,
      'instrument': null,
      'counterparty': null,
      'amounts': <Object?>[],
      'references': <String, String>{},
      'attrs': {'category': r.reason.wire},
      'provenance': {
        'engine': 'rules',
        'ruleId': r.id,
        'ruleVersion': 0,
        'bundleVersion': cb.bundle.bundleVersion,
        'engineVersion': engineVersion,
        'appVersion': appVersion,
      },
      'evidence': <Object?>[],
      'confidence': 1.0,
    };
    return Fact.fromJson(json);
  }

  static String _factId(String sourceKey, String ruleId, int emitIndex) =>
      sha256.convert(utf8.encode('$sourceKey|$ruleId|$emitIndex')).toString();

  // ---- facts from a rule ----

  List<Fact> _build(
    CompiledRule c,
    RegExpMatch m,
    SmsMessage msg,
    CompiledBundle cb,
    String brand,
    String appVersion,
  ) {
    final rule = c.rule;
    final ctx = _Ctx(m, msg.body);
    final sender = cb.sendersByBrand[brand];
    final built = <Map<String, Object?>>[];

    for (var i = 0; i < rule.emit.length; i++) {
      built.add(_buildEmit(i, rule.emit[i], ctx, built, msg, sender, rule, cb, appVersion));
    }
    _applyCounterpartyPurposes(built, cb);

    final facts = <Fact>[];
    for (final j in built) {
      final f = Fact.fromJson(j); // validates; throws ContractException
      final v = f.validate();
      if (!v.ok) throw ContractException(v.errors);
      facts.add(f);
    }
    return facts;
  }

  Map<String, Object?> _buildEmit(
    int index,
    Emit e,
    _Ctx ctx,
    List<Map<String, Object?>> built,
    SmsMessage msg,
    SenderEntry? sender,
    Rule rule,
    CompiledBundle cb,
    String appVersion,
  ) {
    final evidence = <Map<String, Object?>>[];
    void span(String field, String? group) {
      if (group == null) return;
      final s = ctx.span(group);
      if (s != null) evidence.add({'field': field, 'start': s.$1, 'end': s.$2});
    }

    // Amounts.
    final amounts = <Map<String, Object?>>[];
    for (final a in e.amounts ?? const <EmitAmount>[]) {
      final raw = ctx.group(a.from);
      if (raw == null) continue;
      // The unit is fixed by the rule or read from the message (CCR-004).
      var unit = a.unit;
      if (unit == null) {
        final token = ctx.group(a.unitFrom!);
        if (token == null) throw _Emitted('amount "${a.from}" has no currency: group "${a.unitFrom}" did not match');
        unit = token.trim().toUpperCase() == 'INR' ? 'INR' : smsForeignCurrencyCode(token);
        if (unit == null) throw _Emitted('amount "${a.from}" has an unknown currency: "$token"');
      }
      // POINTS are whole points, not paise; a foreign amount uses the
      // precision of its own currency and is never rounded.
      final int? minor;
      if (unit == 'POINTS') {
        minor = int.tryParse(raw.replaceAll(',', ''));
      } else if (unit == 'INR') {
        minor = parseAmountIndian(raw);
      } else {
        final exponent = smsCurrencyExponent(unit);
        if (exponent == null) throw _Emitted('amount "${a.from}" has an unknown currency: "$unit"');
        minor = parseDecimalMinor(raw, exponent);
      }
      if (minor == null) throw _Emitted('amount "${a.from}" is not a number: "$raw"');
      final amount = <String, Object?>{'role': a.role.wire, 'minor': minor, 'unit': unit};
      final og = a.original;
      if (og != null) {
        final printed = ctx.group(og.from);
        if (printed != null) {
          if (unit != 'INR') throw _Emitted('amount "${a.from}": an original foreign amount needs an INR posting');
          final token = og.currency ?? (og.currencyFrom == null ? null : ctx.group(og.currencyFrom!));
          final code = token == null ? null : smsForeignCurrencyCode(token);
          if (code == null) throw _Emitted('amount "${a.from}": original currency "$token" is not a foreign currency');
          final originalMinor = parseDecimalMinor(printed, smsCurrencyExponent(code)!);
          if (originalMinor == null) throw _Emitted('original "${og.from}" is not a number: "$printed"');
          amount['original'] = {'minor': originalMinor, 'currency': code};
          span('amounts.${a.role.wire}.original', og.from);
        }
      }
      amounts.add(amount);
      span('amounts.${a.role.wire}', a.from);
    }

    // occurredAt.
    DateTime? occurredAt;
    final oa = e.occurredAt;
    if (oa != null) {
      final raw = ctx.group(oa['from'] as String);
      if (raw != null) {
        final formats = (oa['formats'] as List?)?.cast<String>() ?? _defaultDateFormats;
        occurredAt = parseDate(raw, formats);
        if (occurredAt != null) {
          span('occurredAt', oa['from'] as String);
          if (occurredAt.isAfter(msg.observedAt.add(const Duration(days: 1)))) occurredAt = null;
        }
      }
    }

    // Instrument.
    Map<String, Object?>? instrument;
    final inst = e.instrument;
    if (inst != null) {
      if (inst.containsKey('sameAs')) {
        final src = _earlier(built, inst['sameAs'], index);
        final i0 = src['instrument'];
        instrument = i0 == null ? null : Map<String, Object?>.of(i0 as Map<String, Object?>);
      } else {
        String? issuer = inst['issuerSlug'] as String?;
        if (issuer == null && inst['issuerSlugFrom'] != null) {
          issuer = ctx.group(inst['issuerSlugFrom'] as String)?.toLowerCase();
        }
        issuer ??= sender?.issuerSlug;
        String? maskDigits, raw;
        int? maskLength;
        final maskGroup = inst['maskFrom'] as String?;
        if (maskGroup != null) {
          raw = ctx.group(maskGroup);
          if (raw != null) {
            var d = digitsOnly(raw);
            maskLength = d.length;
            if (d.length > 6) d = d.substring(d.length - 4);
            if (d.length >= 2) {
              maskDigits = d;
              if (maskLength < 2) maskLength = null;
            } else {
              maskDigits = null;
              maskLength = null;
            }
          }
          final mlg = inst['maskLengthFrom'] as String?;
          if (mlg != null) {
            final n = int.tryParse(ctx.group(mlg) ?? '');
            if (n != null) maskLength = n;
          }
          // The "card 2026" bug: a mask taken out of a date.
          if (maskDigits != null) {
            final ms = ctx.span(maskGroup);
            if (ms != null && _overlapsDate(ms, e, ctx)) {
              stats.maskDateOverlaps++;
              maskDigits = null;
              maskLength = null;
              raw = null;
            } else {
              span('instrument.maskDigits', maskGroup);
            }
          }
        }
        final pn = inst['productNameFrom'] as String?;
        final productName = pn == null ? null : ctx.group(pn);
        if (pn != null && productName != null) span('instrument.productName', pn);
        instrument = {
          'kind': inst['kind'],
          'issuerSlug': issuer,
          'maskDigits': maskDigits,
          'maskLength': maskLength,
          'productName': productName,
          'raw': raw,
        };
        if (instrument.values.every((v) => v == null)) instrument = null;
      }
    }

    // Counterparty.
    Map<String, Object?>? counterparty;
    final cp = e.counterparty;
    if (cp != null) {
      if (cp.containsKey('sameAs')) {
        final src = _earlier(built, cp['sameAs'], index);
        final c0 = src['counterparty'];
        counterparty = c0 == null ? null : Map<String, Object?>.of(c0 as Map<String, Object?>);
      } else {
        final transforms = (cp['transforms'] as List?)?.cast<String>() ?? const <String>[];
        String? name;
        final ng = cp['nameFrom'] as String?;
        if (ng != null) {
          name = ctx.group(ng);
          if (name != null) {
            for (final t in transforms) {
              name = applyStringTransform(t, name!);
            }
            name = name!.trim();
            if (name.isEmpty) {
              name = null;
            } else {
              span('counterparty.name', ng);
            }
          }
        }
        String? vpa;
        final vg = cp['vpaFrom'] as String?;
        if (vg != null) {
          final raw = ctx.group(vg);
          if (raw != null) {
            vpa = vpaFromText(raw);
            if (vpa != null) span('counterparty.vpa', vg);
          }
        }
        String? accountMask;
        final ag = cp['accountMaskFrom'] as String?;
        if (ag != null) {
          final raw = ctx.group(ag);
          if (raw != null) {
            final d = digitsOnly(raw);
            if (d.isNotEmpty) {
              accountMask = d;
              span('counterparty.accountMask', ag);
            }
          }
        }
        final kind = cp['kind'] as String?;
        if (name != null || vpa != null || accountMask != null || kind != null) {
          counterparty = {'name': name, 'vpa': vpa, 'kind': kind, 'accountMask': accountMask};
        }
      }
    }

    // References: explicit mappings, then ref_<key> groups.
    final refs = <String, String>{};
    final factTypeWire = e.factType.wire;
    e.references?.forEach((key, group) {
      final v = ctx.group(group);
      if (v != null) {
        refs[key] = v;
        span('references.$key', group);
      }
    });
    if (_refFactTypes.contains(factTypeWire)) {
      for (final name in ctx.groupNames) {
        if (!name.startsWith('ref_') || name.length == 4) continue;
        final key = name.substring(4);
        final v = ctx.group(name);
        if (v != null && !refs.containsKey(key)) {
          refs[key] = v;
          span('references.$key', name);
        }
      }
    }

    // Attrs.
    final attrs = <String, Object?>{};
    final spec = e.attrs;
    if (spec != null) {
      for (final entry in spec.entries) {
        final key = entry.key;
        final v = entry.value;
        Object? out;
        if (v is Map) {
          if (v.containsKey('sameAs')) {
            final src = _earlier(built, v['sameAs'], index);
            final field = (v['field'] as String?) ?? key;
            out = switch (field) {
              'occurredAt' => src['occurredAt'] ?? src['observedAt'],
              'observedAt' => src['observedAt'],
              _ => (src['attrs'] as Map)[field],
            };
          } else if (v.containsKey('from')) {
            out = _attrFromGroup(key, v.cast<String, Object?>(), ctx);
          }
        } else {
          out = v;
        }
        if (out != null) attrs[key] = out;
      }
    }

    // A balance with no printed date is as of the fact's own time.
    if (factTypeWire == 'balance_snapshot' && attrs['asOf'] == null) {
      attrs['asOf'] = formatUtc(occurredAt ?? msg.observedAt);
    }

    final ruleId = rule.id;
    return {
      'contractVersion': Fact.contractVersion,
      'factId': _factId(msg.sourceKey, ruleId, index),
      'sourceKey': msg.sourceKey,
      'factType': factTypeWire,
      'observedAt': formatUtc(msg.observedAt),
      'occurredAt': occurredAt == null ? null : formatUtc(occurredAt),
      'instrument': instrument,
      'counterparty': counterparty,
      'amounts': amounts,
      'references': refs,
      'attrs': attrs,
      'provenance': {
        'engine': 'rules',
        'ruleId': ruleId,
        'ruleVersion': rule.version,
        'bundleVersion': cb.bundle.bundleVersion,
        'engineVersion': engineVersion,
        'appVersion': appVersion,
      },
      'evidence': evidence,
      'confidence': rule.confidence,
    };
  }

  Map<String, Object?> _earlier(List<Map<String, Object?>> built, Object? idx, int current) {
    if (idx is! int || idx < 0 || idx >= current || idx >= built.length) {
      throw _Emitted('sameAs $idx must name an earlier emit');
    }
    return built[idx];
  }

  Object? _attrFromGroup(String key, Map<String, Object?> spec, _Ctx ctx) {
    final raw = ctx.group(spec['from'] as String);
    if (raw == null) return null;
    final formats = (spec['formats'] as List?)?.cast<String>() ?? _defaultDateFormats;
    if (_dateAttrKeys.contains(key)) {
      final d = parseDate(raw, formats);
      if (d == null) throw _Emitted('attr $key: cannot read date "$raw"');
      final l = d.add(istOffset);
      return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
    }
    if (_instantAttrKeys.contains(key)) {
      final d = parseDate(raw, formats);
      if (d == null) throw _Emitted('attr $key: cannot read date "$raw"');
      return formatUtc(d);
    }
    if (key == 'previousMinor' || key == 'amountMinor') {
      final n = parseAmountIndian(raw);
      if (n == null) throw _Emitted('attr $key: not an amount "$raw"');
      return n;
    }
    var s = raw;
    for (final t in (spec['transforms'] as List?)?.cast<String>() ?? const <String>[]) {
      s = applyStringTransform(t, s);
    }
    s = s.trim();
    return s.isEmpty ? null : s;
  }

  bool _overlapsDate((int, int) mask, Emit e, _Ctx ctx) {
    final groups = <String>[];
    final from = e.occurredAt?['from'];
    if (from is String) groups.add(from);
    for (final entry in (e.attrs ?? const <String, Object?>{}).entries) {
      final v = entry.value;
      if (v is Map &&
          v['from'] is String &&
          (_dateAttrKeys.contains(entry.key) || _instantAttrKeys.contains(entry.key))) {
        groups.add(v['from'] as String);
      }
    }
    for (final g in groups) {
      final s = ctx.span(g);
      if (s != null && mask.$1 < s.$2 && s.$1 < mask.$2) return true;
    }
    return false;
  }

  void _applyCounterpartyPurposes(List<Map<String, Object?>> facts, CompiledBundle cb) {
    if (cb.purposes.isEmpty) return;
    for (final f in facts) {
      if (f['factType'] != 'movement') continue;
      final cp = f['counterparty'];
      if (cp is! Map<String, Object?>) continue;
      final attrs = f['attrs'] as Map<String, Object?>;
      if (attrs['direction'] != 'debit') continue;
      final vpa = cp['vpa'] as String?;
      final name = cp['name'] as String?;
      for (final p in cb.purposes) {
        final byVpa = p.vpa != null && vpa != null && p.vpa!.hasMatch(vpa);
        final byName = p.name != null && name != null && p.name!.hasMatch(name);
        if (!byVpa && !byName) continue;
        if (!_purposeReplaceable.contains(attrs['purpose'])) break;
        final purpose = p.purpose.purpose.wire;
        attrs['purpose'] = purpose;
        if (purpose == 'wallet_topup' || purpose == 'card_payment') cp['kind'] = 'own';
        break;
      }
    }
  }
}

/// A match with lazy group access and best-effort spans.
class _Ctx {
  _Ctx(this.m, this.body);

  final RegExpMatch m;
  final String body;
  Map<String, (int, int)?>? _spans;

  Iterable<String> get groupNames => m.groupNames;

  /// The captured text, trimmed; null when the group is absent, empty or
  /// unknown.
  String? group(String name) {
    if (!m.groupNames.contains(name)) throw _Emitted('rule names a group that does not exist: $name');
    final v = m.namedGroup(name);
    if (v == null) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// Dart gives no group offsets: find each captured value inside the match
  /// range, scanning left to right in pattern order.
  (int, int)? span(String name) {
    var spans = _spans;
    if (spans == null) {
      spans = {};
      var cursor = m.start;
      for (final g in m.groupNames) {
        final v = m.namedGroup(g);
        if (v == null || v.isEmpty) {
          spans[g] = null;
          continue;
        }
        var idx = body.indexOf(v, cursor);
        if (idx < 0 || idx + v.length > m.end) idx = body.indexOf(v, m.start);
        if (idx < 0 || idx + v.length > m.end) {
          spans[g] = null;
          continue;
        }
        spans[g] = (idx, idx + v.length);
        cursor = idx + v.length;
      }
      _spans = spans;
    }
    return spans[name];
  }
}
