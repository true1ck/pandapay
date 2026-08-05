import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-2.2: User-Reported Data Error queue — shown vs claimed side by side
/// against the current live value, source link. Approve writes through the
/// same typed reward-rule path AD-1 uses (see api/'s
/// POST /admin/error-reports/:id/approve), producing a card_catalogue_changes
/// row, a data_version bump, and an audit entry — verified end to end.
class ErrorReportsScreen extends ConsumerWidget {
  const ErrorReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(errorReportsProvider);

    return reports.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load error reports: $err')),
      data: (reportList) {
        if (reportList.isEmpty) {
          return const Center(child: Text('No open data error reports.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: reportList.length,
          itemBuilder: (context, index) => _ErrorReportTile(reportList[index]),
        );
      },
    );
  }
}

class _ErrorReportTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> report;
  const _ErrorReportTile(this.report);

  @override
  ConsumerState<_ErrorReportTile> createState() => _ErrorReportTileState();
}

class _ErrorReportTileState extends ConsumerState<_ErrorReportTile> {
  bool _busy = false;
  String? _error;

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      ref.invalidate(errorReportsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final isPending = r['state'] == 'pending';
    final isStale = r['is_stale'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text('${r['card_name']} — ${r['field_path']}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (isStale) ...[
                  const SizedBox(width: 8),
                  Chip(
                    label: Text('Stale · ${r['age_days']}d'),
                    backgroundColor: Colors.orange.shade100,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
            Text('state: ${r['state']}'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Shown (report time)', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text('${r['shown_value']}'),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward, size: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Claimed', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text('${r['claimed_value']}'),
                    ],
                  ),
                ),
              ],
            ),
            if (r['source_url'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${r['source_url']}', style: const TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 8),
            if (isPending)
              Row(
                children: [
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _act(() => ref.read(adminApiProvider)!.approveErrorReport(r['id'] as String)),
                    child: Text(_busy ? '...' : 'Approve'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _act(() => ref.read(adminApiProvider)!.rejectErrorReport(r['id'] as String)),
                    child: const Text('Reject'),
                  ),
                ],
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}
