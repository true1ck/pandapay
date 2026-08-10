import 'package:flutter/material.dart';

import 'app_theme.dart';

/// PandaPay's brand mark — a rounded panda-ear silhouette in a teal tile.
/// Used on the login screen and anywhere the app needs to introduce
/// itself, so there's one real "this is PandaPay" moment instead of a
/// bare form.
class AppLogoMark extends StatelessWidget {
  final double size;
  const AppLogoMark({super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.teal500, AppColors.navy800],
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
        boxShadow: [
          BoxShadow(color: AppColors.teal500.withValues(alpha: 0.28), blurRadius: 20, offset: const Offset(0, 8)),
        ],
      ),
      child: Icon(Icons.savings_rounded, color: Colors.white, size: size * 0.52),
    );
  }
}

/// The real panda-mark logo from the Bamboo Ink handoff
/// (`assets/logo/pandapay_mark.png`, registered in pubspec.yaml) —
/// distinct from [AppLogoMark] above, which is the older placeholder
/// icon still used by screens not yet migrated to the new design system
/// (e.g. the login screen).
class PandaMark extends StatelessWidget {
  final double size;
  const PandaMark({super.key, this.size = 42});

  @override
  Widget build(BuildContext context) {
    return Image.asset('assets/logo/pandapay_mark.png', width: size, height: size, fit: BoxFit.contain);
  }
}

/// Centered placeholder for "nothing here yet" states — icon, headline,
/// optional supporting copy and action, so empty states read as
/// intentional rather than broken.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // A scroll view rather than a bare Center+Column: on a short viewport
    // (landscape phone, split-screen, or a keyboard eating half the
    // available height) a fixed-size icon plus title plus message plus
    // action can legitimately exceed the space this renders into. Scrolling
    // degrades gracefully; a bare Column throws a RenderFlex overflow.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(color: AppColors.surfaceMuted, shape: BoxShape.circle),
              child: Icon(icon, size: 30, color: AppColors.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(title, style: textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(message!, style: textTheme.bodyMedium, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: AppSpace.lg), action!],
          ],
        ),
      ),
    );
  }
}

/// Centered "something went wrong" state with a user-facing message and a
/// retry action — pairs with userFacingErrorMessage() so no screen shows a
/// raw exception dump.
class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorState({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // See EmptyState's build() for why this scrolls rather than overflows.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(color: AppColors.errorBg, shape: BoxShape.circle),
              child: const Icon(Icons.error_outline_rounded, size: 30, color: AppColors.error),
            ),
            const SizedBox(height: AppSpace.lg),
            Text('Something went wrong', style: textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: AppSpace.sm),
            Text(message, style: textTheme.bodyMedium, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpace.lg),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

/// A small rounded status pill (e.g. "Confirmed" / "Estimated" / "Override")
/// — the one place confidence/status badges are built, so they stay visually
/// consistent everywhere they appear.
class StatusPill extends StatelessWidget {
  final String label;
  final Color foreground;
  final Color background;
  final IconData? icon;

  const StatusPill({
    super.key,
    required this.label,
    required this.foreground,
    required this.background,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 4),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(AppRadius.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: foreground), const SizedBox(width: 4)],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
