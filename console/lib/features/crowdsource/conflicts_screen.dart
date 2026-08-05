import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-6.3 conflict resolution queue + AD-6.4 abuse & quality controls, one
/// screen (both are small, both are "the cases the automatic rule doesn't
/// confidently handle" — same operator workflow shape as Card Requests/
/// Error Reports elsewhere in this console).
class ConflictsScreen extends StatelessWidget {
  const ConflictsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Merchant conflicts'), Tab(text: 'Abuse signals')]),
          const Expanded(
            child: TabBarView(children: [_ConflictsTab(), _AbuseSignalsTab()]),
          ),
        ],
      ),
    );
  }
}

class _ConflictsTab extends ConsumerWidget {
  const _ConflictsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(merchantConflictsProvider);
    return conflicts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load conflicts: $err')),
      data: (rows) {
        if (rows.isEmpty) return const Center(child: Text('No pending conflicts.'));
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: rows.length,
          itemBuilder: (context, i) => _ConflictTile(rows[i]),
        );
      },
    );
  }
}

class _ConflictTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> conflict;
  const _ConflictTile(this.conflict);

  @override
  ConsumerState<_ConflictTile> createState() => _ConflictTileState();
}

class _ConflictTileState extends ConsumerState<_ConflictTile> {
  bool _busy = false;
  String? _error;

  Future<void> _resolve(String value) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminApiProvider)!.resolveMerchantConflict(
            widget.conflict['id'] as String,
            value,
            reason: 'console resolve',
          );
      ref.invalidate(merchantConflictsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.conflict;
    // AD-6.3.2: competing values shown with counts and recency so an
    // operator can apply "majority wins, weighted toward recency" by eye —
    // this screen exists for exactly the cases that rule doesn't confidently
    // resolve on its own (there's no automated job computing that today).
    final values = (c['competing_values'] as List).cast<Map<String, dynamic>>();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${c['merchant_display_name'] ?? c['vpa']} — field: ${c['field']}',
                style: Theme.of(context).textTheme.titleMedium),
            Text(c['vpa'] as String, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final v in values)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _resolve(v['value'] as String),
                    child: Text('${v['value']} (${v['count']}×)'),
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

class _AbuseSignalsTab extends ConsumerWidget {
  const _AbuseSignalsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signals = ref.watch(abuseSignalsProvider);
    return signals.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load abuse signals: $err')),
      data: (rows) {
        if (rows.isEmpty) return const Center(child: Text('No open abuse signals.'));
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: rows.length,
          itemBuilder: (context, i) => _AbuseSignalTile(rows[i]),
        );
      },
    );
  }
}

class _AbuseSignalTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> signal;
  const _AbuseSignalTile(this.signal);

  @override
  ConsumerState<_AbuseSignalTile> createState() => _AbuseSignalTileState();
}

class _AbuseSignalTileState extends ConsumerState<_AbuseSignalTile> {
  bool _busy = false;
  String? _error;

  Future<void> _block() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminApiProvider)!.blockAbuseSignal(widget.signal['id'] as String, reason: 'console block');
      ref.invalidate(abuseSignalsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.signal;
    return ListTile(
      title: Text('${s['signal']} (severity ${s['severity']})'),
      subtitle: Text(
        'device ${s['device_hash']} · detected ${s['detected_at']}'
        '${_error != null ? '\n$_error' : ''}',
      ),
      isThreeLine: _error != null,
      trailing: FilledButton(
        onPressed: _busy ? null : _block,
        // AD-6.4.2: blocks every abuse_signals row for this device_hash and
        // bulk-reverts its merchant_contributions (marks is_counted=false) —
        // see api/'s POST /admin/abuse-signals/:id/block doc comment.
        child: Text(_busy ? '...' : 'Block device'),
      ),
    );
  }
}
