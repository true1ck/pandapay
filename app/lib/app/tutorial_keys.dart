import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// GlobalKeys shared between HomeScreen (which owns the amount field,
/// category chips, and first recommendation card) and the shell in
/// router.dart (which owns the scan FAB) so TutorialOverlay can locate all
/// four real, live widgets — not stand-ins — regardless of which file
/// mounts them. One instance per app run via Provider so both sides read
/// the same keys.
class TutorialKeys {
  final amountField = GlobalKey();
  final categoryChips = GlobalKey();
  final firstRecommendationCard = GlobalKey();
  final scanFab = GlobalKey();
}

final tutorialKeysProvider = Provider<TutorialKeys>((ref) => TutorialKeys());
