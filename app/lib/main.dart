import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'app/design/app_theme.dart';
import 'app/env.dart';
import 'app/error_handling.dart';
import 'app/router.dart';
import 'features/settings/appearance_providers.dart';

void main() {
  // error_handling.dart: catches the class of error that isn't caught by
  // Flutter's own build-error recovery (a stray unawaited Future, a
  // platform-channel callback) and would otherwise silently kill the whole
  // app on a real device — "unexpectedly shuts down" from the user's side.
  // Installed before anything else runs, so no early failure slips past it.
  installGlobalErrorHandlers();

  // Replaces the widget shown in place of one whose build() threw. Debug
  // builds keep Flutter's own red screen (a developer tool no real user
  // ever sees); every other build gets a widget that can't itself crash
  // from being handed unexpected constraints — see AppErrorWidget's doc.
  if (!kDebugMode) {
    ErrorWidget.builder = (details) => AppErrorWidget(details: details);
  }

  // Plan Phase 0.3: refuse to start a release build that was compiled
  // without the backend --dart-defines, rather than shipping one that can
  // only ever show users a network error. No-op in debug/profile and in any
  // correctly-configured release. See app/env.dart.
  //
  // Deliberately OUTSIDE runGuarded below: this throw is meant to be loud
  // and fatal — "a crash on the first frame with an actionable message is
  // strictly better than shipping a build that can only ever show users a
  // network error" (env.dart's own words). Inside the zone guard, that
  // exception would just become a silent CrashLog entry behind a blank
  // screen, which is the opposite of what this check exists for.
  Env.assertReleaseConfigured();

  runGuarded(() {
    // Debug-only: materialise the semantics tree even when no assistive
    // technology is attached.
    //
    // Two reasons. It is what lets `uiautomator` (and so the emulator
    // tooling this project drives QA with) see the app as labelled nodes
    // rather than one opaque rectangle. And it means the semantics added
    // this pass — MoneyText announcing "estimated", Pressable's button
    // roles, the tile labels — are exercised on every debug run instead of
    // only when someone turns TalkBack on.
    //
    // Release builds are untouched: Flutter already builds the tree on
    // demand there when a real accessibility service asks for it, and
    // forcing it on unconditionally would be a permanent cost for no gain.
    if (kDebugMode) {
      WidgetsFlutterBinding.ensureInitialized();
      SemanticsBinding.instance.ensureSemantics();
    }
    runApp(const ProviderScope(child: PandaPayApp()));
  });
}

/// UA-0.4.2 bottom nav: Home · Cards · raised SCAN FAB · Activity · Account.
/// All four tabs are real as of Chunk 18. Navigation shell (route
/// registration, the FAB, and the bottom nav itself) lives in
/// app/router.dart as of the go_router migration (Task 3) — this widget
/// just wires the router into MaterialApp.
///
/// Task H6 (Appearance): the app's display preferences are applied here, at
/// the root, since that is the only place they can reach every screen.
///
/// **Theme mode is pinned to light.** Every screen migrated to Bamboo Ink
/// paints its own surfaces from that palette's fixed constants — including
/// [AppBackground], which is a hardcoded white-plus-wash — so `ThemeMode`
/// no longer changes what the user sees on any of them. Leaving the app
/// free to resolve to [AppTheme.dark] produced the worst of both: Bamboo
/// screens stayed light while Material-supplied chrome underneath them
/// (segmented buttons, tab indicators, unstyled text) went dark, on the
/// same screen. Note that pinning here is what makes that impossible, not
/// merely the Appearance screen no longer offering the choice — `System`
/// would otherwise still flip the app on any device set to dark.
/// [AppTheme.dark] is left in place, unreferenced by this widget, because
/// it is the honest starting point for the real dark ramp whenever the
/// design system grows one.
///
/// **Text scale is applied here too**, which it previously wasn't: the
/// preference only ever affected the Appearance screen's own body via a
/// local override there, so choosing 130% did nothing anywhere else in the
/// app. See [_scaledTextMediaQuery] for how it composes with the OS
/// setting.
class PandaPayApp extends ConsumerWidget {
  const PandaPayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textScale = ref.watch(textScaleProvider);
    return MaterialApp.router(
      title: 'PandaPay',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.light,
      builder: (context, child) => _scaledTextMediaQuery(context, child, textScale),
      routerConfig: ref.watch(goRouterProvider),
    );
  }
}

