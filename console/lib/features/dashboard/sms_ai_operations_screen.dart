import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Operational view for the durable SMS AI queue. It intentionally shows
/// counters, redacted source keys and event counts; message bodies never
/// belong in the admin dashboard.
class SmsAiOperationsScreen extends ConsumerWidget {
  const SmsAiOperationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(smsAiSummaryProvider);
    final jobs = ref.watch(smsAiJobsProvider);
    final quota = ref.watch(smsAiQuotaProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('SMS AI Operations'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(smsAiSummaryProvider);
              ref.invalidate(smsAiJobsProvider);
              ref.invalidate(smsAiQuotaProvider);
              ref.invalidate(smsLearningCandidatesProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          summary.when(
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => Text('Summary failed: $error'),
            data: (data) => _SummaryCard(data: data),
          ),
          const SizedBox(height: 16),
          Text('Shared learning candidates', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text(
            'These are aggregated correction signals. Marking one for manual pattern authoring creates a work item only; it does not activate a parser pattern.',
          ),
          const SizedBox(height: 8),
          const _LearningCandidatesSection(),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text('Recent jobs', style: Theme.of(context).textTheme.titleLarge)),
              const SizedBox(width: 12),
              DropdownButton<String?>(
                value: ref.watch(smsAiJobStatusFilterProvider),
                hint: const Text('All statuses'),
                items: const [
                  DropdownMenuItem<String?>(value: null, child: Text('All statuses')),
                  DropdownMenuItem<String?>(value: 'queued', child: Text('Queued')),
                  DropdownMenuItem<String?>(value: 'leased', child: Text('Leased')),
                  DropdownMenuItem<String?>(value: 'done', child: Text('Done')),
                  DropdownMenuItem<String?>(value: 'failed', child: Text('Failed')),
                ],
                onChanged: (value) => ref.read(smsAiJobStatusFilterProvider.notifier).state = value,
              ),
            ],
          ),
          const SizedBox(height: 8),
          jobs.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Text('Jobs failed: $error'),
            data: (items) => _JobsTable(items: items),
          ),
          const SizedBox(height: 16),
          Text('Quota by anonymized user', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          quota.when(
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => Text('Quota failed: $error'),
            data: (items) => _QuotaTable(items: items),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _SummaryCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final counts = (data['statusCounts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final capacity = (data['providerCapacity'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            _Metric(label: 'Queued', value: '${counts['queued'] ?? 0}'),
            _Metric(label: 'Leased', value: '${counts['leased'] ?? 0}'),
            _Metric(label: 'Done', value: '${counts['done'] ?? 0}'),
            _Metric(label: 'Failed', value: '${counts['failed'] ?? 0}'),
            _Metric(label: 'Oldest queue (s)', value: '${data['oldestAgeSeconds'] ?? 0}'),
            _Metric(label: 'Retries', value: '${data['retryCount'] ?? 0}'),
            _Metric(label: 'Batches today', value: '${data['batchesToday'] ?? 0}'),
            _Metric(label: 'Jobs in multi-SMS batches', value: '${data['batchedJobsToday'] ?? 0}'),
            _Metric(
              label: 'Provider requests / min',
              value: '${capacity['requestsLastMinute'] ?? '—'} / ${capacity['requestsPerMinuteLimit'] ?? '—'}',
            ),
            _Metric(
              label: 'Estimated tokens / min',
              value: '${capacity['tokensLastMinute'] ?? '—'} / ${capacity['tokensPerMinuteLimit'] ?? '—'}',
            ),
            _Metric(label: 'Capacity waits (last min)', value: '${capacity['waitingLastMinute'] ?? '—'}'),
            _Metric(
              label: 'Permanently blocked (last min)',
              value: '${capacity['permanentlyBlockedLastMinute'] ?? '—'}',
            ),
          ],
        ),
      ),
    );
  }
}

class _LearningCandidatesSection extends ConsumerWidget {
  const _LearningCandidatesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates = ref.watch(smsLearningCandidatesProvider);
    return candidates.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text('Learning candidates failed: $error'),
      data: (items) {
        if (items.isEmpty) {
          return const Text('No eligible candidates yet. Candidates require feedback from multiple users.');
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                child: ListTile(
                  title: Text('${item['fact_family'] ?? 'unknown'} · ${item['corrected_field'] ?? 'unknown field'}'),
                  subtitle: Text(
                    '${item['distinct_users'] ?? 0} users · ${item['feedback_count'] ?? 0} corrections · '
                    'last feedback ${item['last_feedback_at'] ?? 'unknown'}'
                    '${item['decision'] == null ? '' : ' · decision: ${item['decision']}'}',
                  ),
                  trailing: item['decision'] == null
                      ? Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: item['id'] is String
                                  ? () => _decide(context, ref, item['id'] as String, 'reject')
                                  : null,
                              child: const Text('Reject'),
                            ),
                            FilledButton.tonal(
                              onPressed: item['id'] is String
                                  ? () => _decide(context, ref, item['id'] as String, 'manual_pattern_authoring')
                                  : null,
                              child: const Text('Send to pattern authoring'),
                            ),
                          ],
                        )
                      : const Icon(Icons.check_circle_outline),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, String id, String decision) async {
    final api = ref.read(adminApiProvider);
    if (api == null) return;
    try {
      await api.decideSmsLearningCandidate(id, decision);
      ref.invalidate(smsLearningCandidatesProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              decision == 'reject'
                  ? 'Candidate rejected.'
                  : 'Manual pattern-authoring work item recorded. No parser pattern was activated.',
            ),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update candidate: $error')));
      }
    }
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  const _Metric({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: Theme.of(context).textTheme.headlineSmall),
      Text(label),
    ],
  );
}

