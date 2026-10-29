import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/design/app_theme.dart';

/// Shared visual language for the account and first-run journey.
class EntryBackdrop extends StatelessWidget {
  final Widget child;
  final bool waves;

  const EntryBackdrop({super.key, required this.child, this.waves = true});

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
    child: Material(
      color: Colors.white,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(child: CustomPaint(painter: _EntryWashPainter(waves))),
          child,
        ],
      ),
    ),
  );
}

class _EntryWashPainter extends CustomPainter {
  final bool waves;
  const _EntryWashPainter(this.waves);

  @override
  void paint(Canvas canvas, Size size) {
    final glow = Paint()
      ..shader =
          const RadialGradient(
            colors: [Color(0xFFF1F9E4), Color(0x00F1F9E4)],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * .96, 0),
              radius: size.width * .7,
            ),
          );
    canvas.drawRect(Offset.zero & size, glow);
    if (!waves) return;
    final h = math.min(195.0, size.height * .26);
    final y = size.height - h;
    final first = Path()
      ..moveTo(0, y)
      ..cubicTo(
        size.width * .28,
        y + h * .15,
        size.width * .42,
        y + h,
        size.width,
        y + h * .32,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(first, Paint()..color = const Color(0xFFF1F9E7));
    final second = Path()
      ..moveTo(0, y + h * .48)
      ..cubicTo(
        size.width * .35,
        y + h * .25,
        size.width * .68,
        y + h * .95,
        size.width,
        y + h * .08,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(second, Paint()..color = const Color(0xFFE6F4D5));
    final third = Path()
      ..moveTo(0, size.height - h * .04)
      ..cubicTo(
        size.width * .27,
        size.height + h * .18,
        size.width * .58,
        y + h * .28,
        size.width,
        y + h * .62,
      )
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(third, Paint()..color = const Color(0xFFD5EDBA));
  }

  @override
  bool shouldRepaint(_EntryWashPainter oldDelegate) =>
      oldDelegate.waves != waves;
}

class PandaWordmark extends StatelessWidget {
  final double size;
  const PandaWordmark({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      text: 'Panda',
      children: const [
        TextSpan(
          text: 'Pay',
          style: TextStyle(color: Color(0xFF91C83F)),
        ),
      ],
    ),
    textAlign: TextAlign.center,
    textScaler: TextScaler.noScaling,
    style: BambooFonts.heading(size, weight: FontWeight.w800, height: 1),
  );
}

class EntryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool secondary;
  final bool loading;

  const EntryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.secondary = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(54)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      ),
      textStyle: WidgetStatePropertyAll(
        BambooFonts.ui(15, weight: FontWeight.w700),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (secondary) return Colors.white.withValues(alpha: .85);
        if (!states.contains(WidgetState.disabled)) return BambooInk.slate;
        // A busy button keeps its faded slate fill so the lime spinner stays
        // legible; an inert button (form not yet complete) reads as light so
        // "not ready yet" is obvious at a glance.
        return loading
            ? BambooInk.slate.withValues(alpha: .5)
            : BambooInk.ink900.withValues(alpha: .08);
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (secondary) return BambooInk.ink900;
        return states.contains(WidgetState.disabled) && !loading
            ? BambooInk.ink500
            : BambooInk.lime;
      }),
      side: WidgetStatePropertyAll(
        secondary
            ? const BorderSide(color: BambooInk.hairlineOnPaper)
            : BorderSide.none,
      ),
    );
    final content = loading
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: BambooInk.lime,
            ),
          )
        : Text(label, textAlign: TextAlign.center);
    return secondary
        ? OutlinedButton(
            onPressed: loading ? null : onPressed,
            style: style,
            child: content,
          )
        : FilledButton(
            onPressed: loading ? null : onPressed,
            style: style,
            child: content,
          );
  }
}

class EntryProgress extends StatelessWidget {
  final int step;
  const EntryProgress({super.key, required this.step});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step $step of 3',
    child: Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 1; i <= 3; i++) ...[
              if (i > 1)
                Container(width: 36, height: 2, color: const Color(0xFFE2E6DF)),
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: i <= step
                      ? const Color(0xFFA9DF46)
                      : const Color(0xFFDDE1DB),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Text('$step of 3', style: BambooFonts.ui(12, weight: FontWeight.w600)),
      ],
    ),
  );
}

class PandaIllustration extends StatelessWidget {
  final String asset;
  final double size;
  final bool halo;
  const PandaIllustration({
    super.key,
    this.asset = 'assets/logo/pandapay_mark.png',
    this.size = 220,
    this.halo = true,
  });

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        if (halo)
          Container(
            width: size * .94,
            height: size * .94,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0xFFEFF8E2), Color(0x00EFF8E2)],
              ),
            ),
          ),
        Image.asset(asset, fit: BoxFit.contain, excludeFromSemantics: true),
      ],
    ),
  );
}

/// The approved AI-generated footage exported as compact, cropped image
/// sequences. The source MP4 and its marked outer margins are not included in
/// the app.
class PandaStoryIllustration extends StatefulWidget {
  final bool spending;
  final bool playing;
  const PandaStoryIllustration({
    super.key,
    this.spending = false,
    this.playing = true,
  });

  @override
  State<PandaStoryIllustration> createState() => _PandaStoryIllustrationState();
}

class _PandaStoryIllustrationState extends State<PandaStoryIllustration> {
  Future<bool>? _ready;
  String get _asset => widget.spending
      ? 'assets/illustrations/panda_spending_story.webp'
      : 'assets/illustrations/panda_card_story.webp';

  @override
  void didUpdateWidget(PandaStoryIllustration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spending != widget.spending ||
        (!oldWidget.playing && widget.playing)) {
      _ready = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return const PandaIllustration();
    }
    // A completed one-shot animation can remain in Flutter's image cache.
    // Resolve a fresh stream when this scene is opened or replayed.
    _ready ??= AssetImage(_asset).evict();
    return TickerMode(
      enabled: widget.playing,
      child: FutureBuilder<bool>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox.shrink();
          }
          return Center(
            child: AspectRatio(
              aspectRatio: widget.spending ? 720 / 950 : 620 / 930,
              child: ShaderMask(
                shaderCallback: (rect) => const LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: [0, .14, .86, 1],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0, .09, .88, 1],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: Image.asset(
                    _asset,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
