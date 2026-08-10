import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
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
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Home-screen widget', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Shows the single best card to use right now on your phone\'s '
                'home screen, without opening the app. Native widget rendering '
                'was not verified on a real device in this build — this screen '
                'only proves the data that would be written to it.',
                style: BambooFonts.ui(13, color: BambooInk.ink500),
              ),
              const SizedBox(height: 16),
              best.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Text('Could not compute a best card: $err', style: BambooFonts.ui(13.5, color: BambooInk.clay)),
                data: (rec) => Container(
                  decoration: BoxDecoration(
                    color: BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: BambooInk.hairlineOnPaper),
                  ),
                  padding: const EdgeInsets.all(14),
                  child: rec == null
                      ? Text('No usable card yet — add one first.', style: BambooFonts.ui(13.5, color: BambooInk.ink500))
                      : Row(
                          children: [
                            const Icon(Icons.credit_card, color: BambooInk.ink900),
                            const SizedBox(width: 8),
                            Expanded(child: Text(rec.card.name, style: BambooFonts.heading(14.5, color: BambooInk.ink900))),
                            MoneyText(rec.expectedValue, confidence: rec.confidence, style: BambooFonts.money(14, color: BambooInk.ink900)),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                ),
                onPressed: _refreshing ? null : _refreshWidget,
                child: Text(_refreshing ? 'Updating…' : 'Update home-screen widget now'),
              ),
              if (_lastResult != null) ...[
                const SizedBox(height: 8),
                Text(_lastResult!, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