class _JobsTable extends ConsumerWidget {
  final List<Map<String, dynamic>> items;
  const _JobsTable({required this.items});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) return const Text('No jobs');
    return Column(
      children: [
        for (final item in items)
          Card(
            child: ExpansionTile(
              key: PageStorageKey('sms-ai-${item['id']}'),
              title: Text('${item['status'] ?? 'unknown'} · attempts ${item['attempts'] ?? 0}'),
              subtitle: Text(
                'Source ${_shortSource(item['source_key']?.toString() ?? '')} · '
                '${item['created_at'] ?? ''} · elapsed ${_elapsed(item['created_at'], item['updated_at'])}',
              ),
              onExpansionChanged: (expanded) {
                if (expanded && item['id'] is String) {
                  ref.invalidate(smsAiJobTimelineProvider(item['id'] as String));
                }
              },
              children: [
                _JobOutcome(item: item),
                Consumer(
                  builder: (context, ref, _) {
                    final id = item['id'];
                    if (id is! String) return const ListTile(title: Text('Job ID unavailable'));
                    final timeline = ref.watch(smsAiJobTimelineProvider(id));
                    return timeline.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (error, _) => ListTile(title: Text('Timeline unavailable: $error')),
                      data: (events) => events.isEmpty
                          ? const ListTile(title: Text('No events'))
                          : Column(
                              children: [
                                for (final event in events)
                                  ListTile(
                                    dense: true,
                                    title: Text('${event['event_type'] ?? 'event'}'),
                                    subtitle: Text(
                                      '${event['created_at'] ?? ''}  ${_safeEventSummary(event['payload'])}',
                                    ),
                                  ),
                              ],
                            ),
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _shortSource(String value) =>
      value.length <= 16 ? value : '${value.substring(0, 8)}…${value.substring(value.length - 8)}';

  String _elapsed(dynamic created, dynamic updated) {
    final start = DateTime.tryParse(created?.toString() ?? '');
    final end = DateTime.tryParse(updated?.toString() ?? '');
    if (start == null || end == null || end.isBefore(start)) return 'unavailable';
    final seconds = end.difference(start).inSeconds;
    if (seconds < 60) return '${seconds}s (queue + processing)';
    return '${seconds ~/ 60}m ${seconds % 60}s (queue + processing)';
  }

  String _safeEventSummary(dynamic payload) {
    if (payload is! Map) return '';
    const allowed = ['reason', 'landed', 'skippedExisting', 'attempts', 'leaseMinutes', 'batchId', 'batchSize'];
    return payload.entries
        .where((entry) => allowed.contains(entry.key))
        .where((entry) => entry.value is num || entry.value is bool || entry.value is String)
        .map((entry) => '${entry.key}: ${entry.value}')
        .join(' · ');
  }
}

/// Only shows the compact, server-generated result summary. Raw SMS text and
/// full fact payloads are deliberately never rendered in the operations UI.
class _JobOutcome extends StatelessWidget {
  final Map<String, dynamic> item;
  const _JobOutcome({required this.item});

  @override
  Widget build(BuildContext context) {
    final result = item['result'];
    if (result is! Map) return const SizedBox.shrink();
    final types = result['factTypes'];
    final typeSummary = types is List ? types.whereType<String>().join(', ') : '';
    final reviewRequired = result['reviewRequired'];
    final safelyProjected = reviewRequired == false;
    return ListTile(
      dense: true,
      leading: Icon(safelyProjected ? Icons.check_circle_outline : Icons.rate_review_outlined),
      title: Text(
        safelyProjected
            ? 'Result safely projected'
            : reviewRequired == true
            ? 'Result still needs user review'
            : 'Review status unavailable',
      ),
      subtitle: Text(typeSummary.isEmpty ? 'No fact type summary' : 'Fact types: $typeSummary'),
    );
  }
}

class _QuotaTable extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  const _QuotaTable({required this.items});
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Text('No quota usage');
    return DataTable(
      columns: const [
        DataColumn(label: Text('User key')),
        DataColumn(label: Text('Day')),
        DataColumn(label: Text('Jobs used')),
      ],
      rows: [
        for (final item in items)
          DataRow(
            cells: [
              DataCell(Text('${item['user_key'] ?? ''}')),
              DataCell(Text('${item['day'] ?? ''}')),
              DataCell(Text('${item['jobs_used'] ?? 0}')),
            ],
          ),
      ],
    );
  }
}
