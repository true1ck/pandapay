import '../contract/enums.dart';
import '../contract/interfaces.dart';
import '../contract/rule_bundle.dart';
import 'compiled_bundle.dart';
import 'lint.dart';
import 'rule_engine.dart';
import 'sender.dart';

/// A rule example the engine's output disagrees with.
class ExampleFailure {
  const ExampleFailure({
    required this.ruleId,
    required this.exampleIndex,
    required this.kind,
    required this.message,
    this.shadowedBy,
  });

  final String ruleId;
  final int exampleIndex;

  /// `positive_not_matched`, `positive_shadowed`, `positive_wrong_facts`,
  /// `positive_sender_mismatch`, `negative_matched`, `mask_looks_like_year` or
  /// `bundle_refused`.
  final String kind;
  final String message;

  /// The rule or ignore rule that won instead, for `positive_shadowed`.
  final String? shadowedBy;

  @override
  String toString() => '[$ruleId example #$exampleIndex] $kind: $message';
}

/// Late enough that no printed date counts as "after observedAt".
final DateTime _exampleObservedAt = DateTime.utc(2099, 1, 1);

final RegExp _yearLike = RegExp(r'^(?:19|20)\d\d$');

/// Runs every example of every active or provisional rule through the engine.
/// A positive example (non-empty `expectFactTypes`) must be won by its own rule
/// and produce exactly those fact types, in order. A negative example must not
/// be won by its own rule.
List<ExampleFailure> runRuleExamples(RuleBundle bundle, {String engineVersion = smsEngineVersion}) {
  final engine = RuleEngine(engineVersion: engineVersion);
  final out = <ExampleFailure>[];
  try {
    engine.compiled(bundle);
  } on BundleRefusedException catch (e) {
    return [ExampleFailure(ruleId: '*', exampleIndex: 0, kind: 'bundle_refused', message: e.toString())];
  }
  final compiled = engine.compiled(bundle);
  for (final rule in bundle.rules) {
    if (rule.status != RuleStatus.active && rule.status != RuleStatus.provisional) continue;
    for (var i = 0; i < rule.examples.length; i++) {
      final ex = rule.examples[i];
      final msg = SmsMessage(
        sender: ex.sender,
        body: ex.body,
        observedAt: _exampleObservedAt,
        sourceKey: 'example:${rule.id}:$i',
      );
      final o = engine.interpretDetailed(msg, bundle, appVersion: 'examples');
      final positive = ex.expectFactTypes.isNotEmpty;
      if (!positive) {
        if (o.winnerId == rule.id) {
          out.add(ExampleFailure(
            ruleId: rule.id,
            exampleIndex: i,
            kind: 'negative_matched',
            message: 'negative example is matched by its own rule: "${_clip(ex.body)}"',
          ));
        }
        continue;
      }
      if (positive) {
        final brand = compiled.normalize(ex.sender).brand;
        if (!rule.senders.contains('*') && !rule.senders.contains(brand)) {
          out.add(ExampleFailure(
            ruleId: rule.id,
            exampleIndex: i,
            kind: 'positive_sender_mismatch',
            message: 'example sender ${ex.sender} (brand $brand) is not one of ${rule.senders}',
          ));
          continue;
        }
      }
      if (o.winnerId != null && o.winnerId != rule.id) {
        out.add(ExampleFailure(
          ruleId: rule.id,
          exampleIndex: i,
          kind: 'positive_shadowed',
          message: 'positive example is matched first by ${o.winnerId}: "${_clip(ex.body)}"',
          shadowedBy: o.winnerId,
        ));
        continue;
      }
      if (o.winnerId == null) {
        out.add(ExampleFailure(
          ruleId: rule.id,
          exampleIndex: i,
          kind: 'positive_not_matched',
          message: 'no rule matched the positive example: "${_clip(ex.body)}"',
        ));
        continue;
      }
      if (o.result.outcome != InterpretOutcome.matched) {
        out.add(ExampleFailure(
          ruleId: rule.id,
          exampleIndex: i,
          kind: 'positive_wrong_facts',
          message: 'rule matched but its emit was invalid (${o.detail})',
        ));
        continue;
      }
      final got = [for (final f in o.result.facts) f.factType];
      final want = ex.expectFactTypes;
      if (got.length != want.length || [for (var k = 0; k < got.length; k++) got[k] == want[k]].contains(false)) {
        out.add(ExampleFailure(
          ruleId: rule.id,
          exampleIndex: i,
          kind: 'positive_wrong_facts',
          message: 'expected ${want.map((t) => t.wire).toList()} but got ${got.map((t) => t.wire).toList()}',
        ));
        continue;
      }
      for (final f in o.result.facts) {
        final md = f.instrument?.maskDigits;
        if (md != null && _yearLike.hasMatch(md)) {
          final inDate = RegExp(r'(?:\d{1,2}[-/.]\d{1,2}[-/.]|[A-Za-z]{3}[-\s,]*)' + md).hasMatch(ex.body);
          if (inDate) {
            out.add(ExampleFailure(
              ruleId: rule.id,
              exampleIndex: i,
              kind: 'mask_looks_like_year',
              message: 'mask "$md" looks like a year taken from a date',
            ));
          }
        }
      }
    }
  }
  return out;
}

