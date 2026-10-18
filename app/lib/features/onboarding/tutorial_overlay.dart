import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/tutorial_keys.dart';

enum TutorialPage { home, manual, scan, voice, spending }

class _TutorialStep {
  final TutorialPage page;
  final String title;
  final String body;
  final GlobalKey Function(TutorialKeys) targetKey;

  const _TutorialStep({
    required this.page,
    required this.title,
    required this.body,
    required this.targetKey,
  });
}

const _steps = [
  _TutorialStep(
    page: TutorialPage.home,
    title: 'Make every card count.',
    body:
        'Choose an amount and category on Home. Panda compares your cards and explains which one could earn you more.',
    targetKey: _amountField,
  ),
  _TutorialStep(
    page: TutorialPage.manual,
    title: 'Add a transaction yourself.',
    body:
        'Tap + on Home to open Quick add. Add the amount, payment method and category, and attach a receipt photo or file if you like. Save when you’re ready. This tour won’t save a transaction.',
    targetKey: _manualAmount,
  ),
  _TutorialStep(
    page: TutorialPage.scan,
    title: 'Scan before you spend.',
    body:
        'Use the centre scan button for a merchant’s UPI QR code. Panda helps you choose a card, then you can review and log the spend.',
    targetKey: _scanFab,
  ),
  _TutorialStep(
    page: TutorialPage.voice,
    title: 'Or just say it to Panda.',
    body:
        'Tap the mic and say something like “Spent ₹250 on groceries.” Review the details before saving—handy when you don’t want to type.',
    targetKey: _voiceFab,
  ),
  _TutorialStep(
    page: TutorialPage.spending,
    title: 'See where your money goes.',
    body:
        'Insights → Spending brings your totals, categories and trends together. Change the period or filters here. Insights also has budgets, rewards and bill details.',
    targetKey: _spendingPeriod,
  ),
];

GlobalKey _amountField(TutorialKeys keys) => keys.amountField;
GlobalKey _manualAmount(TutorialKeys keys) => keys.manualAmount;
GlobalKey _scanFab(TutorialKeys keys) => keys.scanFab;
GlobalKey _voiceFab(TutorialKeys keys) => keys.voiceFab;
GlobalKey _spendingPeriod(TutorialKeys keys) =>
    keys.spendingSummary.currentContext != null
    ? keys.spendingSummary
    : keys.spendingPeriod;

/// The shell owns navigation; the guide stays above its Navigator, dock and
/// microphone. A modal barrier blocks even the spotlight's transparent area,
/// so tapping a highlighted control cannot open a different route mid-step.
class TutorialOverlay extends ConsumerStatefulWidget {
  final Future<void> Function(TutorialPage page) onShowPage;
  final Future<void> Function(bool completed) onFinish;

  const TutorialOverlay({
    super.key,
    required this.onShowPage,
    required this.onFinish,
  });

