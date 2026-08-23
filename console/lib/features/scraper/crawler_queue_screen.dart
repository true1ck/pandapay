import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Admin visibility for the card crawler pipeline.
///
/// Two tabs:
///   Jobs   — card_crawl_jobs rows: type, state, attempts, last_error
///   Drafts — card_source_drafts rows: card, issuer, status, confidence
///
/// Both tabs are read-only; no mutation is offered here — promotion is an
/// automated pipeline step handled server-side.
class CrawlerQueueScreen extends ConsumerStatefulWidget {
  const CrawlerQueueScreen({super.key});

  @override
  ConsumerState<CrawlerQueueScreen> createState() => _CrawlerQueueScreenState();
}

class _CrawlerQueueScreenState extends ConsumerState<CrawlerQueueScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Jobs'),
            Tab(text: 'Drafts'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: const [
              _JobsTab(),
              _DraftsTab(),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Jobs Tab ──────────────────────────────────────────────────────────────────

class _JobsTab extends ConsumerWidget {
  const _JobsTab();

  static const _stateColors = {
    'queued': Colors.blue,
    'running': Colors.orange,
    'succeeded': Colors.green,
    'failed': Colors.red,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(crawlerJobsProvider);
    return jobs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load jobs: $err')),
      data: (list) {
        if (list.isEmpty) {
          return const Center(child: Text('No crawler jobs found.'));
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(crawlerJobsProvider),
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final job = list[i];
              final state = job['state'] as String? ?? 'unknown';
              final color = _stateColors[state] ?? Colors.grey;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: color.withOpacity(0.15),
                  child: Icon(
                    _iconFor(state),
                    color: color,
                    size: 18,
                  ),
                ),
                title: Text(
                  '${job['job_type'] ?? '?'} · ${_truncId(job['id'])}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'target: ${job['card_target_id'] ?? '—'}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    if (job['last_error'] != null)
                      Text(
                        'error: ${job['last_error']}',
                        style: const TextStyle(fontSize: 11, color: Colors.red),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Chip(
                      label: Text(state, style: const TextStyle(fontSize: 11)),
                      backgroundColor: color.withOpacity(0.15),
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    if (job['attempts'] != null)
                      Text('attempts: ${job['attempts']}', style: const TextStyle(fontSize: 11)),
                  ],
                ),
                isThreeLine: job['last_error'] != null,
              );
            },
          ),
        );
      },
    );
  }

  IconData _iconFor(String state) => switch (state) {
        'queued' => Icons.schedule,
        'running' => Icons.sync,
        'succeeded' => Icons.check_circle_outline,
        'failed' => Icons.error_outline,
        _ => Icons.help_outline,
      };

  String _truncId(dynamic id) {
    final s = id?.toString() ?? '';
    return s.length > 8 ? s.substring(0, 8) : s;
  }
}

// ── Drafts Tab ────────────────────────────────────────────────────────────────

class _DraftsTab extends ConsumerWidget {
  const _DraftsTab();

  static const _statusColors = {
    'draft': Colors.orange,
    'ready': Colors.blue,
    'promoted': Colors.green,
    'rejected': Colors.red,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drafts = ref.watch(crawlerDraftsProvider);
    return drafts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load drafts: $err')),
      data: (list) {
        if (list.isEmpty) {
          return const Center(child: Text('No pending drafts.'));
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(crawlerDraftsProvider),
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final draft = list[i];
              final status = draft['status'] as String? ?? 'draft';
              final color = _statusColors[status] ?? Colors.grey;
              final confidence = switch (draft['confidence']) {
                final num n => n,
                final String s => num.tryParse(s),
                _ => null,
              };
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: color.withOpacity(0.15),
                  child: Icon(Icons.description_outlined, color: color, size: 18),
                ),
                title: Text(
                  draft['card_name'] as String? ?? '—',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  draft['issuer_name'] as String? ?? '—',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Chip(
                      label: Text(status, style: const TextStyle(fontSize: 11)),
                      backgroundColor: color.withOpacity(0.15),
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    if (confidence != null)
                      Text(
                        'conf: ${confidence.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 11),
                      ),
                  ],
                ),
                onTap: () => _showDraftDetail(context, draft),
              );
            },
          ),
        );
      },
    );
  }

  void _showDraftDetail(BuildContext context, Map<String, dynamic> draft) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(draft['card_name'] as String? ?? 'Draft detail'),
        content: SingleChildScrollView(
          child: SelectableText(
            _formatDraftSummary(draft),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatDraftSummary(Map<String, dynamic> d) {
    final buf = StringBuffer();
    for (final key in ['id', 'card_name', 'issuer_name', 'status', 'confidence', 'created_at']) {
      if (d[key] != null) buf.writeln('$key: ${d[key]}');
    }
    return buf.toString().trim();
  }
}
