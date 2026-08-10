import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../app/tutorial_keys.dart';

class _TutorialStep {
  final String title;
  final String body;
  final GlobalKey Function(TutorialKeys) targetKey;
  const _TutorialStep({required this.title, required this.body, required this.targetKey});
}

const _steps = [
  _TutorialStep(
    title: 'Type what you\'re about to spend',
    body: 'Every recommendation below updates for the exact amount.',
    targetKey: _amountField,
  ),
  _TutorialStep(
    title: 'Pick the category',
    body: 'Groceries, fuel, dining — the ranking changes with it.',
    targetKey: _categoryChips,
  ),
  _TutorialStep(
    title: 'This is your best card, and why',
    body: 'The reasons underneath are the real numbers, not a guess.',
    targetKey: _firstCard,
  ),
  _TutorialStep(
    title: 'Scan a card to add it',
    body: 'Point your camera at any card — this button works from every tab.',
    targetKey: _scanFab,
  ),
];

GlobalKey _amountField(TutorialKeys k) => k.amountField;
GlobalKey _categoryChips(TutorialKeys k) => k.categoryChips;
GlobalKey _firstCard(TutorialKeys k) => k.firstRecommendationCard;
GlobalKey _scanFab(TutorialKeys k) => k.scanFab;

/// Task 5 (ui-spec.md A11): four coach-marked steps over the REAL Home
/// screen and shell — not static illustrations. Locates each target via the
/// GlobalKeys in tutorial_keys.dart, shared with HomeScreen and the shell's
/// FAB, so the spotlight sits on whatever is actually on screen right now.
///
/// Deliberately tolerant of a missing target (e.g. step 3 when the wallet is
/// still empty and there's no first card to point at yet): falls back to a
/// centered card with no cutout rather than crashing on a null RenderBox.
class TutorialOverlay extends ConsumerStatefulWidget {
  const TutorialOverlay({super.key});

  @override
  ConsumerState<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends ConsumerState<TutorialOverlay> {
  int _step = 0;
  final _overlayBoxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // On the very first frame this overlay's own RenderBox doesn't exist
    // yet (it's what we're in the middle of building), so _localTargetRect
    // below has nothing to convert into on that pass. One extra frame is
    // enough — after that this State stays mounted across every _next()
    // call, so its RenderBox is always available from then on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _finish() async {
    await ref.read(tutorialSeenProvider.notifier).complete();
  }

  void _next() {
    if (_step >= _steps.length - 1) {
      _finish();
    } else {
      setState(() => _step++);
    }
  }

  /// The target's rect converted into THIS overlay's own local coordinate
  /// space — i.e. Positioned-ready. Target widgets report their position via
  /// `localToGlobal`, which is relative to the whole device screen; but this
  /// overlay sits inside the Scaffold's body Stack, whose (0,0) starts below
  /// the AppBar, not at the screen's true top-left. Feeding a global
  /// coordinate straight into `Positioned` would silently shift everything
  /// up by the AppBar's height — `globalToLocal` on this overlay's own
  /// RenderBox is what corrects for that.
  Rect? _localTargetRect(TutorialKeys keys) {
    final key = _steps[_step].targetKey(keys);
    final targetBox = key.currentContext?.findRenderObject();
    if (targetBox is! RenderBox || !targetBox.attached) return null;

    final overlayBox = _overlayBoxKey.currentContext?.findRenderObject();
    if (overlayBox is! RenderBox || !overlayBox.attached) return null;

    final globalTopLeft = targetBox.localToGlobal(Offset.zero);
    final localTopLeft = overlayBox.globalToLocal(globalTopLeft);
    return localTopLeft & targetBox.size;
  }