  @override
  ConsumerState<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends ConsumerState<TutorialOverlay>
    with WidgetsBindingObserver {
  int _step = 0;
  bool _moving = true;
  bool _finishing = false;
  String? _message;
  Rect? _targetRect;
  final _overlayBoxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showStep(0));
      _trackTarget(Duration.zero);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Remeasure after returning from the background without resetting or
      // advancing the current step.
      setState(() => _targetRect = null);
    }
  }

  Future<void> _showStep(int index) async {
    setState(() {
      _step = index;
      _moving = true;
      _targetRect = null;
      _message = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await widget.onShowPage(_steps[index].page);
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final target = _steps[index]
          .targetKey(ref.read(tutorialKeysProvider))
          .currentContext;
      if (target != null &&
          target.mounted &&
          ModalRoute.of(target)?.isCurrent != false) {
        await Scrollable.ensureVisible(
          target,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'This view isn’t ready yet. You can continue the tour or skip it.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _moving = false;
          _targetRect = _localTargetRect();
        });
      }
    }
  }

  /// Observe real rendered frames, including data refreshes, scrolling and
  /// size changes. Registering the next callback does not request a frame;
  /// only a changed rectangle needs a repaint, so the guide stays idle too.
  void _trackTarget(Duration _) {
    if (!mounted) return;
    if (!_moving && !_finishing) {
      final target = _localTargetRect();
      if (target != _targetRect) setState(() => _targetRect = target);
    }
    WidgetsBinding.instance.addPostFrameCallback(_trackTarget);
  }

  Rect? _localTargetRect() {
    final targetContext = _steps[_step]
        .targetKey(ref.read(tutorialKeysProvider))
        .currentContext;
    if (targetContext == null ||
        ModalRoute.of(targetContext)?.isCurrent == false) {
      return null;
    }
    final target = targetContext.findRenderObject();
    final overlay = _overlayBoxKey.currentContext?.findRenderObject();
    if (target is! RenderBox ||
        !target.attached ||
        !target.hasSize ||
        overlay is! RenderBox ||
        !overlay.attached ||
        !overlay.hasSize) {
      return null;
    }
    final topLeft = overlay.globalToLocal(target.localToGlobal(Offset.zero));
    final rect = (topLeft & target.size).intersect(Offset.zero & overlay.size);
    return rect.isEmpty || !rect.isFinite ? null : rect;
  }

  Future<void> _finish(bool completed) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await widget.onFinish(completed);
    } catch (_) {
      if (mounted) {
        setState(() {
          _finishing = false;
          _message = 'We couldn’t close the tour. Please try again.';
        });
      }
    }
  }

  void _next() {
    if (_moving || _finishing) return;
    if (_step == _steps.length - 1) {
      unawaited(_finish(true));
    } else {
      unawaited(_showStep(_step + 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_step];
    final busy = _moving || _finishing;
    return Positioned.fill(
      child: BlockSemantics(
        child: SizedBox.expand(
          key: _overlayBoxKey,
          child: Stack(
            children: [
              const Positioned.fill(
                child: ModalBarrier(
                  dismissible: false,
                  color: Colors.transparent,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _ScrimPainter(_targetRect)),
                ),
              ),
              Positioned.fill(
                child: CustomMultiChildLayout(
                  delegate: _TooltipLayout(
                    target: _targetRect,
                    safePadding: MediaQuery.paddingOf(context),
                  ),
                  children: [
                    LayoutId(
                      id: _tooltipId,
                      child: _TooltipCard(
                        title: step.title,
                        body: step.body,
                        message: _message,
                        stepIndex: _step,
                        stepCount: _steps.length,
                        busy: busy,
                        onSkip: _finishing ? null : () => _finish(false),
                        onBack: _step == 0 || busy
                            ? null
                            : () => _showStep(_step - 1),
                        onNext: busy ? null : _next,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _tooltipId = 'tutorial-tooltip';

/// Position using the card's actual laid-out height, including large text,
/// instead of assuming a fixed height that can hide Next behind the dock.
class _TooltipLayout extends MultiChildLayoutDelegate {
  final Rect? target;
  final EdgeInsets safePadding;

  _TooltipLayout({required this.target, required this.safePadding});

  @override
  void performLayout(Size size) {
    final margin = math.min(16.0, size.width / 8);
    final minTop = safePadding.top + margin;
    final maxBottom = math.max(
      minTop,
      size.height - safePadding.bottom - margin,
    );
    final card = layoutChild(
      _tooltipId,
      BoxConstraints.loose(
        Size(
          math.min(360, math.max(0, size.width - margin * 2)),
          math.max(0, maxBottom - minTop),
        ),
      ),
    );
    final maxTop = math.max(minTop, maxBottom - card.height);
    var top = minTop + (maxBottom - minTop - card.height) / 2;
    if (target != null) {
      final below = target!.bottom + 16;
      final above = target!.top - 16 - card.height;
      if (below + card.height <= maxBottom) {
        top = below;
      } else if (above >= minTop) {
        top = above;
      }
    }
    positionChild(
      _tooltipId,
      Offset((size.width - card.width) / 2, top.clamp(minTop, maxTop)),
    );
  }

  @override
  bool shouldRelayout(covariant _TooltipLayout oldDelegate) =>
      target != oldDelegate.target || safePadding != oldDelegate.safePadding;
}

class _ScrimPainter extends CustomPainter {
  final Rect? target;
  const _ScrimPainter(this.target);

  @override
  void paint(Canvas canvas, Size size) {
    final fullScreen = Path()..addRect(Offset.zero & size);
    final paint = Paint()..color = BambooInk.slate.withValues(alpha: 0.55);
    if (target == null) {
      canvas.drawPath(fullScreen, paint);
      return;
    }
    final spotlight = RRect.fromRectAndRadius(
      target!.inflate(6),
      const Radius.circular(16),
    );
    final hole = Path()..addRRect(spotlight);
    canvas.drawPath(
      Path.combine(PathOperation.difference, fullScreen, hole),
      paint,
    );
    canvas.drawRRect(
      spotlight,
      Paint()
        ..color = BambooInk.lime
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _ScrimPainter oldDelegate) =>
      target != oldDelegate.target;
}

class _TooltipCard extends StatelessWidget {
  final String title, body;
  final String? message;
  final int stepIndex, stepCount;
  final bool busy;
  final VoidCallback? onSkip, onBack, onNext;

  const _TooltipCard({
    required this.title,
    required this.body,
    required this.message,
    required this.stepIndex,
    required this.stepCount,
    required this.busy,
    required this.onSkip,
    required this.onBack,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: BambooInk.paper,
    elevation: 12,
    shadowColor: BambooInk.slate.withValues(alpha: 0.2),
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Image.asset(
                'assets/illustrations/panda_peek.png',
                width: 42,
                height: 42,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'PANDA’S QUICK TOUR',
                  style: BambooFonts.ui(
                    10.5,
                    color: BambooInk.jade,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${stepIndex + 1} of $stepCount',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: (stepIndex + 1) / stepCount,
            color: BambooInk.jade,
            backgroundColor: const Color(0xFFEAF1E2),
            borderRadius: BorderRadius.circular(4),
            minHeight: 4,
          ),
          const SizedBox(height: 18),
          Semantics(
            liveRegion: true,
            child: Text(
              title,
              style: BambooFonts.heading(
                21,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
                height: 1.15,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: BambooFonts.ui(14, color: BambooInk.ink700, height: 1.45),
          ),
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(message!, style: BambooFonts.ui(12, color: BambooInk.clay)),
          ],
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: onSkip,
                style: TextButton.styleFrom(foregroundColor: BambooInk.ink500),
                child: const Text('Skip tour'),
              ),
              if (stepIndex > 0)
                TextButton(
                  onPressed: onBack,
                  style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
                  child: const Text('Back'),
                ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  minimumSize: const Size(100, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                ),
                onPressed: onNext,
                child: busy
                    ? const SizedBox.square(
                        dimension: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        stepIndex == stepCount - 1
                            ? 'Explore Insights'
                            : 'Next',
                      ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
