import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// C7: admin review surface for EXPLICIT user corrections stored in
/// `sms_learning_feedback_events` (migration 20261027190000's typed
/// correction envelope).
///
/// Privacy boundary (mirrors api/'s SAFE_FIELDS/decision-redaction contract):
/// the only message evidence shown is the server-generalized `redactedPattern`
/// — never a raw SMS body. Decision fields are rendered only when their key is
/// in [kSafeDecisionFieldKeys], so a body/account/reference/OTP key that ever
/// appeared in a payload would be dropped, not displayed. `subscription` and
/// the other commitment labels are never rendered as a spend category slug.
///
/// These cases are read-only: the correction is already applied on the user's
/// device, and no admin approval endpoint exists for explicit feedback events,
/// so no approve/reject actions are offered (unlike the AI/parser/category
/// proposal tabs).

/// Canonical 15 spend categories (app/lib/data/sms_fact_contract.dart, api and
/// SQL agree). Anything outside this set is never displayed as a spend slug.
const List<String> kSpendCategorySlugs = [
  'groceries', 'fuel', 'dining', 'online', 'travel', 'bills', 'rent',
  'insurance', 'education', 'government', 'wallet', 'entertainment',
  'health', 'emi', 'other',
];

/// Commitment-family taxonomy (CommitmentCategory on the device). A value from
/// this set that is not also a spend slug (e.g. 'subscription', 'utility')
/// must never render as a spend category.
const Set<String> kCommitmentCategories = {
  'utility', 'telecom', 'insurance', 'loanOrEmi', 'rent',
  'education', 'tax', 'subscription', 'other',
};

/// Kinds that make no claim about machine correctness; they must never train a
/// shared classification rule and are labelled as such here.
const Set<String> kNonTrainingCorrectionKinds = {
  'cosmetic', 'preference_only', 'duplicate', 'already_paid',
};

/// Allow-list of decision field keys the console will render, mirroring the
/// API's SAFE_FIELDS for `original_decision`/`corrected_fields` JSONB.
const Set<String> kSafeDecisionFieldKeys = {
  'entryKind', 'instrument', 'amountInr', 'availableBalanceInr',
  'currentBalanceInr', 'amountDueInr', 'minimumDueInr', 'amountRole',
  'dueDate', 'statementDate', 'asOfAt', 'mandateStatus', 'merchant',
  'cadenceDays', 'limitInr', 'currency', 'categorySlug', 'occurredAt',
  'commitmentCategory', 'billerName',
};

const String _kPreferenceLabelSuffix = ' — does not train rules';

bool isNonTrainingKind(String? kind) =>
    kind != null && kNonTrainingCorrectionKinds.contains(kind);

/// Human label for a typed correction kind. Non-training kinds are explicitly
/// labelled so an operator can never mistake them for trainable proposals.
String correctionKindLabel(String? kind) {
  if (kind == null || kind.isEmpty) return 'Correction (untyped)';
  const names = {
    'misclassified_category': 'Misclassified category',
    'misclassified_kind': 'Misclassified kind',
    'wrong_amount': 'Wrong amount',
    'wrong_merchant': 'Wrong merchant',
    'wrong_date': 'Wrong date',
    'wrong_direction': 'Wrong direction',
    'wrong_instrument': 'Wrong instrument',
    'wrong_account': 'Wrong account',
    'wrong_bill_fields': 'Wrong bill fields',
    'false_transaction': 'False transaction',
    'false_dismissal': 'False dismissal',
    'duplicate': 'Duplicate',
    'already_paid': 'Already paid',
    'cosmetic': 'Cosmetic',
    'preference_only': 'Preference',
  };
  final name = names[kind] ?? kind;
  return isNonTrainingKind(kind) ? '$name$_kPreferenceLabelSuffix' : name;
}

bool isCanonicalSpendSlug(String? slug) =>
    slug != null && kSpendCategorySlugs.contains(slug);

/// Reads `camelCase` then `snake_case` for the same logical key.
Object? caseAware(Map<String, dynamic> map, String camel, String snake) =>
    map[camel] ?? map[snake];

/// A decision field only renders when the key is allow-listed AND the value is
/// not a commitment-only category (those never appear as spend-category-like
/// field values; they render on the commitment line instead).
bool isRenderableField(String key, Object? value) {
  if (!kSafeDecisionFieldKeys.contains(key)) return false;
  if (key == 'categorySlug' && value is String &&
      !isCanonicalSpendSlug(value)) {
    return false;
  }
  if (key == 'commitmentCategory' && value is String &&
      !kCommitmentCategories.contains(value)) {
    return false;
  }
  return true;
}