  @override
  Widget build(BuildContext context) {
    final tutorialKeys = ref.watch(tutorialKeysProvider);
    final step = _steps[_step];
    final targetRect = _localTargetRect(tutorialKeys);
    final isLast = _step == _steps.length - 1;
    // Same box _localTargetRect used for the coordinate conversion — reused
    // here for its size rather than a LayoutBuilder, since a LayoutBuilder
    // wrapping a Positioned isn't a valid direct Stack child (Positioned
    // needs RenderStack as its immediate ancestor RenderObject).
    final overlayBox = _overlayBoxKey.currentContext?.findRenderObject();
    final overlaySize = overlayBox is RenderBox && overlayBox.attached
        ? overlayBox.size
        : MediaQuery.sizeOf(context);

    return Positioned.fill(
      child: SizedBox.expand(
        key: _overlayBoxKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                ignoring: true,
                child: CustomPaint(painter: _ScrimPainter(targetRect)),
              ),
            ),
            _TooltipCard(
              title: step.title,
              body: step.body,
              targetRect: targetRect,
              overlaySize: overlaySize,
              stepIndex: _step,
              stepCount: _steps.length,
              isLast: isLast,
              onSkip: _finish,
              onNext: _next,
            ),
          ],
        ),
      ),
    );
  }
}

/// Dims everything except a rounded-rect cutout around the current target.
/// `IgnorePointer` wraps this specific layer (not the tooltip below it) so
/// the scrim never blocks the tooltip's own buttons or, once dismissed, the
/// real screen underneath.
class _ScrimPainter extends CustomPainter {
  final Rect? target;
  const _ScrimPainter(this.target);

  @override
  void paint(Canvas canvas, Size size) {
    final scrimPaint = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final fullScreen = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    if (target == null) {
      canvas.drawPath(fullScreen, scrimPaint);
      return;
    }

    final inflated = target!.inflate(8);
    final cutout = Path()
      ..addRRect(RRect.fromRectAndRadius(inflated, const Radius.circular(AppRadius.md)));
    final scrimWithHole = Path.combine(PathOperation.difference, fullScreen, cutout);
    canvas.drawPath(scrimWithHole, scrimPaint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(inflated, const Radius.circular(AppRadius.md)),
      Paint()
        ..color = BambooInk.lime
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _ScrimPainter oldDelegate) => oldDelegate.target != target;
}

class _TooltipCard extends StatelessWidget {
  final String title;
  final String body;
  final Rect? targetRect;
  final Size overlaySize;
  final int stepIndex;
  final int stepCount;
  final bool isLast;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  const _TooltipCard({
    required this.title,
    required this.body,
    required this.targetRect,
    required this.overlaySize,
    required this.stepIndex,
    required this.stepCount,
    required this.isLast,
    required this.onSkip,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    // Place the card below the target if there's room, otherwise above it;
    // centered vertically when there's no target to anchor to at all. All
    // measurements here are in the overlay's own local space (see
    // _localTargetRect's doc comment), matching what Positioned expects.
    const cardWidth = 300.0;
    double top;
    if (targetRect == null) {
      top = (overlaySize.height - 220) / 2;
    } else if (targetRect!.bottom + 180 < overlaySize.height) {
      top = targetRect!.bottom + AppSpace.lg;
    } else {
      top = (targetRect!.top - 180).clamp(AppSpace.xxl, overlaySize.height);
    }
    final left =
        ((overlaySize.width - cardWidth) / 2).clamp(AppSpace.lg, overlaySize.width - cardWidth - AppSpace.lg);

    return Positioned(
      top: top,
      left: left,
      width: cardWidth,
      child: Material(
        color: BambooInk.slate,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  for (var i = 0; i < stepCount; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == stepIndex ? BambooInk.lime : BambooInk.onSlateMuted,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Text(title, style: BambooFonts.heading(16, color: BambooInk.onSlate)),
              const SizedBox(height: 4),
              Text(body, style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
              const SizedBox(height: AppSpace.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: BambooInk.onSlateMuted),
                    onPressed: onSkip,
                    child: const Text('Skip tour'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.lime,
                      foregroundColor: BambooInk.slate,
                      minimumSize: const Size(0, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                    ),
                    onPressed: onNext,
                    child: Text(isLast ? 'Done' : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
