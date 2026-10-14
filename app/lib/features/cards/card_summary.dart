import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import 'card_visual.dart';

/// The shared card surface used by Wallet and every card-centric insight.
/// Keeping the surface here prevents each screen from slowly growing a
/// slightly different border, radius, shadow, and padding treatment.
class CardSummaryPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final bool elevated;

  const CardSummaryPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.lg),
    this.margin,
    this.elevated = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: BambooInk.ink900.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      padding: padding,
      child: child,
    );
  }
}

/// A consistent identity row: recognisable card silhouette, concise name,
/// optional supporting line, status content, and one trailing action.
///
/// The same row is intentionally used for a card in Wallet, a points
/// programme, a cap group, and an individual benefit. Users can therefore
/// identify a card by its artwork before reading any text.
class CardSummaryHeader extends StatelessWidget {
  final CardProduct product;
  final String title;
  final String? subtitle;
  final Widget? footer;
  final Widget? trailing;
  final IconData? badgeIcon;
  final double visualWidth;

  const CardSummaryHeader({
    super.key,
    required this.product,
    required this.title,
    this.subtitle,
    this.footer,
    this.trailing,
    this.badgeIcon,
    this.visualWidth = 98,
  });

  @override
  Widget build(BuildContext context) {
    final visual = SizedBox(
      width: visualWidth,
      child: CardVisual(product: product, showProductName: false),
    );
    final decoratedVisual = badgeIcon == null
        ? visual
        : SizedBox(
            width: visualWidth + 10,
            height: visualWidth * 0.62 + 6,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(left: 0, top: 5, child: visual),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 29,
                    height: 29,
                    decoration: BoxDecoration(
                      color: BambooInk.slate,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: BambooInk.paper),
                    ),
                    child: Icon(badgeIcon, size: 16, color: BambooInk.lime),
                  ),
                ),
              ],
            ),
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        decoratedVisual,
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: BambooFonts.heading(15, color: BambooInk.ink900),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (footer != null) ...[
                const SizedBox(height: AppSpace.xs),
                footer!,
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpace.sm),
          trailing!,
        ],
      ],
    );
  }
}

/// A small, reusable status pill for card summaries.
class CardSummaryPill extends StatelessWidget {
  final String label;
  final Color foreground;
  final Color background;

  const CardSummaryPill({
    super.key,
    required this.label,
    this.foreground = BambooInk.ink900,
    this.background = BambooInk.paperMuted,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Text(
      label,
      style: BambooFonts.ui(11.5, weight: FontWeight.w600, color: foreground),
    ),
  );
}
