import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The three colours of a small logo or icon tile: a soft tint of one hue, a
/// hairline in the same hue, and the mark itself.
///
/// One place decides them, so a brand logo, a person, a shop and an account
/// all sit in the same kind of tile. A colour that would be hard to read is
/// darkened (or lightened on dark surfaces) until it is; a very light colour
/// such as Blinkit's yellow becomes a solid tile with a dark mark instead.
@immutable
class TileTones {
  const TileTones({
    required this.background,
    required this.border,
    required this.mark,
  });

  final Color background;
  final Color border;
  final Color mark;

  /// [tone] null means a neutral tile in the app's own ink, for artwork that is
  /// black or white.
  factory TileTones.of(
    BuildContext context,
    Color? tone, {
    bool onSlate = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final (base, ink, hairline) = onSlate
        ? (BambooInk.slateRaised, BambooInk.onSlate, BambooInk.slateHairline)
        : dark
        ? (scheme.surfaceContainerHigh, scheme.onSurface, scheme.outlineVariant)
        : (BambooInk.paper, BambooInk.ink900, BambooInk.hairlineOnPaper);

    if (tone == null) {
      return TileTones(
        background: onSlate || dark ? base : BambooInk.paperMuted,
        border: hairline,
        mark: ink,
      );
    }

    final light = !dark && !onSlate;
    if (light && tone.computeLuminance() > 0.45) {
      // Too pale to read as a mark on its own tint: let the brand colour be the
      // tile, the way the brand does.
      return TileTones(
        background: tone,
        border: Color.lerp(tone, Colors.black, 0.12)!,
        mark: BambooInk.ink900,
      );
    }

    final tint = light ? 0.12 : (onSlate ? 0.18 : 0.22);
    final background = Color.alphaBlend(tone.withValues(alpha: tint), base);
    return TileTones(
      background: background,
      border: Color.alphaBlend(
        tone.withValues(alpha: light ? 0.24 : 0.32),
        onSlate ? BambooInk.slateHairline : base,
      ),
      mark: _readable(
        tone,
        background,
        min: light ? 3.2 : 4.0,
        lighten: !light,
      ),
    );
  }
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
}

Color _readable(
  Color tone,
  Color background, {
  required double min,
  required bool lighten,
}) {
  var colour = tone;
  for (var step = 1; step <= 9 && _contrast(colour, background) < min; step++) {
    colour = Color.lerp(
      tone,
      lighten ? Colors.white : Colors.black,
      step / 10,
    )!;
  }
  return colour;
}
