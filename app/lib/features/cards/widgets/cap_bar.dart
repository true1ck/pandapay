import 'package:flutter/material.dart';

import '../../../app/design/app_theme.dart';
import '../cap_progress.dart';

/// Card Rewards Phase 1 (B1) — one cap as a bar plus its native-unit line:
///
///     Dining bonus
///     ▓▓▓▓▓▓▓▓▓▓░░░░
///     1,240 / 1,500 pts · resets 1 Dec · then 1 pt/₹100
///
/// An unknown cap (no native figure yet) is an empty bar and "Updating…":
/// never a number it cannot stand behind.
class CapBar extends StatelessWidget {
  final CapProgress progress;

  /// The cap's label above the bar; null for a bar inside a card that
  /// already names the cap.
  final String? title;

  const CapBar({super.key, required this.progress, this.title});

  /// Jade while there is room, amber from the 80% alert line, clay from 90%.
  static Color colorFor(double? ratio) {
    if (ratio == null) return BambooInk.ink300;
    if (ratio >= 0.9) return BambooInk.clay;
    if (ratio >= 0.8) return BambooInk.amber;
    return BambooInk.jade;
  }

  @override
  Widget build(BuildContext context) {
    final ratio = progress.ratio;
    final color = colorFor(ratio);
    final label = title;
    final summary = progress.summary;
    return Semantics(
      container: true,
      label: [?label, summary].join(': '),
      excludeSemantics: true,
      child: Column(
        key: ValueKey('cap-bar-${progress.cap.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: 5),
          ],
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              // An unknown cap is an empty track, not an indeterminate
              // spinner: nothing here is "loading" until the server's
              // recompute lands.
              value: ratio ?? 0,
              minHeight: 7,
              backgroundColor: BambooInk.paperMuted,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            summary,
            key: ValueKey('cap-bar-summary-${progress.cap.id}'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: BambooFonts.ui(
              11.5,
              weight: ratio != null && ratio >= 0.8
                  ? FontWeight.w600
                  : FontWeight.w400,
              color: ratio != null && ratio >= 0.8 ? color : BambooInk.ink500,
            ),
          ),
        ],
      ),
    );
  }
}
