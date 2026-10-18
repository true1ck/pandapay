import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

/// Illustrative examples are deliberately separate from imported user data.
class SmsPermissionArtwork extends StatelessWidget {
  const SmsPermissionArtwork({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: 240,
      child: FittedBox(
        child: MediaQuery.withNoTextScaling(
          child: SizedBox(
            width: 350,
            height: 300,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 28,
                  top: 16,
                  child: Container(
                    width: 280,
                    height: 260,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF1F8E9),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: Image.asset(
                    'assets/illustrations/panda_mail.png',
                    width: 150,
                    height: 150,
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 32,
                  width: 229,
                  child: Transform.rotate(
                    angle: -.055,
                    child: _ArtCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _ArtEyebrow('EXAMPLE BANK ALERT'),
                          const SizedBox(height: 9),
                          Row(
                            children: [
                              const _ArtIcon(Icons.sms_outlined),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  '₹1,250 spent at a café',
                                  style: BambooFonts.ui(
                                    13,
                                    weight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 9),
                          Text(
                            'Card ending ••42',
                            style: BambooFonts.ui(11, color: BambooInk.ink700),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Positioned(
                  left: 76,
                  top: 145,
                  child: Icon(
                    Icons.south_rounded,
                    size: 24,
                    color: BambooInk.jade,
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 5,
                  child: _ArtCard(
                    child: Row(
                      children: [
                        const SpendingDonut(size: 99),
                        const SizedBox(width: 19),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _ArtEyebrow('YOUR MONTH, ORGANIZED'),
                              const SizedBox(height: 8),
                              Text(
                                'A clearer picture.',
                                style: BambooFonts.heading(
                                  17,
                                  weight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 11),
                              const _Legend('Food & drinks', Color(0xFF12805C)),
                              const SizedBox(height: 5),
                              const _Legend('Shopping', Color(0xFFB4DA72)),
                              const SizedBox(height: 5),
                              const _Legend(
                                'Everything else',
                                Color(0xFFF0C5A2),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class ImportPermissionArtwork extends StatelessWidget {
  final bool complete;
  const ImportPermissionArtwork({super.key, required this.complete});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: 240,
      child: Center(
        child: SizedBox(
          width: 260,
          height: 240,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 213,
                height: 213,
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F8E9),
                  shape: BoxShape.circle,
                ),
              ),
              if (!complete)
                SizedBox(
                  width: 220,
                  height: 220,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: BambooInk.jade.withValues(alpha: .6),
                    backgroundColor: const Color(0xFFE6F0DB),
                  ),
                ),
              Image.asset(
                'assets/illustrations/panda_mail.png',
                width: 190,
                height: 190,
              ),
              const Positioned(
                left: 0,
                top: 30,
                child: _ArtBadge(Icons.sms_outlined),
              ),
              const Positioned(
                right: 0,
                bottom: 30,
                child: _ArtBadge(Icons.donut_large_rounded),
              ),
              if (complete)
                const Positioned(
                  right: 25,
                  top: 20,
                  child: _ArtBadge(Icons.check_rounded, filled: true),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ReminderPermissionArtwork extends StatelessWidget {
  const ReminderPermissionArtwork({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: 90,
      child: FittedBox(
        child: MediaQuery.withNoTextScaling(
          child: SizedBox(
            width: 350,
            height: 118,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 16,
                  width: 260,
                  child: _ArtCard(
                    child: Row(
                      children: [
                        const _ArtIcon(Icons.notifications_active_outlined),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _ArtEyebrow('EXAMPLE REMINDER'),
                              const SizedBox(height: 5),
                              Text(
                                'A little nudge. Right on time.',
                                style: BambooFonts.ui(
                                  12,
                                  weight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Image.asset(
                    'assets/illustrations/panda_peek.png',
                    width: 105,
                    height: 105,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class SpendingDonut extends StatelessWidget {
  final double size;
  const SpendingDonut({super.key, this.size = 100});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: const _DonutPainter(),
      child: const Center(
        child: Icon(Icons.insights_rounded, color: BambooInk.jade, size: 26),
      ),
    ),
  );
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * .13;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    var start = -math.pi / 2;
    for (final (fraction, color) in const [
      (.43, Color(0xFF12805C)),
      (.34, Color(0xFFB4DA72)),
      (.23, Color(0xFFF0C5A2)),
    ]) {
      final sweep = fraction * math.pi * 2;
      canvas.drawArc(
        rect,
        start + .04,
        sweep - .08,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) => false;
}

class _ArtCard extends StatelessWidget {
  final Widget child;
  const _ArtCard({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(21),
      border: Border.all(color: const Color(0xFFE6EADC)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0C21442A),
          blurRadius: 22,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: child,
  );
}

class _ArtEyebrow extends StatelessWidget {
  final String text;
  const _ArtEyebrow(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: BambooFonts.ui(
      8.5,
      color: BambooInk.ink700,
      weight: FontWeight.w600,
    ).copyWith(letterSpacing: 1),
  );
}

class _Legend extends StatelessWidget {
  final String label;
  final Color color;
  const _Legend(this.label, this.color);
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: BambooFonts.ui(10, color: BambooInk.ink700)),
    ],
  );
}

class _ArtIcon extends StatelessWidget {
  final IconData icon;
  const _ArtIcon(this.icon);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: const Color(0xFFF0F7E8),
      borderRadius: BorderRadius.circular(11),
    ),
    child: Icon(icon, size: 19, color: BambooInk.jade),
  );
}

class _ArtBadge extends StatelessWidget {
  final IconData icon;
  final bool filled;
  const _ArtBadge(this.icon, {this.filled = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: filled ? BambooInk.jade : Colors.white,
      shape: BoxShape.circle,
      border: Border.all(color: const Color(0xFFE2ECD8)),
    ),
    child: Icon(icon, size: 23, color: filled ? Colors.white : BambooInk.jade),
  );
}
