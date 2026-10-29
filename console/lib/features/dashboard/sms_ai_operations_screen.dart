import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Operational view for the durable SMS AI queue and the rules it learns.
/// Everything here is aggregate or redacted by construction: message bodies,
/// prompts and model output values never reach the console. Failure reasons
/// are server-side reason codes and validator messages only.
class SmsAiOperationsScreen extends ConsumerWidget {
  const SmsAiOperationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('SMS AI Operations'),
          actions: [
            IconButton(
              tooltip: 'Refresh all',
              onPressed: () {
                ref.invalidate(smsAiSummaryProvider);
                ref.invalidate(smsAiJobsProvider);
                ref.invalidate(smsAiQuotaProvider);
                ref.invalidate(smsLearningCandidatesProvider);
                ref.invalidate(smsLearningOperationsProvider);
                ref.invalidate(smsRolloutProvider);
                ref.invalidate(smsRuleBundlesProvider);
              },
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Jobs'),
              Tab(text: 'Learning'),
              Tab(text: 'Rules & rollout'),
              Tab(text: 'Dry run'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _OverviewTab(),
            _JobsTab(),
            _LearningTab(),
            _RulesTab(),
            _DryRunTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(smsAiSummaryProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        summary.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => _ErrorBlock(label: 'Summary failed', error: error),
          data: (data) => _SummaryCard(data: data),
        ),
        const SizedBox(height: 24),
        const _SectionHeader(
          title: 'Gemini rollout',
          description:
              'Resolved flags are what the API evaluates for a request. A percentage below 100 collapses to disabled for the anonymous view, so the raw flag rows are shown next to it.',
        ),
        const _RolloutPanel(),
        const SizedBox(height: 24),
        const _SectionHeader(
          title: 'Active rule bundle',
          description: 'The newest active bundle is what devices download. Older active bundles remain available as rollback targets.',
        ),
        const _ActiveBundleCard(),
        const SizedBox(height: 24),
        const _SectionHeader(
          title: 'Autonomous learning worker',
          description: 'A worker that stops reporting is the first sign that learned rules have stopped advancing.',
        ),
        const _WorkerRunsCard(),
        const SizedBox(height: 24),
        const _SectionHeader(
          title: 'Quota by anonymized user',
          description: 'Per-user job counts for the last seven days.',
        ),
        const _QuotaSection(),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String description;
  const _SectionHeader({required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(description, style: Theme.of(context).textTheme.bodySmall),
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
    final failureReasons =
        (data['failureReasons24h'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _Metric(label: 'Queued', value: '${counts['queued'] ?? 0}'),
                _Metric(label: 'Leased', value: '${counts['leased'] ?? 0}'),
                _Metric(label: 'Done', value: '${counts['done'] ?? 0}'),
                _Metric(label: 'Failed', value: '${counts['failed'] ?? 0}'),
                _Metric(label: 'Oldest queue (s)', value: '${data['oldestAgeSeconds'] ?? 0}'),
                _Metric(label: 'Retries', value: '${data['retryCount'] ?? 0}'),
                _Metric(label: 'Done today', value: '${data['doneToday'] ?? 0}'),
                _Metric(label: 'Auto-resolved today', value: '${data['autoResolvedToday'] ?? 0}'),
                _Metric(label: 'Needs review today', value: '${data['reviewRequiredToday'] ?? 0}'),
                _Metric(label: 'Failed (24h)', value: '${data['failureCount24h'] ?? 0}'),
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
            if (failureReasons.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Failure reasons (24h)', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in failureReasons.entries)
                    Chip(label: Text('${entry.key}: ${entry.value}')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RolloutPanel extends ConsumerStatefulWidget {
  const _RolloutPanel();

  @override
  ConsumerState<_RolloutPanel> createState() => _RolloutPanelState();
}

class _RolloutPanelState extends ConsumerState<_RolloutPanel> {
  String? _savingKey;

  @override
  Widget build(BuildContext context) {
    final rollout = ref.watch(smsRolloutProvider);
    return rollout.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => _ErrorBlock(label: 'Rollout failed', error: error),
      data: (data) {
        final resolved = (data['rollout'] as Map?)?.cast<String, dynamic>() ?? const {};
        final flags = (data['flags'] as List?)?.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() ??
            const <Map<String, dynamic>>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _FlagChip(label: 'Master', enabled: resolved['masterEnabled'] == true),
                _FlagChip(label: 'Spend facts', enabled: resolved['spendFamilyEnabled'] == true),
                _FlagChip(label: 'Balance facts', enabled: resolved['balanceFamilyEnabled'] == true),
                _FlagChip(label: 'Bill facts', enabled: resolved['billFamilyEnabled'] == true),
                _FlagChip(label: 'Mandate facts', enabled: resolved['mandateFamilyEnabled'] == true),
                _FlagChip(label: 'AI queue', enabled: resolved['aiQueueEnabled'] == true),
              ],
            ),
            const SizedBox(height: 12),
            if (flags.isEmpty)
              const Text('No sms_* feature flags are configured. The pipeline falls back to defaults.')
            else
              _WideTable(
                child: DataTable(
                  columnSpacing: 20,
                  columns: const [
                    DataColumn(label: Text('Flag')),
                    DataColumn(label: Text('Enabled')),
                    DataColumn(label: Text('Rollout %')),
                    DataColumn(label: Text('Min app version')),
                    DataColumn(label: Text('Platforms')),
                    DataColumn(label: Text('Updated')),
                  ],
                  rows: [
                    for (final flag in flags)
                      DataRow(
                        cells: [
                          DataCell(Text('${flag['key']}')),
                          DataCell(
                            Switch(
                              value: flag['is_enabled'] == true,
                              onChanged: _savingKey == flag['key']
                                  ? null
                                  : (value) => _toggle(flag['key'] as String, value),
                            ),
                          ),
                          DataCell(
                            InkWell(
                              onTap: () => _editPercent(flag),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Text('${flag['rollout_percent'] ?? 0}%  ✎'),
                              ),
                            ),
                          ),
                          DataCell(Text('${flag['min_app_version'] ?? '—'}')),
                          DataCell(Text((flag['platforms'] as List?)?.join(', ') ?? '—')),
                          DataCell(Text('${flag['updated_at'] ?? '—'}')),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _toggle(String key, bool value) async {
    final api = ref.read(adminApiProvider);
    if (api == null) {
      _showMessage('Not signed in with an admin session.');
      return;
    }
    setState(() => _savingKey = key);
    try {
      await api.updateSmsRolloutFlag(key, isEnabled: value, reason: 'admin_console_toggle');
      ref.invalidate(smsRolloutProvider);
      _showMessage('$key ${value ? 'enabled' : 'disabled'}.');
    } catch (error) {
      _showMessage('Could not update $key: $error');
    } finally {
      if (mounted) setState(() => _savingKey = null);
    }
  }

  Future<void> _editPercent(Map<String, dynamic> flag) async {
    final controller = TextEditingController(text: '${flag['rollout_percent'] ?? 0}');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Rollout percentage · ${flag['key']}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '0–100'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(controller.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value < 0 || value > 100) {
      if (value != null) _showMessage('Rollout must be between 0 and 100.');
      return;
    }
    final api = ref.read(adminApiProvider);
    if (api == null) {
      _showMessage('Not signed in with an admin session.');
      return;
    }
    try {
      await api.updateSmsRolloutFlag(
        flag['key'] as String,
        rolloutPercent: value,
        reason: 'admin_console_rollout_percentage',
      );
      ref.invalidate(smsRolloutProvider);
      _showMessage('${flag['key']} rollout set to $value%.');
    } catch (error) {
      _showMessage('Could not update ${flag['key']}: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _FlagChip extends StatelessWidget {
  final String label;
  final bool enabled;
  const _FlagChip({required this.label, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        enabled ? Icons.check_circle_outline : Icons.remove_circle_outline,
        size: 18,
        color: enabled ? Colors.green.shade700 : Theme.of(context).colorScheme.outline,
      ),
      label: Text('$label · ${enabled ? 'on' : 'off'}'),
    );
  }
}

class _ActiveBundleCard extends ConsumerWidget {
  const _ActiveBundleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operations = ref.watch(smsLearningOperationsProvider);
    return operations.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => _ErrorBlock(label: 'Active bundle failed', error: error),
      data: (data) {
        final bundle = (data['activeBundle'] as Map?)?.cast<String, dynamic>();
        if (bundle == null) return const Text('No active rule bundle.');
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _Metric(label: 'Bundle version', value: '${bundle['bundle_version'] ?? '—'}'),
                _Metric(label: 'Min client version', value: '${bundle['min_client_ver'] ?? '—'}'),
                _Metric(label: 'Published', value: '${bundle['published_at'] ?? '—'}'),
                _Metric(label: 'SHA-256', value: _shortHash(bundle['sha256']?.toString())),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WorkerRunsCard extends ConsumerWidget {
  const _WorkerRunsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operations = ref.watch(smsLearningOperationsProvider);
    return operations.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => _ErrorBlock(label: 'Worker history failed', error: error),
      data: (data) {
        final worker = (data['worker'] as Map?)?.cast<String, dynamic>();
        final runs = (worker?['runs'] as List?) ?? const [];
        if (runs.isEmpty) {
          return const Text('No worker runs recorded. The worker health table may not exist on this database yet.');
        }
        return _WideTable(
          child: DataTable(
            columnSpacing: 20,
            columns: const [
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Started')),
              DataColumn(label: Text('Finished')),
              DataColumn(label: Text('Details')),
            ],
            rows: [
              for (final run in runs.whereType<Map>())
                DataRow(
                  cells: [
                    DataCell(Text('${run['status'] ?? 'unknown'}')),
                    DataCell(Text('${run['started_at'] ?? '—'}')),
                    DataCell(Text('${run['finished_at'] ?? '—'}')),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Text(
                          _compactJson(run['details']),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QuotaSection extends ConsumerWidget {
  const _QuotaSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quota = ref.watch(smsAiQuotaProvider);
    return quota.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => _ErrorBlock(label: 'Quota failed', error: error),
      data: (items) {
        if (items.isEmpty) return const Text('No quota usage.');
        return _WideTable(
          child: DataTable(
            columns: const [
              DataColumn(label: Text('User key')),
              DataColumn(label: Text('Day')),
              DataColumn(label: Text('Jobs used')),
              DataColumn(label: Text('Updated')),
            ],
            rows: [
              for (final item in items)
                DataRow(
                  cells: [
                    DataCell(Text('${item['user_key'] ?? ''}')),
                    DataCell(Text('${item['day'] ?? ''}')),
                    DataCell(Text('${item['jobs_used'] ?? 0}')),
                    DataCell(Text('${item['updated_at'] ?? '—'}')),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------

class _JobsTab extends ConsumerWidget {
  const _JobsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(smsAiJobsProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Recent jobs', style: Theme.of(context).textTheme.titleLarge),
            ),
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
          error: (error, _) => _ErrorBlock(label: 'Jobs failed', error: error),
          data: (items) => _JobsTable(items: items),
        ),
      ],
    );
  }
}

class _JobsTable extends ConsumerWidget {
  final List<Map<String, dynamic>> items;
  const _JobsTable({required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) return const Text('No jobs for this filter.');
    return Column(
      children: [
        for (final item in items)
          Card(
            child: ExpansionTile(
              key: PageStorageKey('sms-ai-${item['id']}'),
              title: Text(
                '${item['status'] ?? 'unknown'} · attempts ${item['attempts'] ?? 0}'
                '${_decisionLabel(item) == null ? '' : ' · ${_decisionLabel(item)}'}',
              ),
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
                _JobFailure(item: item),
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

  static String? _decisionLabel(Map<String, dynamic> item) {
    final decision = item['decision'];
    if (decision is! Map) return null;
    final topic = decision['topic'] ?? decision['factFamily'];
    if (topic == null) return null;
    return 'decision $topic';
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
    const allowed = [
      'reason',
      'landed',
      'skippedExisting',
      'attempts',
      'leaseMinutes',
      'batchId',
      'batchSize',
      'failureClass',
      'retryClass',
      'statusCode',
      'model',
      'reviewRequired',
      'decisionValid',
    ];
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
    final typeSummary = _stringList(item['fact_types'] ?? result['factTypes']).join(', ');
    final review = item['review_required'] ?? result['reviewRequired'];
    final decision = item['decision'] ?? result['decision'];
    final decisionMap = decision is Map ? decision.cast<String, dynamic>() : const <String, dynamic>{};
    final reviewLabel = review == false
        ? 'Safely auto-resolved'
        : review == true
            ? 'Still needs user review'
            : 'Review status unavailable';
    return ListTile(
      dense: true,
      leading: Icon(review == false ? Icons.check_circle_outline : Icons.rate_review_outlined),
      title: Text(reviewLabel),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(typeSummary.isEmpty ? 'No fact type summary' : 'Fact types: $typeSummary'),
          if (decisionMap.isNotEmpty)
            Text(
              [
                if (decisionMap['topic'] != null) 'topic: ${decisionMap['topic']}',
                if (decisionMap['shouldConsider'] != null) 'shouldConsider: ${decisionMap['shouldConsider']}',
                if (decisionMap['confidence'] != null) 'confidence: ${decisionMap['confidence']}',
                if (decisionMap['rejectionReason'] != null) 'rejected: ${decisionMap['rejectionReason']}',
              ].join(' · '),
            ),
        ],
      ),
    );
  }
}

class _JobFailure extends StatelessWidget {
  final Map<String, dynamic> item;
  const _JobFailure({required this.item});

  @override
  Widget build(BuildContext context) {
    final status = item['status'];
    final reason = item['fail_reason'] ?? item['last_retry_reason'];
    final details = _stringList(item['failure_details']);
    if (status != 'failed' && reason == null) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      leading: const Icon(Icons.error_outline),
      title: Text(reason == null ? 'Failure reason unavailable' : 'Failure: $reason'),
      subtitle: details.isEmpty
          ? (item['next_attempt_at'] == null ? null : Text('Next attempt: ${item['next_attempt_at']}'))
          : Text(details.join(' · ')),
    );
  }
}

// ---------------------------------------------------------------------------
// Learning
// ---------------------------------------------------------------------------

class _LearningTab extends ConsumerWidget {
  const _LearningTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeader(
          title: 'Autonomous learning monitor',
          description:
              'The worker promotes rules only after baseline comparisons and staged safety gates. Pause a candidate here when an operational issue is found.',
        ),
        const _AutonomousLearningSection(),
        const SizedBox(height: 24),
        const _SectionHeader(
          title: 'Shared learning candidates',
          description:
              'Aggregated correction signals across users. Marking one for manual pattern authoring creates a work item only; it does not activate a parser pattern.',
        ),
        const _LearningCandidatesSection(),
      ],
    );
  }
}

class _AutonomousLearningSection extends ConsumerWidget {
  const _AutonomousLearningSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operations = ref.watch(smsLearningOperationsProvider);
    return operations.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => _ErrorBlock(label: 'Autonomous learning monitor failed', error: error),
      data: (data) {
        final candidates = (data['candidates'] as List?)
                ?.whereType<Map>()
                .map((item) => item.cast<String, dynamic>())
                .toList() ??
            const <Map<String, dynamic>>[];
        if (candidates.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No autonomous candidates have been proposed.'),
          );
        }
        return Column(
          children: [
            for (final candidate in candidates) _AutonomousCandidateCard(candidate: candidate),
          ],
        );
      },
    );
  }
}

class _AutonomousCandidateCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> candidate;
  const _AutonomousCandidateCard({required this.candidate});

  @override
  ConsumerState<_AutonomousCandidateCard> createState() => _AutonomousCandidateCardState();
}

class _AutonomousCandidateCardState extends ConsumerState<_AutonomousCandidateCard> {
  bool _busy = false;
  bool _showEvidence = false;

  Map<String, dynamic> get candidate => widget.candidate;

  @override
  Widget build(BuildContext context) {
    final id = candidate['candidate_id']?.toString();
    final state = candidate['state']?.toString() ?? 'unknown';
    final metrics = (candidate['stage_metrics'] as Map?)?.cast<String, dynamic>() ?? const {};
    final eval = (metrics['eval'] as Map?)?.cast<String, dynamic>();
    final summary = '${candidate['family'] ?? 'unknown'} · ${candidate['issuer'] ?? 'unknown issuer'}\n'
        'state $state · bundle ${candidate['bundle_version'] ?? '—'} · '
        'confidence ${candidate['confidence'] ?? '—'}\n'
        '${candidate['exposures'] ?? 0} exposures · ${candidate['comparisons'] ?? 0} comparisons · '
        '${candidate['distinct_users'] ?? 0} users · ${candidate['corrections'] ?? 0} corrections · '
        '${candidate['false_discards'] ?? 0} false discards';
    final extra = <String>[
      if (candidate['sender_pattern'] != null) 'sender ${candidate['sender_pattern']}',
      if (candidate['min_client_ver'] != null) 'min client ${candidate['min_client_ver']}',
      if (eval?['failureReason'] != null) 'last gate: ${eval!['failureReason']}',
      if (metrics['pause_reason'] != null) 'pause: ${metrics['pause_reason']}',
      if (metrics['rollback_reason'] != null) 'rollback: ${metrics['rollback_reason']}',
    ];
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(id ?? 'candidate'),
            subtitle: Text(extra.isEmpty ? summary : '$summary\n${extra.join(' · ')}'),
            isThreeLine: true,
            trailing: id == null
                ? null
                : Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => setState(() => _showEvidence = !_showEvidence),
                        child: Text(_showEvidence ? 'Hide evidence' : 'Evidence'),
                      ),
                      if (state != 'paused')
                        OutlinedButton(
                          onPressed: _busy ? null : () => _changeState(id, pause: true),
                          child: const Text('Pause'),
                        )
                      else
                        FilledButton.tonal(
                          onPressed: _busy ? null : () => _changeState(id, pause: false),
                          child: const Text('Resume shadow'),
                        ),
                    ],
                  ),
          ),
          if (_showEvidence)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(metrics),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _changeState(String id, {required bool pause}) async {
    final api = ref.read(adminApiProvider);
    if (api == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not signed in with an admin session.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      if (pause) {
        await api.pauseSmsLearningCandidate(id);
      } else {
        await api.resumeSmsLearningCandidate(id);
      }
      ref.invalidate(smsLearningOperationsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(pause ? 'Candidate paused.' : 'Candidate resumed in shadow.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update candidate: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _LearningCandidatesSection extends ConsumerWidget {
  const _LearningCandidatesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates = ref.watch(smsLearningCandidatesProvider);
    return candidates.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => _ErrorBlock(label: 'Learning candidates failed', error: error),
      data: (items) {
        if (items.isEmpty) {
          return const Text('No eligible candidates yet. Candidates require feedback from multiple users.');
        }
        return Column(
          key: const ValueKey('shared-learning-candidates'),
          children: [
            for (final item in items)
              Card(
                key: ValueKey('learning-${item['id']}'),
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
    if (api == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not signed in with an admin session.')),
      );
      return;
    }
    try {
      await api.decideSmsLearningCandidate(id, decision, reason: 'admin_console_decision');
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

// ---------------------------------------------------------------------------
// Rules & rollout
// ---------------------------------------------------------------------------

class _RulesTab extends ConsumerWidget {
  const _RulesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundles = ref.watch(smsRuleBundlesProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeader(
          title: 'Rule bundle history',
          description:
              'Bundles are immutable. Rolling back deactivates the selected version; the next newest active bundle becomes the one devices download.',
        ),
        bundles.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => _ErrorBlock(label: 'Bundle history failed', error: error),
          data: (items) {
            if (items.isEmpty) return const Text('No rule bundles have been published.');
            return _WideTable(
              child: DataTable(
                columnSpacing: 20,
                columns: const [
                  DataColumn(label: Text('Version')),
                  DataColumn(label: Text('Active')),
                  DataColumn(label: Text('Rules')),
                  DataColumn(label: Text('Min client')),
                  DataColumn(label: Text('Published')),
                  DataColumn(label: Text('SHA-256')),
                  DataColumn(label: Text('Actions')),
                ],
                rows: [
                  for (final item in items)
                    DataRow(
                      cells: [
                        DataCell(Text('v${item['bundle_version']}')),
                        DataCell(
                          Icon(
                            item['is_active'] == true ? Icons.check_circle : Icons.remove_circle_outline,
                            color: item['is_active'] == true ? Colors.green.shade700 : null,
                          ),
                        ),
                        DataCell(Text('${item['rule_count'] ?? 0}')),
                        DataCell(Text('${item['min_client_ver'] ?? '—'}')),
                        DataCell(Text('${item['published_at'] ?? '—'}')),
                        DataCell(Text(_shortHash(item['sha256']?.toString()))),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: () => _showRules(context, ref, item['bundle_version'] as int),
                                child: const Text('View rules'),
                              ),
                              if (item['is_active'] == true)
                                TextButton(
                                  onPressed: () => _rollback(context, ref, item['bundle_version'] as int),
                                  child: const Text('Roll back'),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _showRules(BuildContext context, WidgetRef ref, int version) async {
    final api = ref.read(adminApiProvider);
    if (api == null) return;
    try {
      final bundle = await api.fetchSmsRuleBundle(version);
      final rules = (bundle['rules'] as List?)?.whereType<Map>().toList() ?? const [];
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Bundle v$version · ${rules.length} rules'),
          content: SizedBox(
            width: 720,
            height: 480,
            child: rules.isEmpty
                ? const Text('This bundle has no rules.')
                : ListView(
                    children: [
                      for (final rule in rules)
                        ExpansionTile(
                          key: ValueKey('bundle-rule-${rule['id']}'),
                          title: Text('${rule['id'] ?? 'rule'} · ${rule['family'] ?? 'unknown family'}'),
                          subtitle: Text('confidence ${rule['confidence'] ?? '—'}'),
                          childrenPadding: const EdgeInsets.all(12),
                          children: [
                            SelectableText(
                              const JsonEncoder.withIndent('  ').convert(rule),
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                            ),
                          ],
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load bundle: $error')));
      }
    }
  }

  Future<void> _rollback(BuildContext context, WidgetRef ref, int version) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Roll back bundle v$version?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Devices will stop receiving this bundle. Candidates learned into it are marked rolled back.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(labelText: 'Reason (recorded in the audit log)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Roll back'),
          ),
        ],
      ),
    );
    final reason = reasonController.text.trim();
    reasonController.dispose();
    if (confirmed != true) return;
    final api = ref.read(adminApiProvider);
    if (api == null) return;
    try {
      final result = await api.rollbackSmsRuleBundle(version, reason: reason.isEmpty ? null : reason);
      ref.invalidate(smsRuleBundlesProvider);
      ref.invalidate(smsLearningOperationsProvider);
      ref.invalidate(smsAiSummaryProvider);
      if (context.mounted) {
        final active = (result['activeBundle'] as Map?)?['bundle_version'];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Bundle v$version deactivated. '
              '${result['rolledBackCandidates'] ?? 0} candidate(s) marked rolled back.'
              '${active == null ? ' No active bundle remains.' : ' Active bundle is now v$active.'}',
            ),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rollback failed: $error')));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Dry run
// ---------------------------------------------------------------------------

class _DryRunTab extends ConsumerStatefulWidget {
  const _DryRunTab();

  @override
  ConsumerState<_DryRunTab> createState() => _DryRunTabState();
}

class _DryRunTabState extends ConsumerState<_DryRunTab> {
  late final TextEditingController _controller = TextEditingController(text: _sample);
  Map<String, dynamic>? _report;
  String? _error;
  bool _running = false;

  static const _sample = '''[
  {
    "sourceKey": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "occurredAt": "2026-10-27T10:00:00Z",
    "parsed": {
      "amountInr": 250,
      "entryKind": "spend",
      "merchant": "Example Merchant",
      "last4": "1234"
    }
  }
]''';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeader(
          title: 'Compare legacy versus fact-based projection',
          description:
              'Runs entirely in the API process, writes nothing, and returns redacted deltas. Use it to preview a cohort before enabling the fact pipeline.',
        ),
        TextField(
          controller: _controller,
          minLines: 10,
          maxLines: 20,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Observations (JSON array)',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run dry run'),
            ),
            const SizedBox(width: 12),
            if (_running) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        if (_report != null) ...[
          const SizedBox(height: 20),
          _DryRunReport(report: _report!),
        ],
      ],
    );
  }

  Future<void> _run() async {
    final api = ref.read(adminApiProvider);
    if (api == null) {
      setState(() => _error = 'Not signed in with an admin session.');
      return;
    }
    List<Map<String, dynamic>> observations;
    try {
      final decoded = jsonDecode(_controller.text);
      if (decoded is! List) throw const FormatException('Top level must be a JSON array.');
      observations = decoded.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (error) {
      setState(() {
        _error = 'Invalid JSON: $error';
        _report = null;
      });
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final report = await api.runSmsAiDryRun(observations);
      if (mounted) setState(() => _report = report);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _report = null;
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}

class _DryRunReport extends StatelessWidget {
  final Map<String, dynamic> report;
  const _DryRunReport({required this.report});

  @override
  Widget build(BuildContext context) {
    final deltas = (report['deltas'] as List?)?.whereType<Map>().toList() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _Metric(label: 'Observations', value: '${report['totalObservations'] ?? 0}'),
                _Metric(label: 'Legacy spend ₹', value: '${report['totalLegacySpendInr'] ?? 0}'),
                _Metric(label: 'Fact spend ₹', value: '${report['totalNewSpendInr'] ?? 0}'),
                _Metric(label: 'Net difference ₹', value: '${report['netSpendDifferenceInr'] ?? 0}'),
                _Metric(label: 'Equal spend rows', value: '${report['equalSpendCount'] ?? 0}'),
                _Metric(label: 'Spend reductions', value: '${report['spendReductionCount'] ?? 0}'),
                _Metric(label: 'Non-spend facts', value: '${report['nonSpendFactsExtracted'] ?? 0}'),
                _Metric(label: 'Invalid fact sets', value: '${report['invalidFactSetsCount'] ?? 0}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (deltas.isNotEmpty)
          _WideTable(
            child: DataTable(
              columnSpacing: 20,
              columns: const [
                DataColumn(label: Text('Source key')),
                DataColumn(label: Text('Legacy ₹')),
                DataColumn(label: Text('Fact ₹')),
                DataColumn(label: Text('Difference ₹')),
                DataColumn(label: Text('Facts')),
                DataColumn(label: Text('Non-spend types')),
                DataColumn(label: Text('Valid')),
                DataColumn(label: Text('Errors')),
              ],
              rows: [
                for (final delta in deltas)
                  DataRow(
                    cells: [
                      DataCell(Text(_shortSource(delta['sourceKey']?.toString()))),
                      DataCell(Text('${delta['legacySpendInr'] ?? 0}')),
                      DataCell(Text('${delta['newSpendInr'] ?? 0}')),
                      DataCell(Text('${delta['spendDifferenceInr'] ?? 0}')),
                      DataCell(Text('${delta['factsProduced'] ?? 0}')),
                      DataCell(Text((delta['nonSpendTypes'] as List?)?.join(', ') ?? '—')),
                      DataCell(Text(delta['valid'] == true ? 'yes' : 'no')),
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: Text((delta['validationErrors'] as List?)?.join('; ') ?? '—'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets / helpers
// ---------------------------------------------------------------------------

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

class _WideTable extends StatelessWidget {
  final Widget child;
  const _WideTable({required this.child});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: child,
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  final String label;
  final Object error;
  const _ErrorBlock({required this.label, required this.error});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text('$label: $error', style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
      ),
    );
  }
}

List<String> _stringList(dynamic value) =>
    value is List ? value.whereType<String>().toList(growable: false) : const [];

String _compactJson(dynamic value) {
  if (value == null) return '—';
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}

String _shortHash(String? value) =>
    value == null || value.isEmpty ? '—' : (value.length <= 12 ? value : value.substring(0, 12));

String _shortSource(String? value) {
  if (value == null || value.isEmpty) return '—';
  return value.length <= 16 ? value : '${value.substring(0, 8)}…${value.substring(value.length - 8)}';
}
