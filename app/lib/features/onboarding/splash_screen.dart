import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';

/// ui-spec.md A1. Purely presentational — the actual "where to go next"
/// decision (session resolved + onboarding-complete state) lives in
/// router.dart's redirect callback, which re-evaluates automatically via
/// refreshListenable once sessionInitProvider/onboardingCompleteProvider
/// settle. This screen never navigates itself.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.canvas,
      child: const Center(
        child: AppLogoMark(size: 88),
      )
          // A brief, purposeful entrance — not decoration for its own sake.
          // Respects reduced-motion automatically (flutter_animate honours
          // MediaQuery.disableAnimations).
          .animate()
          .fadeIn(duration: const Duration(milliseconds: 250))
          .scale(
            begin: const Offset(0.92, 0.92),
            end: const Offset(1, 1),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          ),
    );
  }
}
