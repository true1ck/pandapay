import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';

/// Card Rewards Phase 1 (WP9) — how faithfully the catalogue models a card's
/// earning, on card detail. A **Partial** or **Basic** card gets a small
/// label; tapping it opens a one-line explanation. **Verified** cards (and a
/// card from the v1 feed, which carries no status) get nothing: a warning
/// label is for what is estimated, not for what is checked.
class ModelStatusLabel extends StatelessWidget {
  final ModelStatus? status;
  const ModelStatusLabel({super.key, required this.status});

  /// The one line the sheet shows.
  static String explanation(ModelStatus status) => switch (status) {
    ModelStatus.partial => 'Some earning rules for this card are estimated.',
    ModelStatus.basic =>
      'Only this card\'s base earning rate is modelled; any bonus rewards '
          'are not included.',
    ModelStatus.verified => 'This card\'s earning rules have been checked.',
  };

  static String? labelFor(ModelStatus? status) => switch (status) {
    ModelStatus.partial => 'Partial',
    ModelStatus.basic => 'Basic',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final current = status;
    final label = labelFor(current);
    if (current == null || label == null) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: '$label model. ${explanation(current)}',
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('model-status-label'),
        behavior: HitTestBehavior.opaque,
        onTap: () => showModelStatusSheet(context, current),
        child: StatusPill(
          label: label.toUpperCase(),
          foreground: BambooInk.clayInk,
          background: BambooInk.warningBg,
          icon: Icons.info_outline_rounded,
        ),
      ),
    );
  }
}

/// The explanation sheet for [status].
Future<void> showModelStatusSheet(BuildContext context, ModelStatus status) {
  final label = ModelStatusLabel.labelFor(status) ?? 'Verified';
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: BambooInk.paper,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          0,
          AppSpace.lg,
          AppSpace.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label earning rules',
              style: BambooFonts.heading(17, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              ModelStatusLabel.explanation(status),
              key: const ValueKey('model-status-explanation'),
              style: BambooFonts.ui(14, color: BambooInk.ink700),
            ),
          ],
        ),
      ),
    ),
  );
}
