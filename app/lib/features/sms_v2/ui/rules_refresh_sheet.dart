import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/design/app_theme.dart';
import '../pipeline/rules_refresh.dart';
import '../providers/runtime_provider.dart';

/// "Refresh rules and re-sort": gets the newest shared rules now, reads
/// unrecognised messages again and puts rule-chosen spends in their right
/// category, then shows what happened. Returns the report (null if it could
/// not start) so the caller can reload its lists.
Future<RulesRefreshReport?> showRulesRefreshSheet(BuildContext context) =>
    showModalBottomSheet<RulesRefreshReport>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: BambooInk.paper,
      builder: (_) => const RulesRefreshSheet(),
    );

class RulesRefreshSheet extends ConsumerStatefulWidget {
  const RulesRefreshSheet({super.key});

  @override
  ConsumerState<RulesRefreshSheet> createState() => _RulesRefreshSheetState();
}

class _RulesRefreshSheetState extends ConsumerState<RulesRefreshSheet> {
  RulesRefreshReport? _report;
  String? _failure;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _report = null;
      _failure = null;
    });
    try {
      final runtime = await ref.read(smsV2RuntimeProvider.future);
      if (runtime == null) {
        if (mounted) {
          setState(() => _failure = 'Sign in to refresh your rules.');
        }
        return;
      }
      final report = await runtime.refreshRulesAndReanalyze();
      if (mounted) setState(() => _report = report);
    } catch (_) {
      if (mounted) {
        setState(
          () => _failure =
              'Something stopped the refresh. Your spends are unchanged. Try again.',
        );
      }
    }
  }

  /// The tap on Apply: moves the spends the preview listed, on this phone,
  /// then tells the account. Until then nothing has changed.
  Future<void> _apply() async {
    setState(() => _applying = true);
    try {
      final runtime = await ref.read(smsV2RuntimeProvider.future);
      if (runtime == null) {
        if (mounted) setState(() => _applying = false);
        return;
      }
      final applied = await runtime.applyResort();
      if (mounted) {
        setState(() {
          _report = applied;
          _applying = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _applying = false;
          _failure =
              'Something stopped the re-sort. Your spends are as they were. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final working = (report == null && _failure == null) || _applying;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            working
                ? (_applying ? 'Sorting your spends…' : 'Refreshing your rules…')
                : (report?.hasProblem ?? true)
                ? 'Refreshed, with a problem'
                : 'Refreshed',
            style: BambooFonts.heading(19, color: BambooInk.ink900),
          ),
          const SizedBox(height: 10),
          if (working) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _applying
                  ? 'Moving your spends to their new categories. This takes a moment.'
                  : 'Getting the newest rules, then checking your earlier spends. Nothing is changed until you say so.',
              style: BambooFonts.ui(13.5, color: BambooInk.ink700),
            ),
          ] else if (_failure != null)
            Text(_failure!, style: BambooFonts.ui(13.5, color: BambooInk.clay))
          else
            for (final line in report!.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  line,
                  style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                ),
              ),
          const SizedBox(height: 16),
          if (!working && (report?.canApply ?? false))
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(report),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _apply,
                    child: Text('Apply to ${report!.resortWouldMove}'),
                  ),
                ),
              ],
            )
          else if (!working)
            Row(
              children: [
                if (_failure != null || (report?.hasProblem ?? false))
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _run,
                      child: const Text('Try again'),
                    ),
                  ),
                if (_failure != null || (report?.hasProblem ?? false))
                  const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(report),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
