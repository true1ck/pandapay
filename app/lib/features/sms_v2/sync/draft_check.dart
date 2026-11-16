import 'dart:isolate';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';

/// The outcome of checking an AI draft against a message it was drafted for.
/// [wire] is the `reason` of POST /sms/v2/draft-rejections (null = pass).
enum DraftCheck {
  pass(null),
  noMatch('no_match'),
  invalidFacts('invalid_facts'),
  unsafeRule('unsafe_rule');

  const DraftCheck(this.wire);
  final String? wire;
}

typedef DraftMessage = ({String sender, String body, DateTime receivedAt});

/// Checks the stored `ai:` [result] against up to a few original [messages] of
/// its layout, with the same expansion and engine ProvisionalStore uses.
///
/// Pure and deterministic. A draft that fails the rule-level checks (shape,
/// regex dialect, engine compile) is [DraftCheck.unsafeRule] whatever the
/// message. Otherwise it passes when it reads at least one message soundly; it
/// fails only when it fails on every message given, and then with the first
/// message's reason. [messages] must not be empty.
///
/// Takes and returns plain data so it can run in [checkDraftOffThread].
DraftCheck checkDraft({
  required Map<String, Object?> sharedJson,
  required Map<String, Object?> result,
  required String senderBrand,
  required List<DraftMessage> messages,
}) {
  final Rule rule;
  try {
    final hash = result['templateHash'];
    rule = Rule.fromJson((result['rule'] as Map).cast<String, Object?>());
    if (hash is! String ||
        rule.status != RuleStatus.provisional ||
        rule.match.templateHash != hash ||
        rule.senders.length != 1 ||
        rule.senders.single != senderBrand ||
        lintRegexDialect(rule.match.pattern, rule.match.flags).isNotEmpty) {
      return DraftCheck.unsafeRule;
    }
  } on ContractException {
    return DraftCheck.unsafeRule;
  } on TypeError {
    return DraftCheck.unsafeRule;
  }
  final shared = RuleBundle.fromJson(sharedJson);
  // An installed signed rule of the same id already stands in for the draft.
  if (shared.rules.any((installed) => installed.id == rule.id)) {
    return DraftCheck.pass;
  }
  final sender = normalizeSenderBrand(senderBrand, shared.senders).brand;
  DraftCheck? first;
  for (final message in messages) {
    final localHash = smsTemplateHash(
      smsTemplateBrand(message.sender),
      smsSkeleton(message.body),
    );
    final local = Rule.fromJson({
      ...rule.toJson(),
      'id': '${rule.id}:local:$localHash',
      'senders': [sender],
      'match': {...rule.match.toJson(), 'templateHash': localHash},
    });
    final RuleBundle bundle;
    final engine = RuleEngine();
    try {
      bundle = RuleBundle.fromJson({
        ...sharedJson,
        'rules': [local.toJson()],
      });
      engine.compiled(bundle);
    } on ContractException {
      return DraftCheck.unsafeRule;
    } on BundleRefusedException {
      return DraftCheck.unsafeRule;
    }
    final outcome = engine.interpretDetailed(
      SmsMessage(
        sender: message.sender,
        body: message.body,
        observedAt: message.receivedAt.toUtc(),
        sourceKey: 'draft-check',
      ),
      bundle,
      appVersion: 'draft-check',
    );
    final DraftCheck verdict;
    if ((engine.stats.invalidEmits[local.id] ?? 0) > 0) {
      verdict = DraftCheck.invalidFacts;
    } else if (outcome.result.ruleId == local.id &&
        outcome.result.outcome != InterpretOutcome.unknown) {
      verdict =
          outcome.result.outcome == InterpretOutcome.ignored ||
              _factsAreInMessage(outcome.result.facts, message.body)
          ? DraftCheck.pass
          : DraftCheck.invalidFacts;
    } else if (outcome.detail == 'overruled ${local.id}') {
      // It matched; the engine's evidence reader preferred a money movement.
      verdict = DraftCheck.pass;
    } else {
      verdict = DraftCheck.noMatch;
    }
    if (verdict == DraftCheck.pass) return verdict;
    first ??= verdict;
  }
  return first ?? DraftCheck.noMatch;
}

/// Heavy part (bundle parse + compile per message) off the UI isolate.
/// A top-level function so the closure carries only plain data.
Future<DraftCheck> checkDraftOffThread({
  required Map<String, Object?> sharedJson,
  required Map<String, Object?> result,
  required String senderBrand,
  required List<DraftMessage> messages,
}) => Isolate.run(
  () => checkDraft(
    sharedJson: sharedJson,
    result: result,
    senderBrand: senderBrand,
    messages: messages,
  ),
);

/// At least one fact, every rupee amount printed in the message, and every
/// reference value (account, ref number) found in its text.
bool _factsAreInMessage(List<Fact> facts, String body) {
  if (facts.isEmpty) return false;
  final plain = body.replaceAll(',', '');
  final lower = body.toLowerCase();
  for (final fact in facts) {
    for (final amount in fact.amounts) {
      if (!amount.isInr) continue;
      final rupees = amount.minor ~/ 100, paise = amount.minor % 100;
      final shown = <String>[
        '$rupees.${paise.toString().padLeft(2, '0')}',
        if (paise == 0) '$rupees',
        if (paise % 10 == 0) '$rupees.${paise ~/ 10}',
      ];
      if (!shown.any((needle) => _hasNumber(plain, needle))) return false;
    }
    for (final ref in fact.references.values) {
      if (ref.isNotEmpty && !lower.contains(ref.toLowerCase())) return false;
    }
  }
  return true;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// [needle] as a whole number in [text]: not inside a longer run of digits.
bool _hasNumber(String text, String needle) {
  for (var at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + 1)) {
    final end = at + needle.length;
    if (at > 0 &&
        (_isDigit(text.codeUnitAt(at - 1)) ||
            (text.codeUnitAt(at - 1) == 0x2E &&
                at > 1 &&
                _isDigit(text.codeUnitAt(at - 2))))) {
      continue;
    }
    if (end < text.length && _isDigit(text.codeUnitAt(end))) continue;
    if (end + 1 < text.length &&
        text.codeUnitAt(end) == 0x2E &&
        _isDigit(text.codeUnitAt(end + 1)) &&
        !needle.contains('.')) {
      continue;
    }
    return true;
  }
  return false;
}