/// Applies the in-app text-size preference *on top of* whatever the OS
/// accessibility setting already asks for, then clamps the combination to
/// 200% — H6's own stated ceiling, and the point past which the money
/// figures on the verdict card stop fitting their row.
///
/// The OS scaler is read back as a plain factor via `scale(1.0)` and
/// re-expressed as a linear one. On iOS at the largest accessibility sizes
/// the platform scaler is non-linear, so this is an approximation of it
/// rather than an exact composition — deliberately so: the alternative is
/// leaving the app preference unapplied, which is what the app did before
/// and is a worse answer for the user who set it.
Widget _scaledTextMediaQuery(BuildContext context, Widget? child, double appScale) {
  final media = MediaQuery.of(context);
  final combined = (media.textScaler.scale(1.0) * appScale).clamp(0.85, 2.0);
  return MediaQuery(
    data: media.copyWith(textScaler: TextScaler.linear(combined)),
    child: child ?? const SizedBox.shrink(),
  );
}

/// UA-0.2.4: financial figures must always render through a widget that
/// requires a [Confidence] — a bare `Text('₹\$x')` is a compile-time trap
/// waiting to happen once the custom_lint rule lands (see analysis_options.yaml).
///
/// Task H6: reads numberFormatProvider so every one of this widget's 40+
/// call sites picks up the Appearance screen's lakh/crore-vs-international
/// preference without threading a parameter through each of them — this is
/// the one call site H6 needs to edit, not all its callers.
class MoneyText extends ConsumerWidget {
  final Money amount;
  final Confidence confidence;
  final TextStyle? style;

  /// Trailing words that belong to the figure and must wrap/ellipsize with
  /// it — "₹1,842 earned", "₹24,180 all-time ›". Set here rather than as a
  /// sibling `Text` so the whole phrase stays one line box, and so the
  /// no_bare_money_text lint still has one widget owning the number.
  final String? suffix;

  /// Design 01's header sets three figures on one 42pt-tall row; a
  /// confidence chip beside each turns it into a row of icons. Callers that
  /// carry the confidence signal elsewhere on the screen (or, as here, on
  /// the primary figure only) can drop the secondary one.
  final bool showConfidenceIcon;

  /// Drops a `.00` tail on whole-rupee amounts — see [Money.format]. For
  /// headline display figures, which the design deck always writes without
  /// paise ("₹125", never "₹125.00"). Non-zero paise still render in full,
  /// so nothing is rounded away.
  final bool hidePaise;

  const MoneyText(
    this.amount, {
    super.key,
    required this.confidence,
    this.style,
    this.suffix,
    this.showConfidenceIcon = true,
    this.hidePaise = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseStyle = style ?? Theme.of(context).textTheme.titleMedium;
    final numberFormat = ref.watch(numberFormatProvider);
    final formatted = '${amount.format(format: numberFormat, hidePaise: hidePaise)}${suffix ?? ''}';

    // One Semantics wrapper here covers every money figure in the app —
    // 40+ call sites — rather than each screen remembering to label its
    // own. Two things a screen reader would otherwise miss: the ₹ glyph
    // and grouping are announced inconsistently across engines, and the
    // confidence icon beside the number is pure visual signal with no text
    // equivalent. Saying "estimated" out loud is the whole point of that
    // icon; a user who can't see it would otherwise take an estimate for a
    // settled figure.
    return Semantics(
      label: confidence.isConfirmed ? formatted : '$formatted, estimated',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // This *is* the required Money-rendering widget — exempt by design.
          // Deliberately NOT wrapped in Flexible: this Row is mainAxisSize.min
          // and several of the 40+ call sites render it under unbounded width,
          // where a flex child asserts. Callers that need clipping wrap the
          // whole MoneyText instead.
          // ignore: no_bare_money_text
          Text(
            formatted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: baseStyle?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          if (showConfidenceIcon) ...[
            const SizedBox(width: 6),
            Icon(
              confidence.isConfirmed ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
              size: 14,
              color: confidence.isConfirmed ? BambooInk.jade : BambooInk.amber,
            ),
          ],
        ],
      ),
    );
  }
}
