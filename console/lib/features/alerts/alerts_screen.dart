import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-4.2: the unified policy-change alert queue. Evidence and any
/// heuristic-extracted proposed fields (Chunk 14 — explicitly NOT AI, see
/// scraper/pandapay_scraper/extraction.py) are shown so the operator can
/// see *why* an alert exists, not just that it does. Deciding an alert
/// (approve/reject/needs more evidence) only ever changes the alert's own
/// state — it never writes card data. Applying a correction still goes
/// through the Catalogue tab's typed rate editor (Chunk 6), same as the
/// C7 error queue (Chunk 8): AI/heuristics extract, a human verifies.
class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider);

    return alerts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load alerts: $err')),
      data: (alertList) {
        if (alertList.isEmpty) {
          return const Center(child: Text('No policy-change alerts.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: alertList.length,
          itemBuilder: (context, index) => _AlertTile(alertList[index]),
        );
      },
    );
  }
}

class _AlertTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> alert;
  const _AlertTile(this.alert);

  @override
  ConsumerState<_AlertTile> createState() => _AlertTileState();
}

class _AlertTileState extends ConsumerState<_AlertTile> {
  Map<String, dynamic>? _detail;
  bool _loadingDetail = false;
  bool _busy = false;
  String? _error;

  Future<void> _loadDetail() async {
    if (_detail != null) return;
    setState(() => _loadingDetail = true);
    try {
      final detail = await ref.read(adminApiProvider)!.fetchAlertDetail(widget.alert['id'] as String);
      setState(() => _detail = detail);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loadingDetail = false);
    }
  }

  Future<void> _decide(String decision) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminApiProvider)!.decideAlert(widget.alert['id'] as String, decision);
      ref.invalidate(alertsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.alert;
    final isOpen = a['state'] == 'open';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        onExpansionChanged: (expanded) {
          if (expanded) _loadDetail();
        },
        title: Text('${a['card_name']} — ${a['field_label']}'),
        subtitle: Text(
          'state: ${a['state']} · signals: ${a['signal_count']} '
          '(${a['distinct_signal_kinds']} kinds) · corroboration: ${a['corroboration_score']}',
        ),
        children: [
          if (_loadingDetail) const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
          if (_detail != null) ..._buildDetail(_detail!),
          if (isOpen)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : () => _decide('approved'),
                    child: const Text('Approve'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _decide('rejected'),
                    child: const Text('Reject'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _decide('needs_more_evidence'),
                    child: const Text('Needs more evidence'),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildDetail(Map<String, dynamic> detail) {
    final evidence = (detail['evidence'] as List).cast<Map<String, dynamic>>();
    final proposals = (detail['proposals'] as List).cast<Map<String, dynamic>>();
    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Align(alignment: Alignment.centerLeft, child: Text('Evidence', style: TextStyle(fontWeight: FontWeight.bold))),
      ),
      for (final e in evidence)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('[${e['signal']}] ${e['excerpt']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
      if (proposals.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Proposed fields (heuristic regex, not AI — verify before applying)',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        for (final p in proposals)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${p['model_name']} (confidence ${p['model_confidence']}): ${p['proposed_fields']}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
      ],
    ];
  }
}
