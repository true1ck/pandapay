import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'app_theme.dart';
import 'tile_tones.dart';

/// What a row's leading tile stands for when there is no brand logo.
///
/// One hue each, taken from the palette the charts already use, so a list reads
/// at a glance: people are violet, shops amber, cards indigo, accounts blue,
/// money in and out keep the jade and clay they have always had.
enum AvatarKind {
  /// A person: a P2P transfer, or money to or from family.
  person(AppIcons.person, BambooChartColors.violet),

  /// A business that has no logo of its own: a shop, a merchant, a company.
  business(AppIcons.business, BambooChartColors.amber),
  card(AppIcons.card, BambooChartColors.indigo),
  bank(AppIcons.bank, BambooChartColors.blue),
  wallet(AppIcons.wallet, BambooChartColors.teal),
  cash(AppIcons.cash, BambooChartColors.rose),

  /// A bill or a payment that is due.
  bill(AppIcons.bill, BambooChartColors.pink),

  /// A repeating payment, and its paused and ended states.
  subscription(AppIcons.subscription, BambooChartColors.teal),
  paused(AppIcons.paused, BambooChartColors.amber),
  ended(AppIcons.ended, BambooInk.ink500),

  /// Money moved between the person's own accounts.
  transfer(AppIcons.transfer, BambooChartColors.cyan),
  moneyIn(AppIcons.moneyIn, BambooInk.jade),
  moneyOut(AppIcons.moneyOut, BambooInk.clay),
  investment(AppIcons.investment, BambooInk.jade),
  refund(AppIcons.refund, BambooInk.jade),
  reversal(AppIcons.reversal, BambooInk.amber),
  ignored(AppIcons.ignored, BambooInk.ink500);

  const AvatarKind(this.icon, this.tone);

  final IconData icon;
  final Color tone;
}

/// The tile for an [AvatarKind]. Same size, radius and tint as a brand logo
/// tile, so the two sit together in one list.
class PartyAvatar extends StatelessWidget {
  const PartyAvatar(
    this.kind, {
    super.key,
    this.size = 40,
    this.onSlate = false,
  });

  final AvatarKind kind;
  final double size;
  final bool onSlate;

  @override
  Widget build(BuildContext context) =>
      TintedIconTile(kind.icon, kind.tone, size: size, onSlate: onSlate);
}

/// A line icon in a soft tint of one hue: the single tile every avatar,
/// category badge and tag uses. A hue that would be hard to read is darkened
/// (or lightened on dark surfaces) until it is; see [TileTones].
class TintedIconTile extends StatelessWidget {
  const TintedIconTile(
    this.icon,
    this.tone, {
    super.key,
    this.size = 40,
    this.onSlate = false,
  });

  final IconData icon;
  final Color tone;
  final double size;
  final bool onSlate;

  @override
  Widget build(BuildContext context) {
    final tones = TileTones.of(context, tone, onSlate: onSlate);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tones.background,
          border: Border.all(color: tones.border),
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Icon(icon, size: size * 0.5, color: tones.mark),
      ),
    );
  }
}
