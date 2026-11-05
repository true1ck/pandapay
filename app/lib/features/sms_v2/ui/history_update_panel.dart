import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart' as app;
import '../migration/history_update.dart';
import '../providers/runtime_provider.dart';
import 'screen_parts.dart';

class HistoryUpdatePanel extends ConsumerStatefulWidget {
  const HistoryUpdatePanel({super.key, required this.onApplied});
  final VoidCallback onApplied;

  @override
  ConsumerState<HistoryUpdatePanel> createState() => _HistoryUpdatePanelState();
}

class _HistoryUpdatePanelState extends ConsumerState<HistoryUpdatePanel> {
  DateTimeRange? _period;
  HistoryUpdate? _request;
  HistoryUpdateReport? _preview;
  bool _busy = false, _applying = false, _pause = false, _applied = false;
  String? _status;

  Future<void> _choosePeriod() async {
    final chosen = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      initialDateRange: _period,
    );
    if (!mounted || chosen == null) return;
    setState(() {
      _period = chosen;
      _preview = null;
      _request = null;
      _applied = false;
      _status = null;
    });
  }

  Future<void> _run({required bool apply}) async {
    final namespace = ref.read(app.cacheNamespaceProvider);
    setState(() {
      _busy = true;
      _applying = apply;
      _pause = false;
      if (!apply) {
        _preview = null;
        _request = null;
      }
      _status = apply ? 'Checking saved history…' : 'Preparing a preview…';
    });
    bool current() =>
        mounted && namespace == ref.read(app.cacheNamespaceProvider);
    try {
      if (!apply) {
        final runtime = await ref.read(smsV2RuntimeProvider.future);
        if (runtime == null) throw StateError('No active SMS account');
        final now = DateTime.now();
        final end = _period?.end ?? now;
        _request = await runtime.historyUpdate(
          _period?.start ?? DateTime(2000),
          DateTime(end.year, end.month, end.day + 1),
        );
        final result = await _request!.preview();
        if (current()) {
          setState(() {
            _preview = result;
            _applied = false;
            _status = 'Preview ready. Review the changes before applying.';
          });
        }
      } else {
        final result = await _request!.apply(
          shouldContinue: () => mounted && !_pause,
          onProgress: (progress) {
            if (current()) {
              setState(
                () => _status =
                    '${progress.processed} of ${progress.total} readings checked',
              );
            }
          },
        );
        if (current()) {
          setState(() {
            _applied = result.categories.complete;
            _status = _applied
                ? 'History check complete. Changes will sync normally.'
                : 'Paused. Apply again to resume the saved check.';
          });
        }
        if (current()) widget.onApplied();
      }
    } on HistoryUpdatePaused {
      if (current()) {
        setState(
          () => _status = 'Paused. Apply again to resume the saved check.',
        );
      }
    } catch (_) {
      if (current()) {
        setState(
          () => _status =
              'The check stopped. Committed progress is saved. Preview again to continue.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmApply() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply this history check?'),
        content: const Text(
          'Older SMS with saved text will be checked. Automatic categories can change. Your category choices, manual entries and corrections are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) await _run(apply: true);
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Check saved history',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text(
            'Testing control. Check previously unprocessed messages and refresh automatic categories for a chosen period.',
          ),
          Text(
            _period == null
                ? 'All retained history'
                : '${MaterialLocalizations.of(context).formatMediumDate(_period!.start)} – ${MaterialLocalizations.of(context).formatMediumDate(_period!.end)}',
          ),
          TextButton(
            onPressed: _busy ? null : _choosePeriod,
            child: const Text('Choose dates'),
          ),
          if (_preview case final preview?) ...[
            Text('${preview.categories.changed} automatic categories change'),
            Text('${preview.categories.preservedUser} user categories kept'),
            if (preview.categories.awaitingSync > 0)
              Text(
                '${preview.categories.awaitingSync} readings await sync. Preview again after sync to refresh their categories.',
              ),
            Text(
              '${preview.migration.legacyWithoutBody} old entries have no saved SMS text',
            ),
            Text(
              '${preview.migration.data['uncheckedMessages']} messages need review',
            ),
            ExpansionTile(
              title: const Text('Preview account monthly totals'),
              children: [
                for (final month in {
                  ...(preview.migration.data['beforeByMonth'] as Map).keys,
                  ...(preview.migration.data['afterByMonth'] as Map).keys,
                }.cast<String>().toList()..sort())
                  ListTile(
                    title: Text(month),
                    subtitle: Text(
                      [
                        for (final (key, label) in [
                          ('spendMinor', 'Spending'),
                          ('incomeMinor', 'Money in'),
                          ('investmentMinor', 'Investments'),
                        ])
                          '$label ${smsMoney(((preview.migration.data['beforeByMonth'] as Map)[month] as Map?)?[key] as int? ?? 0)} → ${smsMoney(((preview.migration.data['afterByMonth'] as Map)[month] as Map?)?[key] as int? ?? 0)}',
                      ].join('\n'),
                    ),
                  ),
              ],
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_status != null) Text(_status!),
          OutlinedButton(
            onPressed: _busy ? null : () => _run(apply: false),
            child: const Text('Preview history check'),
          ),
          if (_preview != null)
            FilledButton(
              onPressed: _busy || _applied ? null : _confirmApply,
              child: const Text('Apply history check'),
            ),
          if (_busy && _applying)
            TextButton(
              onPressed: () => setState(() => _pause = true),
              child: const Text('Pause after current batch'),
            ),
        ],
      ),
    ),
  );
}
