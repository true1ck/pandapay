import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'app_theme.dart';
import 'merchant_brand.dart';
import 'merchant_brand_tile.dart';
import 'party_avatar.dart';

@Preview(name: 'Merchant marks', group: 'Bamboo Ink', size: Size(300, 360))
Widget merchantBrandPreview() => Material(
  color: BambooInk.paper,
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A brand logo in its colour, a person, a shop with no logo of its own,
        // a card, and a brand whose artwork is black (neutral tile).
        for (final (name, fallback) in [
          ('Swiggy', AvatarKind.business),
          ('Flipkart', AvatarKind.business),
          ('Blinkit', AvatarKind.business),
          ('Uber', AvatarKind.business),
          ('Local store', AvatarKind.business),
          ('Transfer to Ramesh', AvatarKind.person),
          ('HDFC card bill', AvatarKind.card),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                MerchantBrandTile(
                  brand: fallback == AvatarKind.business
                      ? MerchantBrand.forName(name)
                      : null,
                  fallback: PartyAvatar(fallback),
                ),
                const SizedBox(width: 12),
                Text(name, style: const TextStyle(color: BambooInk.ink900)),
              ],
            ),
          ),
        const Material(
          color: BambooInk.slate,
          borderRadius: BorderRadius.all(Radius.circular(12)),
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Row(
              children: [
                MerchantBrandTile(brand: MerchantBrand.spotify, onSlate: true),
                SizedBox(width: 12),
                Text('Spotify', style: TextStyle(color: BambooInk.onSlate)),
              ],
            ),
          ),
        ),
      ],
    ),
  ),
);
