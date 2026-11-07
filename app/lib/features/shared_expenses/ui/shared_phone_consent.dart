import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';

/// The choice shown before a join request is sent, only when the server says
/// phone sharing is on. Neither option is preselected. Someone without a
/// verified phone gets a notice instead. Nothing here stores the number.
class SharedPhoneConsent extends StatelessWidget {
  final String? ownerName, ownMask;
  final bool? value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  const SharedPhoneConsent({
    super.key,
    required this.ownerName,
    required this.ownMask,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final owner = ownerName ?? 'The owner';
    final scheme = Theme.of(context).colorScheme;
    if (ownMask == null) {
      return Padding(
        key: const Key('phone-consent-notice'),
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          'Your account has no verified phone number, so $owner will see '
          'your name only.',
          style: BambooFonts.ui(13, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text:
                        '$owner will see your PandaPay name and your phone number (',
                  ),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Semantics(
                        label:
                            'ending ${ownMask!.substring(ownMask!.length - 4)}',
                        excludeSemantics: true,
                        child: Text(
                          ownMask!.replaceAll(' ', ' '),
                          style: BambooFonts.ui(14, weight: FontWeight.w700)
                              .copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                      ),
                    ),
                  ),
                  const TextSpan(
                    text:
                        ') to confirm it is you. They can’t see it after they decide.',
                  ),
                ],
              ),
              style: BambooFonts.ui(14, color: scheme.onSurface),
            ),
          ),
          const SizedBox(height: 12),
          _Option(
            key: const Key('consent-share'),
            label: 'Share my number',
            selected: value == true,
            enabled: enabled,
            onTap: () => onChanged(true),
          ),
          const SizedBox(height: 8),
          _Option(
            key: const Key('consent-decline'),
            label: 'Ask without sharing',
            hint: 'They will see your name only and may not approve.',
            selected: value == false,
            enabled: enabled,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  final String label;
  final String? hint;
  final bool selected, enabled;
  final VoidCallback onTap;
  const _Option({
    super.key,
    required this.label,
    this.hint,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      button: true,
      label: label,
      hint: hint,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: BambooFonts.ui(14, weight: FontWeight.w600),
                    ),
                    if (hint != null)
                      Text(
                        hint!,
                        style: BambooFonts.ui(
                          12,
                          color: scheme.onSurfaceVariant,
                        ),
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
