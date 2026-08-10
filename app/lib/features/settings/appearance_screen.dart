import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../main.dart' show MoneyText;
import 'appearance_providers.dart';

/// Task H6 (ui-spec.md Settings > Appearance). Reached via
/// `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const
/// AppearanceScreen()))` from Settings Hub (H1), same pushed-screen pattern
/// tools_hub_screen.dart's own tiles use — not a registered go_router route.
///
/// Text-size root-level wiring: this screen demonstrates the effect on its
/// own body via a local `MediaQuery` override (see build() below), which is
/// enough to prove the preference round-trips through SharedPreferences.
/// Applying it at the whole-app root (wrapping `MaterialApp.router` in
/// main.dart's `PandaPayApp` with a `Builder` that overrides
/// `MediaQuery.textScalerOf`) is real app-wide behavior and is intentionally
/// left as a follow-up rather than done here: main.dart is already being
/// touched by this task for the theme-mode wiring (see its own doc-comment),
/// and stacking a second unrelated MediaQuery override in the same pass
/// risks fighting the OS-level accessibility text scale in ways that need
/// their own dedicated verification pass (per H6's own DoD note about the
/// 200% ceiling), not a drive-by addition here.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final textScale = ref.watch(textScaleProvider);
    final numberFormat = ref.watch(numberFormatProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Appearance', style: BambooFonts.heading(18, color: BambooInk.ink900)),
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
        child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            _SectionHeader('Theme'),
            const SizedBox(height: AppSpace.sm),
            _SegmentedCard<ThemeMode>(
              value: themeMode,
              options: const [
                (ThemeMode.light, 'Light', Icons.light_mode_outlined),
                (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
                (ThemeMode.system, 'System', Icons.brightness_auto_outlined),
              ],
              onChanged: (mode) => ref.read(themeModeProvider.notifier).setThemeMode(mode),
            ),
            const SizedBox(height: AppSpace.xl),
            _SectionHeader('Text size'),
            const SizedBox(height: AppSpace.sm),
            _SegmentedCard<double>(
              value: textScale,
              options: const [
                (0.85, '85%', null),
                (1.0, '100%', null),
                (1.15, '115%', null),
                (1.3, '130%', null),
              ],
              onChanged: (scale) => ref.read(textScaleProvider.notifier).setTextScale(scale),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Applies within this screen as a preview. Stacks on top of your device\'s own '
              'accessibility text size setting, if you have one.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.xl),
            _SectionHeader('Card art style'),
            const SizedBox(height: AppSpace.sm),
            Container(
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Opacity(
                opacity: 0.5,
                child: Row(
                  children: [
                    const Icon(Icons.style_outlined, color: BambooInk.ink500),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Default', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                          const SizedBox(height: 2),
                          Text(
                            'More styles coming soon — this catalogue doesn\'t have alternate '
                            'card art assets yet.',
                            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            _SectionHeader('Number format'),
            const SizedBox(height: AppSpace.sm),
            _SegmentedCard<MoneyNumberFormat>(
              value: numberFormat,
              options: const [
                (MoneyNumberFormat.lakhCrore, 'Lakh/Crore', null),
                (MoneyNumberFormat.international, 'International', null),
              ],
              onChanged: (format) => ref.read(numberFormatProvider.notifier).setNumberFormat(format),
            ),
            const SizedBox(height: AppSpace.md),
            Container(
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Row(
                children: [
                  Text('Preview', style: BambooFonts.ui(13.5, color: BambooInk.ink500)),
                  const SizedBox(width: AppSpace.md),
                  MoneyText(
                    Money.fromRupees(1234567),
                    confidence: Confidence.confirmed,
                    style: BambooFonts.money(16, color: BambooInk.ink900),
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

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.ink500).copyWith(letterSpacing: 1.1),
    );
  }
}

/// A row of selectable segments backed by a single value — used for all
/// three real toggles on this screen (theme / text size / number format) so
/// they share one visual language.
class _SegmentedCard<T> extends StatelessWidget {
  final T value;
  final List<(T, String, IconData?)> options;
  final ValueChanged<T> onChanged;

  const _SegmentedCard({required this.value, required this.options, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.xs),
      child: Row(
        children: [
          for (final option in options)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: _SegmentButton<T>(
                  selected: option.$1 == value,
                  label: option.$2,
                  icon: option.$3,
                  onTap: () => onChanged(option.$1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegmentButton<T> extends StatelessWidget {
  final bool selected;
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  const _SegmentButton({required this.selected, required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? BambooInk.slate : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.md, horizontal: AppSpace.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(icon, size: 18, color: selected ? BambooInk.lime : BambooInk.ink500),
              if (icon != null) const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: BambooFonts.ui(
                  12.5,
                  weight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? BambooInk.onSlate : BambooInk.ink900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
