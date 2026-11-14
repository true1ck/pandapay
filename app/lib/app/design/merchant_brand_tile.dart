import 'package:flutter/material.dart';

import 'merchant_brand.dart';
import 'merchant_brand_colors.dart';
import 'tile_tones.dart';

/// A decorative mark alongside the merchant's existing text label: the brand's
/// logo in the brand's colour on a soft tint of it. A brand whose artwork is
/// black or white gets a neutral tile. Each screen supplies its usual icon (a
/// `PartyAvatar`) when there is no known brand.
class MerchantBrandTile extends StatelessWidget {
  const MerchantBrandTile({
    super.key,
    required this.brand,
    this.fallback,
    this.size = 40,
    this.onSlate = false,
  });

  final MerchantBrand? brand;
  final Widget? fallback;
  final double size;
  final bool onSlate;

  @override
  Widget build(BuildContext context) {
    final mark = brand;
    if (mark == null) return fallback ?? const SizedBox.shrink();

    final tones = TileTones.of(context, mark.color, onSlate: onSlate);

    return Image.asset(
      mark.asset,
      width: size * 0.76,
      height: size * 0.54,
      fit: BoxFit.contain,
      color: tones.mark,
      colorBlendMode: BlendMode.srcIn,
      excludeFromSemantics: true,
      frameBuilder: (context, image, _, _) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tones.background,
          border: Border.all(color: tones.border),
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: image,
      ),
      errorBuilder: (context, error, stackTrace) =>
          fallback ?? const SizedBox.shrink(),
    );
  }
}
