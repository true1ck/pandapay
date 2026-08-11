import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
          BoxShadow(
            color: AppColors.teal500.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
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

/// The one canonical light-screen background, transcribed literally from
/// the design handoff — every light screen in the deck (01 Home, 02
/// Wallet, 04 Insights, 05 You, 07..14, 16..23, 25..32) carries this exact
/// CSS on its root element:
///
/// ```css
/// background:
///   radial-gradient(120% 46% at 92%  -4%, #E4F2CF 0%, rgba(228,242,207,0) 58%),
///   radial-gradient( 90% 40% at  0% 104%, #EFF3F6 0%, rgba(239,243,246,0) 62%),
///   #FFFFFF;
/// ```
///
/// Two stacked radials, not one: bamboo green falls in from just *above*
/// the top-right corner, and a cool grey lifts from just *below* the
/// bottom-left. `BoxDecoration` holds a single gradient, so the two layers
/// are two [DecoratedBox]es over a white fill rather than one decoration.
///
/// Every screen previously hand-rolled its own single-radial approximation
/// with a slightly different `center` (-0.5/-0.6/-0.7 across 55 files),
/// which is why the wash visibly jumped as you moved between tabs. Route
/// all of them through here so the app reads as one continuous surface.
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  /// `at 92% -4%` in Alignment space (0..1 → -1..1), sized so the ellipse's
  /// horizontal reach (120% of a 390pt-wide frame) lands at ~1.2× the
  /// short side.
  static const _topRight = BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(0.84, -1.08),
      radius: 1.2,
      colors: [BambooInk.wash, Color(0x00E4F2CF)],
      stops: [0.0, 0.58],
    ),
  );

  /// `at 0% 104%` — the cool grey counterweight in the bottom-left.
  static const _bottomLeft = BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(-1.0, 1.08),
      radius: 0.9,
      colors: [BambooInk.paperCool, Color(0x00EFF3F6)],
      stops: [0.0, 0.62],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: BambooInk.paper,
      child: DecoratedBox(
        decoration: _bottomLeft,
        child: DecoratedBox(
          decoration: _topRight,
          // The screens that use this as their route root (the onboarding
          // chain) have no Scaffold, so without a Material here their
          // ambient DefaultTextStyle is `WidgetsApp._errorTextStyle` — the
          // "you forgot a Material" marker. `Text.style` *merges* onto that,
          // so a BambooFonts style overrode its red monospace but left its
          // `decoration` alone, painting a yellow underline under every line
          // of text on those screens. Transparent, so the wash still shows.
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// Haptics for the two moments [Pressable] doesn't cover.
///
/// [Pressable] fires a selection tick on every card and row, which is the
/// right weight for navigation. These two are for the moments that are not
/// navigation: committing the app's primary action, and confirming
/// something destructive. Kept here rather than picked per call site so the
/// app doesn't end up with five different intensities meaning the same
/// thing.
void primaryActionHaptic() => HapticFeedback.lightImpact();

/// Fire on the *confirm* of a destructive flow, not on opening the dialog —
/// a heavier bump is a signal that something irreversible just happened,
/// and firing it on "are you sure?" would spend that signal on a question.
void destructiveActionHaptic() => HapticFeedback.mediumImpact();

/// The handoff's press state, in one place: *"Cards and rows: scale to
/// `0.98` with a slight shadow reduction, ~120ms"* (README, *Interactions &
/// behavior*).
///
/// Wrap any card or row that responds to a tap. Scaling the child scales
/// whatever shadow it draws along with it, so the deck's "slight shadow
/// reduction" comes out of the same transform rather than needing the
/// caller to hand over its `BoxDecoration`.
///
/// Three things ride along, because every tappable surface in the app
/// wants them and hand-rolled `GestureDetector`s were skipping them:
///
/// - **Haptics.** [HapticFeedback.selectionClick] on tap, matching the
///   deck's restrained motion budget — a selection tick, not an impact.
///   Opt out with `haptic: false` for rows where a tap opens something
///   heavy enough to have its own feedback.
/// - **A 44×44 floor.** The deck's own minimum tap target. A no-op for
///   anything already larger, which is most cards.
/// - **Semantics.** Marks the subtree as a button so screen readers
///   announce it as one; pass [semanticLabel] when the visible child is
///   an icon or a bare numeral that wouldn't read out usefully.
///
/// Deliberately not an `InkWell`: the Bamboo Ink surfaces are tinted
/// glass and slate panels, and a Material ripple spreading across them
/// reads as a different design system than the one the deck specifies.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;
  final bool haptic;

  /// Set false for inline targets whose layout a 44pt floor would
  /// visibly distort (a chip inside a dense row, say). Prefer leaving it
  /// on and giving the target real room.
  final bool enforceMinTarget;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
    this.haptic = true,
    this.enforceMinTarget = true,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _setDown(bool value) {
    if (!_enabled || _down == value) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    Widget child = AnimatedScale(
      scale: _down ? 0.98 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: widget.child,
    );

    if (widget.enforceMinTarget) {
      child = ConstrainedBox(constraints: const BoxConstraints(minWidth: 44, minHeight: 44), child: child);
    }

    return Semantics(
      button: _enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        onTap: _enabled
            ? () {
                if (widget.haptic) HapticFeedback.selectionClick();
                widget.onTap?.call();
              }
            : null,
        onLongPress: widget.onLongPress,
        child: child,
      ),
    );
  }
}

