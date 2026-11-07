import 'dart:convert';
import 'package:flutter/material.dart';
import '../../data/admin_api.dart';
import '../../data/sms_v2_admin_api.dart';
import 'reason_dialog.dart';

/// Every state a shared layout can be in, in the order the filter chips show.
const smsTemplateStatuses = <String>[
  'held',
  'queued',
  'working',
  'ready',
  'failed',
  'covered',
  'rejected',
  'blocked',
];

/// Why an admin may reject an AI draft. The key is what the server stores.
const smsRejectReasons = <String, String>{
  'wrong_fact_type': 'The fact type is wrong',
  'wrong_amount_role': 'The amount role is wrong',
  'overmatches': 'It matches too much',
  'misses_fields': 'It misses fields',
  'should_be_ignored': 'This message should be ignored',
  'other': 'Something else (write a note)',
};

/// "rejected" is a decision on a draft; the layout itself is at `failed`.
String templateStatusOf(Map row) =>
    row['admin_decision'] == 'rejected' ? 'rejected' : '${row['ai_status']}';

/// Why a shared layout is not drafted, or was turned down. Held ones never
/// reach the AI, failed ones carry the worker's failure code. Null otherwise.
String? templateStatusReason(Map row) {
  if (row['admin_decision'] == 'rejected') {
    final reason = smsRejectReasons['${row['admin_reason']}'] ?? '${row['admin_reason']}';
    final note = row['admin_note'];
    return 'Rejected: $reason${note is String && note.isNotEmpty ? ' · $note' : ''}';
  }
  return switch (row['ai_status']) {
    'held' =>
      'Held: sent without a valid App Check token, so it was not sent to the AI',
    'failed' => 'Failed: ${row['failure_code'] ?? 'unknown'}',
    'covered' => 'Covered: already read by ${row['covered_by'] ?? 'an active rule'}',
    'blocked' => 'Blocked: ${row['admin_reason'] ?? 'by an admin'}',
    _ => null,
  };
}

/// True when the draft emits only `info` facts: the AI thinks this is not a
/// money message.
bool draftIsNotMoney(Map row) {
  final emit = (row['ai_draft'] as Map?)?['emit'];
  return emit is List &&
      emit.isNotEmpty &&
      emit.every((e) => e is Map && e['factType'] == 'info');
}

/// "Private rule on 3 phones: 12 hits, 1 corrected" when phones have reported
/// on the draft's private rule; null before any phone has.
String? privateRuleLine(Map row) {
  final phones = row['privatePhones'];
  if (phones is! num) return null;
  return 'Private rule on ${phones.toInt()} ${phones == 1 ? 'phone' : 'phones'}: '
      '${row['privateHits'] ?? 0} hits, ${row['privateCorrected'] ?? 0} corrected';
}

class SmsTemplatesTab extends StatefulWidget {
  const SmsTemplatesTab({super.key, required this.api, required this.onOpenRule});
  final SmsV2AdminApi api;

  /// Opens the rule editor for a draft made from a layout.
  final void Function(String ruleId) onOpenRule;
  @override
  State<SmsTemplatesTab> createState() => _SmsTemplatesTabState();
}

class _SmsTemplatesTabState extends State<SmsTemplatesTab> {
  late Future<List<Map<String, dynamic>>> _future = widget.api.templates();
  String? _filter;

  void _reload() => setState(() {
    _future = widget.api.templates();
  });

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String _failure(Object error) =>
      error is AdminApiException ? error.message : error.toString();

  Future<void> _createDraft(Map row) async {
    try {
      final draft = await widget.api.templateDraft(row['template_hash'] as String);
      widget.onOpenRule(draft['ruleId'] as String);
    } catch (error) {
      if (mounted) _say(error.toString());
    }
  }

