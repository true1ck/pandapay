import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

/// The card-shaped viewfinder drawn over the live camera preview in the
/// OCR scan flow — what the user asked for as "a silhouette on top so the
/// user knows how to scan their card."
///
/// Two things this deliberately gets right:
///
/// 1. **The aspect ratio is ID-1 (CR-80), 85.60mm × 53.98mm** — the actual
///    physical dimensions of every bank card ever issued (ISO/IEC 7810).
///    A generic rounded rectangle would look plausible but train the user
///    to frame the card slightly wrong; this ratio (1.586:1) is what a
///    real card looks like from any distance, so "fill the guide" is
///    correct guidance rather than an approximation.
/// 2. **The surround is dimmed, not the guide** — same visual grammar as
///    every QR/document scanner (including this app's own QR path):
///    darken everything OUTSIDE the shape so the eye is pulled to where
///    the card goes, rather than drawing a border on an otherwise-equal
///    bright frame.
class CardGuidePainter extends CustomPainter {
  /// 0.0-1.0 pulse used for the "hold steady" breathing animation on the
  /// guide border while waiting for a capture.
  final double pulse;

  const CardGuidePainter({this.pulse = 0});

  static const double _aspectRatio = 85.60 / 53.98; // ID-1/CR-80, width:height

  @override
  void paint(Canvas canvas, Size size) {
    final guideWidth = size.width * 0.84;
    final guideHeight = guideWidth / _aspectRatio;
    final guideRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: guideWidth,
      height: guideHeight,
    );
    final guideRRect = RRect.fromRectAndRadius(guideRect, const Radius.circular(14));

    // Dim everything outside the card shape via even-odd fill — the
    // standard "punch a hole in an overlay" technique, cheaper and more
    // reliable across platforms than a BackdropFilter blur here.
    final overlayPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(guideRRect);
    canvas.drawPath(overlayPath, Paint()..color = Colors.black.withValues(alpha: 0.55));

    // The guide border itself, with a subtle brightness pulse so a
    // motionless frame still reads as "live," not "frozen."
    final borderOpacity = 0.7 + (0.3 * pulse);
    canvas.drawRRect(
      guideRRect,
      Paint()
        ..color = BambooInk.lime.withValues(alpha: borderOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Four corner accents, drawn brighter than the border — the same
    // "brackets read as a target" language as the QR scanner's own corner
    // brackets, scaled to the card shape instead of a square.
    final cornerLen = guideHeight * 0.16;
    final cornerPaint = Paint()
      ..color = BambooInk.lime
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    void corner(Offset origin, Offset dx, Offset dy) {
      canvas.drawLine(origin, origin + dx, cornerPaint);
      canvas.drawLine(origin, origin + dy, cornerPaint);
    }

    final r = guideRect;
    corner(r.topLeft, Offset(cornerLen, 0), Offset(0, cornerLen));
    corner(r.topRight, Offset(-cornerLen, 0), Offset(0, cornerLen));
    corner(r.bottomLeft, Offset(cornerLen, 0), Offset(0, -cornerLen));
    corner(r.bottomRight, Offset(-cornerLen, 0), Offset(0, -cornerLen));
  }

  @override
  bool shouldRepaint(covariant CardGuidePainter oldDelegate) => oldDelegate.pulse != pulse;
}