/// A neutral block standing in for content that hasn't loaded — the
/// handoff's *"Show a result, not a spinner, wherever cached rates
/// allow"* applied to the cases where there genuinely is nothing cached
/// to show yet.
///
/// Static on purpose, no shimmer sweep or opacity pulse. Two reasons, in
/// order: the deck's motion budget is explicitly restrained and a
/// travelling highlight is the loudest thing that would then be on
/// screen; and an indefinitely repeating animation never lets
/// `pumpAndSettle` return, which would hang the 38 test files that call
/// it. If a pulse is ever wanted, gate it on
/// `MediaQuery.disableAnimationsOf` and it stays test-safe.
class Skeleton extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const Skeleton({super.key, this.width, this.height = 14, this.radius = 8});

  /// A short line of placeholder text, sized as a fraction of the
  /// available width so a column of them reads as ragged prose rather
  /// than a stack of identical bars.
  factory Skeleton.line({double widthFactor = 1.0, double height = 12}) =>
      _SkeletonLine(widthFactor: widthFactor, height: height);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(radius)),
    );
  }
}

class _SkeletonLine extends Skeleton {
  final double widthFactor;
  const _SkeletonLine({required this.widthFactor, required super.height});

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: super.build(context),
    );
  }
}

/// The placeholder shape of one list row — an avatar tile, two lines of
/// text, and a trailing figure. Matches the real row geometry closely
/// enough that content landing doesn't visibly reflow the list.
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
      child: Row(
        children: [
          const Skeleton(width: 40, height: 40, radius: 12),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton.line(widthFactor: 0.55, height: 13),
                const SizedBox(height: AppSpace.sm),
                Skeleton.line(widthFactor: 0.34, height: 11),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.md),
          const Skeleton(width: 52, height: 16),
        ],
      ),
    );
  }
}

/// [count] stacked [SkeletonRow]s under a hairline divider each — the
/// standard "a list is loading" state for Wallet, Activity and the ranked
/// list on Home.
class SkeletonList extends StatelessWidget {
  final int count;
  const SkeletonList({super.key, this.count = 3});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      child: Column(
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const Divider(height: 1, color: BambooInk.hairlineOnPaper),
            const SkeletonRow(),
          ],
        ],
      ),
    );
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
              decoration: const BoxDecoration(color: BambooInk.paperMuted, shape: BoxShape.circle),
              child: Icon(icon, size: 30, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(
              title,
              style: BambooFonts.heading(16, color: BambooInk.ink900),
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                message!,
                style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                textAlign: TextAlign.center,
              ),
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
              decoration: BoxDecoration(
                color: BambooInk.clay.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.error_outline_rounded, size: 30, color: BambooInk.clay),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(
              'Something went wrong',
              style: BambooFonts.heading(16, color: BambooInk.ink900),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              message,
              style: BambooFonts.ui(13.5, color: BambooInk.ink500),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpace.lg),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  side: const BorderSide(color: BambooInk.hairlineOnPaper),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
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
            style: BambooFonts.ui(11, weight: FontWeight.w600, color: foreground),
          ),
        ],
      ),
    );
  }
}
