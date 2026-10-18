import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared anchors for the real controls shown by the five-step app tour.
/// Preview-only anchors are passed to Quick add and Spending by the shell.
class TutorialKeys {
  final amountField = GlobalKey();
  final categoryChips = GlobalKey();
  final firstRecommendationCard = GlobalKey();
  final scanFab = GlobalKey();
  final voiceFab = GlobalKey();
  final manualAmount = GlobalKey();
  final spendingPeriod = GlobalKey();
  final spendingSummary = GlobalKey();
}

final tutorialKeysProvider = Provider<TutorialKeys>((ref) => TutorialKeys());
