import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import 'sync_status_copy.dart';
import 'sync_status_providers.dart';
import 'sync_status_sheet.dart';

/// Mounts the sync-status strip above every route (WP-banner, decision D2).
///
/// Used once, from `MaterialApp.router(builder:)` in `main.dart`, so it shows
/// on every screen including sign-in and onboarding.
///
/// **Healthy state is a no-op layout.** The strip slot is a zero-size box and
/// the app below gets exactly the constraints and the same `MediaQuery` it
/// would get without this widget (`test/features/sync_status/` proves size,
/// offset and MediaQuery parity). The widget tree keeps the same shape in both
/// states, so showing or hiding the strip never rebuilds or resets the
/// Navigator and the screens in it.
///
/// **Visible state owns the top safe area.** The strip is as tall as the status
/// bar inset plus one slim line, and the content below has its top padding
/// removed, so nothing is padded twice and nothing is covered. Keyboard
/// insets, the bottom padding and back gestures are untouched.
///
/// Rebuilds only when the strip appears or disappears (`select`); count
/// changes rebuild just the strip.
class SyncStatusBanner extends ConsumerWidget {
  const SyncStatusBanner({super.key, required this.child, this.navigatorKey});

  /// The Navigator built by `MaterialApp.router`.
  final Widget? child;

  /// The root Navigator, used to open the Sync status sheet above the app.
  /// The strip itself sits above the Navigator and has no Navigator ancestor.
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(
      syncStatusSummaryProvider.select((summary) => summary.visible),
    );
    // `verticalDirection: up` lays the strip out at the TOP while painting it
    // AFTER the app. That order matters for accessibility: a route's modal
    // barrier uses BlockSemantics, which drops the semantics of everything
    // painted before it, so a strip painted first would be silent to
    // TalkBack/VoiceOver (verified by test).
    return Column(
      verticalDirection: VerticalDirection.up,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: visible,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        if (visible)
          SyncStatusStrip(navigatorKey: navigatorKey)
        else
          const SizedBox.shrink(),
      ],
    );
  }
}

/// The slim strip itself: one 12 sp line under the status bar.
class SyncStatusStrip extends ConsumerWidget {
  const SyncStatusStrip({super.key, this.navigatorKey});

  final GlobalKey<NavigatorState>? navigatorKey;

  /// Height of the line, below the status bar inset.
  static const double lineHeight = 18;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(syncStatusSummaryProvider);
    if (!summary.visible) return const SizedBox.shrink();

    final dark = Theme.of(context).brightness == Brightness.dark;
    final attention = summary.mode == SyncStatusMode.needsAttention;
    final palette = _Palette.of(dark: dark, attention: attention);
    final topInset = MediaQuery.paddingOf(context).top;
    final label = syncStatusLabel(summary);

    return Semantics(
      container: true,
      button: true,
      label: syncStatusSemanticsLabel(summary),
      excludeSemantics: true,
      onTap: () => _open(context),
      child: Material(
        key: const Key('sync-status-strip'),
        color: palette.background,
        child: InkWell(
          onTap: () => _open(context),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.hairline)),
            ),
            child: Padding(
              padding: EdgeInsets.only(top: topInset),
              // A big system text size must not turn the strip into a banner.
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.5,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: lineHeight),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 1,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _icon(summary.mode),
                            size: 12,
                            color: palette.text,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: BambooFonts.ui(
                                11,
                                weight: FontWeight.w500,
                                color: palette.text,
                                height: 1.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    final navigatorContext = navigatorKey?.currentContext;
    if (navigatorContext == null) return;
    showSyncStatusSheet(navigatorContext);
  }

  static IconData _icon(SyncStatusMode mode) => switch (mode) {
    SyncStatusMode.offline => Icons.cloud_off_outlined,
    SyncStatusMode.unreachable => Icons.cloud_off_outlined,
    SyncStatusMode.syncing => Icons.sync_rounded,
    SyncStatusMode.needsAttention => Icons.sync_problem_outlined,
    SyncStatusMode.hidden => Icons.check,
  };
}

class _Palette {
  const _Palette({
    required this.background,
    required this.text,
    required this.hairline,
  });

  final Color background;
  final Color text;
  final Color hairline;

  static _Palette of({required bool dark, required bool attention}) {
    if (attention) {
      return dark
          ? const _Palette(
              background: Color(0xFF3A2E14),
              text: Color(0xFFF2C46B),
              hairline: Color(0xFF55421C),
            )
          : const _Palette(
              background: Color(0xFFFFF1D6),
              text: Color(0xFF8A4B00),
              hairline: Color(0xFFF3DCA8),
            );
    }
    return dark
        ? const _Palette(
            background: BambooInk.slateLow,
            text: BambooInk.onSlateSubtle,
            hairline: BambooInk.slateHairline,
          )
        : const _Palette(
            background: BambooInk.paperMuted,
            text: BambooInk.ink700,
            hairline: BambooInk.hairlineOnPaper,
          );
  }
}
