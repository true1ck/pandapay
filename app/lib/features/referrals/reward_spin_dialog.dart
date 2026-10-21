import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/referral_repository.dart';

/// A visual wheel slice. Slice size is intentionally independent of prize
/// weight; the server selects the prize using the configured weighted odds.
@immutable
class SpinWheelSector {
  const SpinWheelSector({
    required this.prize,
    required this.startAngle,
    required this.sweepAngle,
  });

  final SpinPrize prize;
  final double startAngle;
  final double sweepAngle;

  double get centerAngle => startAngle + sweepAngle / 2;
}

/// Builds equal-size presentation slices while leaving the actual odds intact.
List<SpinWheelSector> equalSpinWheelSectors(SpinConfiguration configuration) {
  final count = configuration.prizes.length;
  if (count == 0) return const [];

  final sweep = math.pi * 2 / count;
  return List.generate(
    count,
    (index) => SpinWheelSector(
      prize: configuration.prizes[index],
      startAngle: -math.pi / 2 + sweep * index,
      sweepAngle: sweep,
    ),
  );
}

/// Returns the wheel rotation that places the server-selected prize at the
/// fixed pointer. Weighted selection happens on the server, not from the UI.
double? spinWheelRotationForResult(
  SpinConfiguration configuration,
  SpinResult result,
) {
  final selected = configuration.prizeFor(result);
  if (selected == null) return null;
  for (final sector in equalSpinWheelSectors(configuration)) {
    if (sector.prize.id == selected.id) {
      return (-math.pi / 2 - sector.centerAngle) % (math.pi * 2);
    }
  }
  return null;
}

class RewardSpinDialog extends StatefulWidget {
  const RewardSpinDialog({
    required this.loadConfiguration,
    required this.onSpin,
    required this.onCheckResult,
    super.key,
  });

  final Future<SpinConfiguration> Function() loadConfiguration;
  final Future<SpinResult?> Function() onSpin;
  final Future<SpinResult?> Function() onCheckResult;

  @override
  State<RewardSpinDialog> createState() => _RewardSpinDialogState();
}

