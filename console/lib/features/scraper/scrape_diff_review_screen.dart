import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-4.1/AD-4.2 change-detection + diff review — previously only
/// reachable indirectly, through GET /admin/alerts/:id's evidence+
/// proposals once an alert already existed. This screen is the missing
/// front door: browse recent scrape runs across every source, then drill
/// into a specific source's pages and see a page's last few snapshots
/// side by side to actually eyeball what changed. Deliberately not a
/// computed line-diff (see GET /admin/source-pages/:id/snapshots' doc
/// comment, api/src/index.js) — verbatim extracted text, same trust model
/// as the "evidence excerpt" shown everywhere else in this admin flow.
class ScrapeDiffReviewScreen extends ConsumerWidget {
  const ScrapeDiffReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(scrapeRunsProvider);

    return runs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load scrape runs: $err')),
      data: (runList) {
        if (runList.isEmpty) {
          return const Center(child: Text('No scrape runs yet.'));
        }
        // One entry per distinct source, newest run first — the operator
        // picks a source to drill into its pages/snapshots, not a run
        // (page_snapshots aren't 1:1 with a run once retries happen).
        final bySource = <String, Map<String, dynamic>>{};
        for (final run in runList) {
          bySource.putIfAbsent(run['source_id'] as String, () => run);
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Recent runs', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final run in runList.take(20)) _RunTile(run),
            const SizedBox(height: 24),
            Text('Browse a source\'s pages', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final entry in bySource.entries)
              ListTile(
                title: Text(entry.value['source_name'] as String? ?? entry.key),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => _SourcePagesScreen(
                    sourceId: entry.key,
                    sourceName: entry.value['source_name'] as String? ?? entry.key,
                  ),
                )),
              ),
          ],
        );
      },
    );
  }
}

class _RunTile extends StatelessWidget {
  final Map<String, dynamic> run;
  const _RunTile(this.run);

  @override
  Widget build(BuildContext context) {
    final status = run['status'] as String? ?? 'unknown';
    final color = switch (status) {
      'success' => Colors.green,
      'failed' => Colors.red,
      'running' => Colors.blue,
      _ => Colors.grey,
    };
    return ListTile(
      dense: true,
      leading: Icon(Icons.circle, size: 10, color: color),
      title: Text('${run['source_name']} — $status'),
      subtitle: Text('${run['pages_fetched'] ?? 0} fetched · ${run['pages_changed'] ?? 0} changed'
          '${run['error_text'] != null ? ' · ${run['error_text']}' : ''}'),
      trailing: Text(run['started_at'] as String? ?? '', style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

class _SourcePagesScreen extends ConsumerWidget {
  final String sourceId;
  final String sourceName;
  const _SourcePagesScreen({required this.sourceId, required this.sourceName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(adminApiProvider);
    return Scaffold(
      appBar: AppBar(title: Text(sourceName)),
      body: api == null
          ? const SizedBox.shrink()
          : FutureBuilder<List<Map<String, dynamic>>>(
              future: api.fetchSourcePages(sourceId),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                if (snapshot.hasError) return Center(child: Text('Failed to load pages: ${snapshot.error}'));
                final pages = snapshot.data!;
                if (pages.isEmpty) return const Center(child: Text('No pages registered for this source.'));
                return ListView.builder(
                  itemCount: pages.length,
                  itemBuilder: (context, index) {
                    final page = pages[index];
                    return ListTile(
                      title: Text(page['page_role'] as String? ?? ''),
                      subtitle: Text(page['url'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _SnapshotDiffScreen(sourcePageId: page['id'] as String, pageRole: page['page_role'] as String? ?? ''),
                      )),
                    );
                  },
                );
              },
            ),
    );
  }
}

class _SnapshotDiffScreen extends ConsumerWidget {
  final String sourcePageId;
  final String pageRole;
  const _SnapshotDiffScreen({required this.sourcePageId, required this.pageRole});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(adminApiProvider);
    return Scaffold(
      appBar: AppBar(title: Text(pageRole)),
      body: api == null
          ? const SizedBox.shrink()
          : FutureBuilder<List<Map<String, dynamic>>>(
              future: api.fetchSourcePageSnapshots(sourcePageId),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                if (snapshot.hasError) return Center(child: Text('Failed to load snapshots: ${snapshot.error}'));
                final snapshots = snapshot.data!;
                if (snapshots.isEmpty) {
                  return const Center(child: Text('No snapshots captured for this page yet.'));
                }
                if (snapshots.length == 1) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Only one snapshot exists — nothing to diff against yet.'),
                        const SizedBox(height: 12),
                        Expanded(child: SingleChildScrollView(child: Text(snapshots.first['extracted_text'] as String? ?? ''))),
                      ],
                    ),
                  );
                }
                final newest = snapshots[0];
                final previous = snapshots[1];
                final changed = newest['content_hash'] != previous['content_hash'];
                return Column(
                  children: [
                    Container(
                      width: double.infinity,
                      color: changed ? Colors.orange.shade100 : Colors.green.shade100,
                      padding: const EdgeInsets.all(8),
                      child: Text(changed
                          ? 'Content changed between these two snapshots'
                          : 'No content change between these two snapshots'),
                    ),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _SnapshotColumn(title: 'Previous — ${previous['captured_at']}', text: previous['extracted_text'] as String? ?? '')),
                          const VerticalDivider(width: 1),
                          Expanded(child: _SnapshotColumn(title: 'Newest — ${newest['captured_at']}', text: newest['extracted_text'] as String? ?? '')),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _SnapshotColumn extends StatelessWidget {
  final String title;
  final String text;
  const _SnapshotColumn({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Expanded(child: SingleChildScrollView(child: SelectableText(text))),
        ],
      ),
    );
  }
}
