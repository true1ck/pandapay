import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';

/// Card Rewards Phase 1 (plan C8/D15d, D32d) — what the app does with the v2
/// engine's `exclusion_unparsed` assumption.
///
/// The engine adds it when an exclusion rule on the card could not be read
/// (a skipped rule that was `rule_role = 'exclusion'`): the estimate may pay
/// on spend the card actually excludes. Nothing in the app read it, so such a
/// card ranked as confidently as any other. It now
///
///  * never shows as more than an estimate ([confidenceOf]: one step down
///    from confirmed, which is the floor: the hourglass the app already uses
///    for an estimate), and
///  * says so in words ([RecommendationCaution]).
const String kExclusionUnparsedAssumption = 'exclusion_unparsed';

/// Whether [recommendation] was computed with an exclusion rule it could not
/// read.
bool hasUnparsedExclusion(Recommendation recommendation) =>
    recommendation.reward?.assumptions.contains(kExclusionUnparsedAssumption) ??
    false;

/// The confidence to SHOW for [recommendation]: lowered one step (confirmed
/// to estimated; the app has no level below estimated) when an exclusion could
/// not be read, so the app's estimate marker is shown, never a confirmed one.
Confidence confidenceOf(Recommendation recommendation) =>
    hasUnparsedExclusion(recommendation)
    ? Confidence.estimated
    : recommendation.confidence;

/// The words for the same thing: shown under a figure that may be too high.
const String kUnparsedExclusionCaution =
    'Some of this card\'s exclusions could not be read, so this may be '
    'higher than you\'ll actually earn.';

/// A one-line caution under a recommendation whose estimate may be too high
/// (an exclusion rule could not be read); nothing otherwise.
class RecommendationCaution extends StatelessWidget {
  final Recommendation recommendation;

  /// The text colour: the card's surface decides (paper vs slate).
  final Color color;

  const RecommendationCaution({
    super.key,
    required this.recommendation,
    this.color = BambooInk.ink500,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasUnparsedExclusion(recommendation)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.hourglass_top_rounded, size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              kUnparsedExclusionCaution,
              key: const ValueKey('unparsed-exclusion-caution'),
              style: BambooFonts.ui(11.5, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
