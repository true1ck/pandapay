import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../main.dart' show MoneyText;

/// UA-8.2: Home-screen widget management panel.
/// Allows adding the widget to the home screen (on supported Android launchers)
/// and pushing manual recommendations to the native widget.
class WidgetSettingsScreen extends ConsumerStatefulWidget {
  const WidgetSettingsScreen({super.key});

  @override
  ConsumerState<WidgetSettingsScreen> createState() => _WidgetSettingsScreenState();
}

class _WidgetSettingsScreenState extends ConsumerState<WidgetSettingsScreen> {
  bool _refreshing = false;
  bool _pinning = false;
  bool? _isInstalled;
  bool _pinSupported = false;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    _checkWidgetStatus();
  }

  Future<void> _checkWidgetStatus() async {
    final service = ref.read(homeWidgetServiceProvider);
    final pinSupported = await service.isPinWidgetSupported();
    final installed = await service.isWidgetInstalled();
    if (mounted) {
      setState(() {
        _pinSupported = pinSupported;
        _isInstalled = installed;
      });
    }
  }

  Future<void> _refreshWidget() async {
    setState(() => _refreshing = true);
    try {
      final best = ref.read(bestOverallCardProvider);
      final rec = best.valueOrNull;
      final service = ref.read(homeWidgetServiceProvider);
      final clock = ref.read(clockProvider);
      await service.updateBestCardWidget(recommendation: rec, nowIso: clock.now().toIso8601String());
      final msg = rec == null
          ? 'Widget updated: no usable card right now.'
          : 'Widget updated: ${rec.card.name}.';
      setState(() => _lastResult = msg);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: BambooInk.slate,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      await _checkWidgetStatus();
    } catch (err) {
      final errMsg = 'Widget update failed: $err';
      setState(() => _lastResult = errMsg);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errMsg),
            backgroundColor: BambooInk.clay,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _pinWidget() async {
    setState(() => _pinning = true);
    try {
      final best = ref.read(bestOverallCardProvider);
      final rec = best.valueOrNull;
      final service = ref.read(homeWidgetServiceProvider);
      final clock = ref.read(clockProvider);

      // Save latest data first so widget has content as soon as pinned
      await service.updateBestCardWidget(recommendation: rec, nowIso: clock.now().toIso8601String());
      await service.pinBestCardWidget();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Follow your phone prompt to add the widget.'),
            backgroundColor: BambooInk.slate,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not pin widget: $err'),
            backgroundColor: BambooInk.clay,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pinning = false);
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
      body: AppBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Shows the single best card to use right now on your phone\'s '
                'home screen, without needing to open the app.',
                style: BambooFonts.ui(14, color: BambooInk.ink900),
              ),
              const SizedBox(height: 16),

              // Widget installation status badge
              if (_isInstalled != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _isInstalled!
                        ? BambooInk.jade.withValues(alpha: 0.1)
                        : BambooInk.ink500.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _isInstalled!
                          ? BambooInk.jade.withValues(alpha: 0.3)
                          : BambooInk.hairlineOnPaper,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isInstalled! ? Icons.check_circle : Icons.info_outline,
                        size: 18,
                        color: _isInstalled! ? BambooInk.jade : BambooInk.ink500,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _isInstalled!
                              ? 'Widget is active on your home screen'
                              : 'Widget not yet added to your home screen',
                          style: BambooFonts.ui(
                            12.5,
                            weight: FontWeight.w600,
                            color: _isInstalled! ? BambooInk.jade : BambooInk.ink900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Card preview
              Text(
                'CURRENT RECOMMENDATION FOR WIDGET',
                style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.ink500),
              ),
              const SizedBox(height: 6),
              best.when(
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (err, _) => Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: BambooInk.clay.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: BambooInk.clay.withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    'Could not compute a best card: $err',
                    style: BambooFonts.ui(13.5, color: BambooInk.clay),
                  ),
                ),
                data: (rec) => Container(
                  decoration: BoxDecoration(
                    color: BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: BambooInk.hairlineOnPaper),
                  ),
                  padding: const EdgeInsets.all(14),
                  child: rec == null
                      ? Text(
                          'No usable card yet — add one first.',
                          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                        )
                      : Row(
                          children: [
                            const Icon(Icons.credit_card, color: BambooInk.ink900),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    rec.card.name,
                                    style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                                  ),
                                  Text(
                                    'PandaPay Best Card',
                                    style: BambooFonts.ui(11, color: BambooInk.ink500),
                                  ),
                                ],
                              ),
                            ),
                            MoneyText(
                              rec.expectedValue,
                              confidence: rec.confidence,
                              style: BambooFonts.money(14, color: BambooInk.ink900),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 20),

              // Add to Home Screen button (if supported)
              if (_pinSupported) ...[
                FilledButton.icon(
                  icon: const Icon(Icons.add_to_home_screen),
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.jade,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                  ),
                  onPressed: _pinning ? null : _pinWidget,
                  label: Text(_pinning ? 'Adding…' : 'Add widget to home screen'),
                ),
                const SizedBox(height: 12),
              ],

              // Update home-screen widget now button
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                ),
                onPressed: _refreshing ? null : _refreshWidget,
                label: Text(_refreshing ? 'Updating…' : 'Update home-screen widget now'),
              ),
              if (_lastResult != null) ...[
                const SizedBox(height: 8),
                Text(_lastResult!, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
              ],

              const SizedBox(height: 24),
              // Step-by-step instructions card
              Container(
                decoration: BoxDecoration(
                  color: BambooInk.ink500.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'HOW TO ADD MANUALLY',
                      style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '1. Long-press any empty space on your home screen.\n'
                      '2. Tap "Widgets" in the menu that appears.\n'
                      '3. Scroll to "PandaPay".\n'
                      '4. Touch and hold the "Best Card" widget and drag it to your screen.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink900),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
