import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons_weights.dart'
    show LucideIcons300;

/// Every icon the money screens draw, from one minimal outline family (Lucide,
/// light stroke), named for what it means rather than what it looks like.
///
/// A screen asks for `AppIcons.bank`, never for a glyph, so the whole app
/// changes together and two screens can never draw the same thing two ways.
/// Colour is not decided here: see `AvatarKind` and `TintedIconTile`.
abstract final class AppIcons {
  // People and places.
  static const IconData person = LucideIcons300.userRound;
  static const IconData business = LucideIcons300.store;

  // Where money lives.
  static const IconData card = LucideIcons300.creditCard;
  static const IconData bank = LucideIcons300.landmark;
  static const IconData wallet = LucideIcons300.wallet;
  static const IconData cash = LucideIcons300.banknote;

  // What money is doing.
  static const IconData bill = LucideIcons300.receipt;
  static const IconData subscription = LucideIcons300.repeat;
  static const IconData paused = LucideIcons300.pause;
  static const IconData ended = LucideIcons300.history;
  static const IconData transfer = LucideIcons300.arrowLeftRight;
  static const IconData moneyIn = LucideIcons300.arrowDownLeft;
  static const IconData moneyOut = LucideIcons300.arrowUpRight;
  static const IconData investment = LucideIcons300.trendingUp;
  static const IconData refund = LucideIcons300.undo2;
  static const IconData reversal = LucideIcons300.rotateCcw;
  static const IconData ignored = LucideIcons300.ban;

  // Tags.
  static const IconData tag = LucideIcons300.tag;

  // Spending categories.
  static const IconData dining = LucideIcons300.utensils;
  static const IconData fuel = LucideIcons300.fuel;
  static const IconData shopping = LucideIcons300.shoppingBag;
  static const IconData travel = LucideIcons300.plane;
  static const IconData grocery = LucideIcons300.shoppingBasket;
  static const IconData home = LucideIcons300.house;
  static const IconData education = LucideIcons300.graduationCap;
  static const IconData health = LucideIcons300.heartPulse;
  static const IconData entertainment = LucideIcons300.clapperboard;
  static const IconData otherCategory = LucideIcons300.shapes;
}
