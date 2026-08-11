import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../main.dart' show MoneyText;
import 'appearance_providers.dart';

/// Task H6 (ui-spec.md Settings > Appearance). Reached via
/// `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const
/// AppearanceScreen()))` from Settings Hub (H1), same pushed-screen pattern
/// tools_hub_screen.dart's own tiles use — not a registered go_router route.
///
/// Text size is now applied app-wide from `main.dart`'s `PandaPayApp`, not
/// previewed locally here. The local `MediaQuery` override this screen used
/// to wrap its own body in has been removed along with that change — kept
/// alongside a root-level override it would have double-applied the scale,
/// so this screen alone would have rendered at 130% of 130%.
///
/// The theme control is gone for the same class of reason: it no longer did
/// anything. Every Bamboo Ink screen paints from fixed light constants, so
/// `ThemeMode` changed nothing a user could see — see `PandaPayApp`'s
/// doc-comment for the full reasoning and for where the pinning actually
/// happens. What replaces the control is a plain statement of the current
/// state, rather than a silently missing section that would read as a bug
/// to anyone who remembered the toggle being there.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            _SectionHeader('Theme'),
            const SizedBox(height: AppSpace.sm),
            const _ThemeStatusCard(),
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
              "Applies everywhere in the app. Stacks on top of your device's own "
              'accessibility text size setting, if you have one, up to 200% in total.',
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
    );
  }
}

/// What the Theme section became once `ThemeMode` stopped changing
/// anything a user could see. States the current behaviour plainly and
/// says dark is coming, rather than leaving a control that does nothing or
/// a gap where one used to be.
class _ThemeStatusCard extends StatelessWidget {
  const _ThemeStatusCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Row(
        children: [
          const Icon(Icons.light_mode_outlined, color: BambooInk.ink500),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Light', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                const SizedBox(height: 2),
                Text(
                  'PandaPay is light-only for now. A dark theme is coming — until it '
                  'lands, a switch here would not have changed anything on screen.',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
        ],
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
      style: BambooFonts.ui(
        12,
        weight: FontWeight.w700,
        color: BambooInk.ink500,
      ).copyWith(letterSpacing: 1.1),
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

  const _SegmentButton({
    required this.selected,
    required this.label,
    required this.icon,
    required this.onTap,
  });

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
              if (icon != null) Icon(icon, size: 18, color: selected ? BambooInk.lime : BambooInk.ink500),
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