  Future<void> _reject(Map row) async {
    final answer = await askReason(
      context,
      title: 'Reject this draft?',
      message:
          'The sender’s phone drops the private rule and reads the message again. The next draft for this sender sees the reason.',
      choices: smsRejectReasons,
      noteRequiredFor: const {'other'},
      confirmLabel: 'Reject',
    );
    if (answer == null) return;
    try {
      await widget.api.rejectTemplate(
        row['template_hash'] as String,
        answer.choice!,
        answer.reason.isEmpty ? null : answer.reason,
      );
      if (mounted) _say('Draft rejected.');
    } catch (error) {
      if (mounted) _say(_failure(error));
    }
    if (mounted) _reload();
  }

  Future<void> _requeue(Map row) async {
    final answer = await askReason(
      context,
      title: 'Put this layout back in the queue?',
      message: 'The AI drafts it again, with the current prompt.',
      label: 'Why try again?',
      confirmLabel: 'Requeue',
    );
    if (answer == null) return;
    try {
      await widget.api.requeueTemplate(row['template_hash'] as String, answer.reason);
      if (mounted) _say('Back in the queue.');
    } catch (error) {
      if (mounted) _say(_failure(error));
    }
    if (mounted) _reload();
  }

  Future<void> _block(Map row) async {
    final answer = await askReason(
      context,
      title: 'Never send this layout to the AI?',
      message:
          'Phones drop any private rule for it and the layout stays blocked even if it is shared again.',
      label: 'Why block it?',
      confirmLabel: 'Block',
    );
    if (answer == null) return;
    try {
      await widget.api.blockTemplate(row['template_hash'] as String, answer.reason);
      if (mounted) _say('Blocked.');
    } catch (error) {
      if (mounted) _say(_failure(error));
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: TextButton(
            onPressed: _reload,
            child: const Text('Unable to load data. Retry'),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final all = snapshot.data!;
      if (all.isEmpty) {
        return const Center(child: Text('Nothing waiting for review.'));
      }
      final counts = <String, int>{
        for (final status in smsTemplateStatuses)
          status: all.where((row) => templateStatusOf(row) == status).length,
      };
      final rows = _filter == null
          ? all
          : all.where((row) => templateStatusOf(row) == _filter).toList();
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    key: const Key('filter-all'),
                    label: Text('All (${all.length})'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                  for (final status in smsTemplateStatuses)
                    ChoiceChip(
                      key: Key('filter-$status'),
                      label: Text('$status (${counts[status]})'),
                      selected: _filter == status,
                      onSelected: (_) => setState(() => _filter = status),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                final status = templateStatusOf(row);
                final ready = status == 'ready';
                return ExpansionTile(
                  key: Key('template-${row['template_hash']}'),
                  title: Text('${row['sender_brand']} · $status'),
                  subtitle: Text(
                    [
                      '${row['redacted_body']}',
                      '${row['seen_count']} sightings · ${row['distinct_profiles']} profiles',
                      ?templateStatusReason(row),
                      if (draftIsNotMoney(row)) 'AI: not a money message',
                      ?privateRuleLine(row),
                    ].join('\n'),
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: ready ? () => _createDraft(row) : null,
                        child: const Text('Create draft'),
                      ),
                      // An approved layout is final: the server refuses a rejection.
                      if (ready && row['admin_decision'] != 'approved')
                        TextButton(
                          key: Key('reject-${row['template_hash']}'),
                          onPressed: () => _reject(row),
                          child: const Text('Reject'),
                        ),
                      if (status == 'failed' || status == 'rejected')
                        TextButton(
                          key: Key('requeue-${row['template_hash']}'),
                          onPressed: () => _requeue(row),
                          child: const Text('Requeue'),
                        ),
                      if (status != 'blocked')
                        TextButton(
                          key: Key('block-${row['template_hash']}'),
                          onPressed: () => _block(row),
                          child: const Text('Block'),
                        ),
                    ],
                  ),
                  children: [
                    if (row['ai_draft'] != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          const JsonEncoder.withIndent('  ').convert(row['ai_draft']),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