String _clip(String s) => s.length <= 80 ? s : '${s.substring(0, 77)}...';

/// Lints a bundle: regex dialect, unique ids, examples present, known senders,
/// named groups that exist, and shadowing (no positive example of rule A may be
/// matched first by a higher-priority rule B).
List<LintIssue> lintBundle(RuleBundle bundle) {
  final out = <LintIssue>[];
  final known = <String>{
    for (final s in bundle.senders) ...[s.brand, ...s.aliases.map((a) => a.toUpperCase())],
  };

  void senders(String id, List<String> list) {
    for (final s in list) {
      if (s == '*') continue;
      if (!known.contains(s.toUpperCase())) {
        out.add(LintIssue('lint.sender.unknown', 'sender "$s" is not in senders.json', ruleId: id));
        continue;
      }
      // The engine compares a rule's senders with the canonical brand only
      // (`normalizeSenderBrand` resolves aliases first), so a rule scoped to an
      // alias would never fire.
      final canonical = resolveBrandAlias(s.toUpperCase(), bundle.senders);
      if (canonical != s.toUpperCase()) {
        out.add(LintIssue(
          'lint.sender.alias',
          'sender "$s" is an alias; the engine matches the canonical brand only, so use "$canonical"',
          ruleId: id,
        ));
      }
    }
  }

  void unique(Iterable<String> ids, String what) {
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id)) out.add(LintIssue('lint.id.duplicate', 'duplicate $what id', ruleId: id));
    }
  }

  unique(bundle.rules.map((r) => r.id), 'rule');
  unique(bundle.ignoreRules.map((r) => r.id), 'ignore rule');
  unique(bundle.counterpartyPurposes.map((r) => r.id), 'counterparty purpose');
  unique(bundle.linkRules.map((r) => r.id), 'link rule');

  for (final r in bundle.rules) {
    out.addAll(lintRegexDialect(r.match.pattern, r.match.flags, ruleId: r.id));
    senders(r.id, r.senders);
    final pos = r.examples.where((e) => e.expectFactTypes.isNotEmpty).length;
    final neg = r.examples.length - pos;
    if (pos == 0) out.add(LintIssue('lint.examples.no_positive', 'rule has no positive example', ruleId: r.id));
    if (neg == 0) out.add(LintIssue('lint.examples.no_negative', 'rule has no negative example', ruleId: r.id));

    final groups = patternGroupNames(r.match.pattern);
    void need(String? g, String where) {
      if (g != null && !groups.contains(g)) {
        out.add(LintIssue('lint.group.missing', '$where uses group "$g" that the pattern does not define', ruleId: r.id));
      }
    }

    for (var i = 0; i < r.emit.length; i++) {
      final e = r.emit[i];
      for (final a in e.amounts ?? const <EmitAmount>[]) {
        need(a.from, 'emit[$i].amounts');
        need(a.unitFrom, 'emit[$i].amounts.unitFrom');
        need(a.original?.from, 'emit[$i].amounts.original');
        need(a.original?.currencyFrom, 'emit[$i].amounts.original.currencyFrom');
      }
      need(e.occurredAt?['from'] as String?, 'emit[$i].occurredAt');
      for (final k in const ['maskFrom', 'maskLengthFrom', 'productNameFrom', 'issuerSlugFrom']) {
        need(e.instrument?[k] as String?, 'emit[$i].instrument.$k');
      }
      final maskGroup = e.instrument?['maskFrom'] as String?;
      if (maskGroup != null && maskFollowsOpenSkip(r.match.pattern, maskGroup)) {
        out.add(LintIssue(
          'lint.mask.open_skip',
          'emit[$i] takes its mask from "$maskGroup", which follows a wide skip over arbitrary text; '
          'the digits can be a reference number. Introduce the mask with a closed list (ending, no, number) and mask characters',
          ruleId: r.id,
        ));
      }
      for (final k in const ['nameFrom', 'vpaFrom', 'accountMaskFrom']) {
        need(e.counterparty?[k] as String?, 'emit[$i].counterparty.$k');
      }
      for (final g in (e.references ?? const <String, String>{}).values) {
        need(g, 'emit[$i].references');
      }
      for (final v in (e.attrs ?? const <String, Object?>{}).values) {
        if (v is Map && v['from'] is String) need(v['from'] as String, 'emit[$i].attrs');
      }
    }
  }
  for (final r in bundle.ignoreRules) {
    out.addAll(lintRegexDialect(r.pattern, r.flags, ruleId: r.id));
    senders(r.id, r.senders);
  }
  for (final p in bundle.counterpartyPurposes) {
    for (final pat in [p.vpaPattern, p.namePattern]) {
      if (pat != null) out.addAll(lintRegexDialect(pat, 'i', ruleId: p.id));
    }
  }

  for (final f in runRuleExamples(bundle)) {
    if (f.kind == 'positive_shadowed') {
      out.add(LintIssue('lint.shadowed', f.message, ruleId: f.ruleId));
    } else if (f.kind == 'mask_looks_like_year') {
      out.add(LintIssue('lint.mask.year_like', f.message, ruleId: f.ruleId));
    } else if (f.kind == 'bundle_refused') {
      out.add(LintIssue('lint.bundle.refused', f.message));
    }
  }
  return out;
}
