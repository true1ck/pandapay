import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

/// Presentation rules for tracked credit-card utilization.
///
/// These are guidance bands, not a credit-score calculator. The 30% line is
/// shown because it is a commonly used guideline; PandaPay cannot predict or
/// guarantee a bureau score.
abstract final class CreditUtilizationUi {
  static const yellow = Color(0xFFB59B00);

  static Color color(double ratio) {
    if (ratio > 0.75) {
      return BambooInk.clay;
    }
    if (ratio > 0.50) {
      return BambooInk.amber;
    }
    if (ratio > 0.30) {
      return yellow;
    }
    return BambooInk.jade;
  }

  static String label(double ratio) {
    if (ratio > 1) {
      return 'Over the limit';
    }
    if (ratio > 0.75) {
      return 'Very high utilization';
    }
    if (ratio > 0.50) {
      return 'High utilization';
    }
    if (ratio > 0.30) {
      return 'Watch utilization';
    }
    return 'Healthy headroom';
  }

  static IconData icon(double ratio) {
    if (ratio > 0.50) {
      return Icons.warning_amber_rounded;
    }
    if (ratio > 0.30) {
      return Icons.info_outline_rounded;
    }
    return Icons.check_circle_outline_rounded;
  }

  static String guidance(double ratio) {
    if (ratio > 1) {
      return 'Tracked spend is above the saved credit limit.';
    }
    if (ratio > 0.75) {
      return 'Consider paying this down before adding more spend.';
    }
    if (ratio > 0.50) {
      return 'Keep an eye on this card before the statement closes.';
    }
    if (ratio > 0.30) {
      return 'Above the 30% guideline; lower utilization is generally safer.';
    }
    return 'Lower utilization is generally safer, but this is not a score prediction.';
  }
}