/// Previous vs corrected values for one allow-listed decision field.
/// `map` is `{key: [previous, corrected]}`.
Map<String, List<Object?>> decisionFieldDiff(
  Map<String, dynamic> originalFields,
  Map<String, dynamic> correctedFields,
) {
  final keys = <String>{
    ...originalFields.keys.whereType<String>(),
    ...correctedFields.keys.whereType<String>(),
  };
  final result = <String, List<Object?>>{};
  for (final key in keys) {
    final previous = originalFields[key];
    final corrected = correctedFields[key];
    // A non-null value that fails the allow-list (a raw body key, an account
    // number, or a commitment-only slug on a spend-category field) suppresses
    // the whole diff row rather than leaking half of it.
    bool sideAllowed(Object? value) =>
        value == null || isRenderableField(key, value);
    if (!sideAllowed(previous) || !sideAllowed(corrected)) continue;
    // Unchanged fields carry no review information.
    if (previous == corrected) continue;
    result[key] = [previous, corrected];
  }
  return result;
}

class SmsCorrectionCasesTab extends ConsumerWidget {
  const SmsCorrectionCasesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cases = ref.watch(smsCorrectionCasesProvider);
    return cases.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text('Could not load correction cases: $error'),
      ),
      data: (rows) => rows.isEmpty
          ? const Center(child: Text('No explicit correction cases yet'))
          : ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) =>
                  _CorrectionCaseTile(rows[index]),
            ),
    );
  }
}

class _CorrectionCaseTile extends StatelessWidget {
  const _CorrectionCaseTile(this.caseRow);

  final Map<String, dynamic> caseRow;

  static String _display(Object? value) =>
      value == null ? '—' : value.toString();