class _RewardSpinDialogState extends State<RewardSpinDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wheelController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    upperBound: 1000,
  );

  SpinConfiguration? _configuration;
  SpinResult? _result;
  bool _loadingConfiguration = true;
  bool _spinning = false;
  bool _checking = false;
  bool _needsCheck = false;
  String? _configurationError;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadConfiguration());
  }

  @override
  void dispose() {
    _wheelController.dispose();
    super.dispose();
  }

  Future<void> _loadConfiguration() async {
    setState(() {
      _loadingConfiguration = true;
      _configurationError = null;
    });
    try {
      final configuration = await widget.loadConfiguration();
      if (!mounted) return;
      setState(() {
        _configuration = configuration;
        _loadingConfiguration = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingConfiguration = false;
        _configurationError =
            'We couldn’t load the reward wheel. Check your connection and try again.';
      });
    }
  }

  Future<void> _spin() async {
    final configuration = _configuration;
    if (configuration == null || _spinning || _needsCheck) return;
    setState(() {
      _spinning = true;
      _actionError = null;
    });
    final spinStartedAt = Stopwatch()..start();
    _wheelController.repeat(
      min: 0,
      max: 1,
      period: const Duration(milliseconds: 520),
    );

    SpinResult? result;
    try {
      result = await widget.onSpin();
    } catch (_) {
      // The parent owns the recovery path and performs a canonical read after
      // a failed request. No client-side prize is selected here.
      _actionError = 'We couldn’t confirm the spin result.';
    }

    // Keep a clearly visible fast phase even when the API responds instantly.
    const minimumFastSpin = Duration(milliseconds: 720);
    final remainingFastSpin = minimumFastSpin - spinStartedAt.elapsed;
    if (remainingFastSpin > Duration.zero) {
      await Future<void>.delayed(remainingFastSpin);
    }
    if (!mounted) return;
    if (result == null) {
      final currentTurn = _wheelController.value;
      await _wheelController.animateTo(
        currentTurn.ceilToDouble() + .72,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) return;
      setState(() {
        _spinning = false;
        _needsCheck = true;
        _actionError ??=
            'Your result may already be saved. Check it before doing anything else.';
      });
      return;
    }
    await _reveal(configuration, result);
  }

  Future<void> _checkSavedResult() async {
    if (_checking || _spinning) return;
    setState(() {
      _checking = true;
      _actionError = null;
    });
    try {
      final result = await widget.onCheckResult();
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _checking = false;
          _actionError =
              'There’s no confirmed result yet. Reconnect and check again.';
        });
        return;
      }
      await _reveal(_configuration!, result);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _actionError = 'We still can’t confirm the saved result. Try again.';
      });
    }
  }

  Future<void> _reveal(
    SpinConfiguration configuration,
    SpinResult result,
  ) async {
    _wheelController.stop();
    final target = _targetAngle(configuration, result);
    final targetFraction = _positiveTurn(target / (math.pi * 2));
    final currentFraction = _wheelController.value;
    final finalTurn = currentFraction.ceilToDouble() + 4 + targetFraction;
    await _wheelController.animateTo(
      finalTurn,
      duration: const Duration(milliseconds: 3100),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _spinning = false;
      _checking = false;
      _needsCheck = false;
      _actionError = null;
    });
  }

  double _targetAngle(SpinConfiguration configuration, SpinResult result) {
    return spinWheelRotationForResult(configuration, result) ?? 0;
  }

  double _positiveTurn(double turns) => (turns % 1 + 1) % 1;

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final configuration = _configuration;
    return Dialog(
      backgroundColor: BambooInk.paper,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Close reward game',
                  onPressed: _spinning || _checking
                      ? null
                      : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                  color: BambooInk.ink500,
                ),
              ),
              Text(
                result == null ? 'Your reward is ready' : 'Spin complete',
                textAlign: TextAlign.center,
                style: BambooFonts.heading(24, color: BambooInk.ink900),
              ),
              const SizedBox(height: 5),
              Text(
                result == null
                    ? 'Give the wheel a spin. Your result is saved to your account.'
                    : 'This server-confirmed result is saved with your account.',
                textAlign: TextAlign.center,
                style: BambooFonts.ui(13, color: BambooInk.ink500, height: 1.4),
              ),
              const SizedBox(height: 18),
              _WheelPanel(
                rotation: _wheelController,
                configuration: configuration,
                loading: _loadingConfiguration,
                spinning: _spinning,
                result: result,
              ),
              const SizedBox(height: 14),
              if (result != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    vertical: 15,
                    horizontal: 12,
                  ),
                  decoration: BoxDecoration(
                    color: BambooInk.slate,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      Text(
                        result.amount.value == 0
                            ? 'No credits this time'
                            : result.amount.inr,
                        textAlign: TextAlign.center,
                        style: BambooFonts.money(
                          result.amount.value == 0 ? 21 : 34,
                          color: BambooInk.lime,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        result.amount.value == 0
                            ? 'Your result is saved. You can use the app to earn another referral reward.'
                            : 'promotional subscription credits added',
                        textAlign: TextAlign.center,
                        style: BambooFonts.ui(12.5, color: BambooInk.onSlate),
                      ),
                    ],
                  ),
                ),
              ],
              if (_configurationError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _configurationError!,
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(12.5, color: BambooInk.clayInk),
                ),
                TextButton(
                  onPressed: _loadingConfiguration ? null : _loadConfiguration,
                  child: const Text('Load prize odds again'),
                ),
              ],
              if (_actionError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _actionError!,
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(12.5, color: BambooInk.clayInk),
                ),
              ],
              const SizedBox(height: 13),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('referral-spin-action'),
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    disabledBackgroundColor: BambooInk.slate.withValues(
                      alpha: .6,
                    ),
                    disabledForegroundColor: BambooInk.onSlateMuted,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed:
                      _spinning ||
                          _checking ||
                          _loadingConfiguration ||
                          _configurationError != null
                      ? null
                      : result != null
                      ? () => Navigator.of(context).pop(result)
                      : _needsCheck
                      ? _checkSavedResult
                      : _spin,
                  icon: _spinning || _checking
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BambooInk.lime,
                          ),
                        )
                      : Icon(
                          result != null
                              ? Icons.check_rounded
                              : _needsCheck
                              ? Icons.refresh_rounded
                              : Icons.casino_rounded,
                        ),
                  label: Text(
                    _spinning
                        ? 'Picking your prize…'
                        : _checking
                        ? 'Checking saved result…'
                        : result != null
                        ? 'Done'
                        : _needsCheck
                        ? 'Check saved result'
                        : 'Spin now',
                  ),
                ),
              ),
              if (result == null && !_needsCheck) ...[
                const SizedBox(height: 7),
                Text(
                  'One spin per completed referral · promotional subscription credits',
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(10.5, color: BambooInk.ink500),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WheelPanel extends StatelessWidget {
  const _WheelPanel({
    required this.rotation,
    required this.configuration,
    required this.loading,
    required this.spinning,
    required this.result,
  });

  final AnimationController rotation;
  final SpinConfiguration? configuration;
  final bool loading;
  final bool spinning;
  final SpinResult? result;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 14),
    decoration: BoxDecoration(
      color: BambooInk.slate,
      borderRadius: BorderRadius.circular(24),
      boxShadow: spinning
          ? [
              BoxShadow(
                color: BambooInk.lime.withValues(alpha: .22),
                blurRadius: 22,
                spreadRadius: 1,
              ),
            ]
          : const [],
    ),
    child: Column(
      children: [
        SizedBox(
          width: 248,
          height: 248,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (configuration != null)
                AnimatedBuilder(
                  animation: rotation,
                  builder: (context, child) => CustomPaint(
                    size: const Size.square(236),
                    painter: _PrizeWheelPainter(
                      configuration!,
                      rotation.value * math.pi * 2,
                    ),
                  ),
                )
              else
                const SizedBox(
                  width: 228,
                  height: 228,
                  child: CircularProgressIndicator(
                    color: BambooInk.lime,
                    strokeWidth: 3,
                  ),
                ),
              if (configuration != null)
                Container(
                  width: 66,
                  height: 66,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: BambooInk.paper,
                    shape: BoxShape.circle,
                    border: Border.all(color: BambooInk.lime, width: 3),
                  ),
                  child: Text(
                    result == null ? 'PANDA\nPAY' : 'SAVED',
                    textAlign: TextAlign.center,
                    style: BambooFonts.heading(
                      11,
                      color: BambooInk.slate,
                      height: 1.05,
                    ),
                  ),
                ),
              if (configuration != null)
                Positioned(
                  top: 0,
                  child: AnimatedBuilder(
                    animation: rotation,
                    child: const Icon(
                      Icons.arrow_drop_down_rounded,
                      color: BambooInk.lime,
                      size: 40,
                      shadows: [
                        Shadow(color: BambooInk.slateLow, blurRadius: 4),
                      ],
                    ),
                    builder: (context, child) => Transform.rotate(
                      angle: spinning
                          ? math.sin(
                                  rotation.value *
                                      configuration!.prizes.length *
                                      math.pi *
                                      2,
                                ) *
                                .11
                          : 0,
                      child: child,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Text(
          loading
              ? 'Loading your reward wheel…'
              : spinning
              ? 'SPINNING'
              : result == null
              ? 'SPIN TO REVEAL'
              : 'RESULT CONFIRMED',
          style: BambooFonts.ui(
            10.5,
            weight: FontWeight.w700,
            color: spinning ? BambooInk.lime : BambooInk.onSlateSubtle,
          ).copyWith(letterSpacing: 1.3),
        ),
      ],
    ),
  );
}

class _PrizeWheelPainter extends CustomPainter {
  const _PrizeWheelPainter(this.configuration, this.rotation);

  final SpinConfiguration configuration;
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 3;
    final bounds = Rect.fromCircle(center: center, radius: radius);
    final sectors = equalSpinWheelSectors(configuration);
    final outline = Paint()
      ..color = BambooInk.lime
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (var index = 0; index < sectors.length; index++) {
      final sector = sectors[index];
      final prize = sector.prize;
      final sweep = sector.sweepAngle;
      final start = sector.startAngle + rotation;
      final fill = Paint()
        ..color = index.isEven ? BambooInk.slateRaised : BambooInk.slateLow
        ..style = PaintingStyle.fill;
      canvas.drawArc(bounds, start, sweep, true, fill);
      canvas.drawArc(
        bounds,
        start,
        sweep,
        true,
        Paint()
          ..color = BambooInk.slate.withValues(alpha: .82)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );

      final mid = start + sweep / 2;
      final labelPosition = Offset(
        center.dx + math.cos(mid) * radius * .70,
        center.dy + math.sin(mid) * radius * .70,
      );
      final label = TextPainter(
        text: TextSpan(
          text: prize.amount.inr,
          style: BambooFonts.money(sweep < .50 ? 8 : 10, color: BambooInk.lime),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 58);
      var labelAngle = (mid + math.pi / 2 + math.pi) % (math.pi * 2) - math.pi;
      if (labelAngle > math.pi / 2) labelAngle -= math.pi;
      if (labelAngle < -math.pi / 2) labelAngle += math.pi;
      canvas.save();
      canvas.translate(labelPosition.dx, labelPosition.dy);
      canvas.rotate(labelAngle);
      label.paint(canvas, Offset(-label.width / 2, -label.height / 2));
      canvas.restore();
    }
    canvas.drawCircle(center, radius, outline);
  }

  @override
  bool shouldRepaint(covariant _PrizeWheelPainter oldDelegate) =>
      oldDelegate.configuration != configuration ||
      oldDelegate.rotation != rotation;
}
