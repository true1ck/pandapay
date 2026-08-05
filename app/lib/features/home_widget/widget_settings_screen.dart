import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../main.dart' show MoneyText;

/// UA-8.2: a manual "refresh the home-screen widget now" panel. There is no
/// background refresh scheduling wired up (no WorkManager/BGTaskScheduler
/// job) — genuinely out of scope for this pass alongside always-on
/// geofencing, see PROGRESS.md — so a real widget would only ever show
/// data as fresh as the last time this screen was opened. Shows the
/// same "top overall card" the widget itself would show, computed by the
/// exact same `bestOverallCardProvider`/`BestCardForWidget` pipeline, so
/// what's on screen here is provably what gets written to the widget.
class WidgetSettingsScreen extends ConsumerStatefulWidget {
  const WidgetSettingsScreen({super.key});

  @override
  ConsumerState<WidgetSettingsScreen> createState() => _WidgetSettingsScreenState();
}

class _WidgetSettingsScreenState extends ConsumerState<WidgetSettingsScreen> {
  bool _refreshing = false;
  String? _lastResult;

  Future<void> _refreshWidget() async {
    setState(() => _refreshing = true);
    try {
      final best = ref.read(bestOverallCardProvider);
      final rec = best.valueOrNull;
      final service = ref.read(homeWidgetServiceProvider);
      final clock = ref.read(clockProvider);
      await service.updateBestCardWidget(
        recommendation: rec,
        nowIso: clock.now().toIso8601String(),
      );
      setState(() => _lastResult = rec == null
          ? 'Widget updated: no usable card right now.'
          : 'Widget updated: ${rec.card.name}.');
    } catch (err) {
      setState(() => _lastResult = 'Widget update failed: $err');
    } finally {
      setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final best = ref.watch(bestOverallCardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Home-screen widget')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Shows the single best card to use right now on your phone\'s '
              'home screen, without opening the app. Native widget rendering '
              'was not verified on a real device in this build — this screen '
              'only proves the data that would be written to it.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            best.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Text('Could not compute a best card: $err'),
              data: (rec) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: rec == null
                      ? const Text('No usable card yet — add one first.')
                      : Row(
                          children: [
                            const Icon(Icons.credit_card),
                            const SizedBox(width: 8),
                            Expanded(child: Text(rec.card.name)),
                            MoneyText(rec.expectedValue, confidence: rec.confidence),
                          ],
                        ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _refreshing ? null : _refreshWidget,
              child: Text(_refreshing ? 'Updating…' : 'Update home-screen widget now'),
            ),
            if (_lastResult != null) ...[
              const SizedBox(height: 8),
              Text(_lastResult!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