  @override
  Widget build(BuildContext context) {
    final kind = caseAware(caseRow, 'correctionKind', 'correction_kind') as String?;
    final nonTraining = isNonTrainingKind(kind);
    final supersededAt = caseAware(caseRow, 'supersededAt', 'superseded_at');
    final supersededBy =
        caseAware(caseRow, 'supersededByEventId', 'superseded_by_event_id');
    final origin =
        caseAware(caseRow, 'decisionOrigin', 'decision_origin') as String?;
    final ruleId =
        caseAware(caseRow, 'decisionRuleId', 'decision_rule_id') as String?;
    final resolvedKind =
        caseAware(caseRow, 'resolvedKind', 'resolved_kind') as String?;
    final pattern = caseAware(caseRow, 'redactedPattern', 'redacted_pattern');
    final originalDecision = caseAware(
      caseRow, 'originalDecision', 'original_decision');
    final originalFields = originalDecision is Map
        ? (originalDecision['fields'] as Map? ?? const {})
        : const {};
    final correctedFields = caseAware(
      caseRow, 'correctedFields', 'corrected_fields');
    final corrected = correctedFields is Map
        ? Map<String, dynamic>.from(correctedFields)
        : <String, dynamic>{};
    final diff = decisionFieldDiff(
      Map<String, dynamic>.from(originalFields),
      corrected,
    );
    final categorySlug =
        caseAware(caseRow, 'categorySlug', 'category_slug') as String?;
    final originalCategorySlug = caseAware(
      caseRow, 'originalCategorySlug', 'original_category_slug') as String?;
    final commitmentCategory = caseAware(
      caseRow, 'commitmentCategory', 'commitment_category') as String?;
    final support = caseAware(caseRow, 'support', 'support');
    final supportUsers = support is Map
        ? (support['users'] ?? support['user_count'])
        : caseAware(caseRow, 'supportUsers', 'support_users');
    final supportMessages = support is Map
        ? (support['messages'] ?? support['message_count'])
        : caseAware(caseRow, 'supportMessages', 'support_messages');
    final disagreement = caseAware(caseRow, 'disagreement', 'disagreement');
    final disagreementUsers = disagreement is Map
        ? (disagreement['users'] ?? disagreement['user_count'])
        : caseAware(caseRow, 'disagreementCount', 'disagreement_count');
    final messageAt = caseAware(caseRow, 'messageAt', 'message_at');

    return ExpansionTile(
      title: Text(correctionKindLabel(kind)),
      subtitle: Text(
        '${supersededAt == null ? 'Current correction' : 'Superseded by a later correction'}'
        ' · origin: ${_display(origin)}',
      ),
      trailing: nonTraining
          ? const Tooltip(
              message: 'This correction makes no claim about correctness and '
                  'never trains a shared rule.',
              child: Icon(Icons.block),
            )
          : null,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (nonTraining)
                Text('${correctionKindLabel(kind)}: no claim about machine '
                    'correctness; never contributes to rule proposals.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600)),
              _EvidenceBlock(pattern: pattern),
              const SizedBox(height: 8),
              // L14: the AI diagnosis for the same source, when one exists, is
              // advisory context for the reviewing admin — never training
              // evidence and never a substitute for the user's correction.
              ..._aiDiagnosisLines(),
              SelectableText(
                'Decision being corrected: ${_display(
                  originalDecision is Map
                      ? (originalDecision['kind'] ?? resolvedKind)
                      : resolvedKind,
                )} · ${_display(origin)}'
                '${ruleId == null ? '' : ' · rule: $ruleId'}\n'
                'Fact key: ${_display(caseAware(caseRow, "factKey", "fact_key"))}\n'
                'Message time: ${_display(messageAt)}\n'
                'Support: ${_display(supportUsers)} users · '
                '${_display(supportMessages)} matching SMS\n'
                'Disagreement: ${_display(disagreementUsers)} users countered\n'
                'State: ${supersededAt == null
                    ? 'current'
                    : 'superseded at $supersededAt by event ${_display(supersededBy)}'}',
              ),
              // Spend category line: only canonical spend slugs are shown, so
              // a commitment label such as 'subscription' can never appear
              // here.
              if (categorySlug != null &&
                  isCanonicalSpendSlug(categorySlug))
                SelectableText(
                  'Category: ${originalCategorySlug ?? '—'} → $categorySlug'),
              // Commitment family corrections use their own taxonomy line.
              if (commitmentCategory != null &&
                  kCommitmentCategories.contains(commitmentCategory))
                SelectableText('Commitment category: $commitmentCategory'),
              if (diff.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Previous → corrected decision fields',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                ...diff.entries.map((entry) => SelectableText(
                    '${entry.key}: ${_display(entry.value[0])} → '
                    '${_display(entry.value[1])}')),
              ],
              const SizedBox(height: 8),
              const Text(
                'Explicit corrections are already applied on the user’s '
                'device. This case is informational; shared-rule delivery '
                'still requires the parser/category approval gates.',
                style: TextStyle(fontStyle: FontStyle.italic)),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }

  /// Renders the advisory AI diagnosis attached by the admin route, when one
  /// exists. Only the server-generalized pattern and sanitized proposal
  /// fields are shown, explicitly labelled advisory.
  List<Widget> _aiDiagnosisLines() {
    final diagnosis = caseAware(caseRow, 'aiDiagnosis', 'ai_diagnosis');
    if (diagnosis is! Map || diagnosis.isEmpty) return const [];
    final pattern = diagnosis['redactedPattern'] ?? diagnosis['redacted_pattern'];
    final score = diagnosis['score'] ?? diagnosis['ai_score'];
    final status = diagnosis['proposalStatus'] ?? diagnosis['proposal_status'];
    final fields = diagnosis['proposedFields'] ?? diagnosis['proposed_fields'];
    final fieldText = fields is Map && fields.isNotEmpty
        ? ' · proposed: ${fields.entries
            .where((entry) => kSafeDecisionFieldKeys.contains(entry.key))
            .map((entry) => '${entry.key}=${entry.value}')
            .join(', ')}'
        : '';
    return [
      SelectableText(
        'AI diagnosis (advisory): ${pattern is String && pattern.trim().isNotEmpty
            ? pattern
            : 'no safe pattern stored'}'
        '${score == null ? '' : ' · score $score'}'
        '${status == null ? '' : ' · proposal $status'}$fieldText',
      ),
    ];
  }
}

/// Renders only the backend-generalized pattern. Never falls back to a raw
/// body/message/sample field: if the redacted pattern is absent the block is
/// simply omitted.
class _EvidenceBlock extends StatelessWidget {
  const _EvidenceBlock({required this.pattern});

  final Object? pattern;

  @override
  Widget build(BuildContext context) {
    final text = pattern is String ? (pattern as String).trim() : '';
    if (text.isEmpty) {
      return const Text(
        'No safe message pattern was stored for this correction.',
        style: TextStyle(fontStyle: FontStyle.italic));
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8)),
      child: SelectableText('Generalized SMS pattern: $text'),
    );
  }
}
