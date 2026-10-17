import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../data/user_cards_repository.dart';

/// A recognisable, catalogue-driven card face used wherever PandaPay shows a
/// card. Catalogue art is optional, so the fallback is deliberately generated
/// from issuer, product and network data instead of showing a generic icon.
///
/// This is not intended to reproduce an issuer's exact artwork or logo. It is
/// a quick visual identifier: the same product always gets the same palette,
/// network mark, chip and pattern across Home, Wallet and card detail screens.
class CardVisual extends StatelessWidget {
  final CardProduct product;
  final bool showProductName;
  final bool silver;
  final UserCard? userCard;
  final Money? cycleSpend;
  final TransactionEntry? latestSpend;
  final double? width;
  final double? height;

  const CardVisual({
    super.key,
    required this.product,
    this.showProductName = true,
    this.silver = false,
    this.userCard,
    this.cycleSpend,
    this.latestSpend,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _paletteFor(product, silver: silver);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Picker rows and capability headers intentionally use a tiny card
        // face. Hide text at that size so the network mark never overflows.
        // A parent such as ListTile may tighten the child's final width
        // after this widget receives its explicit size. Treat an explicitly
        // small card as compact too, otherwise the full header row can
        // overflow before the constraint reaches the card face.
        final compact =
            (width != null && width! < 132) ||
            (height != null && height! < 96) ||
            constraints.maxWidth < 132;
        final detailed = !compact && userCard != null;
        final card = ClipRRect(
          borderRadius: BorderRadius.circular(compact ? 12 : 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette.primary, palette.secondary],
              ),
              boxShadow: [
                BoxShadow(
                  color: palette.primary.withValues(alpha: 0.24),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _CardPatternPainter(
                    color: palette.foreground.withValues(alpha: 0.16),
                    seed: product.id.hashCode.abs(),
                  ),
                ),
                if (compact) ...[
                  Positioned(
                    top: 6,
                    left: 8,
                    child: _CardChip(
                      gold: palette.chip,
                      foreground: palette.chipInk,
                      small: true,
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 7,
                    child: _NetworkMark(
                      network: product.network,
                      color: palette.foreground,
                      small: true,
                    ),
                  ),
                ] else if (detailed) ...[
                  Positioned(
                    top: 16,
                    left: 20,
                    right: 20,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _issuerLabel(product),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(
                              12,
                              weight: FontWeight.w800,
                              color: palette.foreground,
                            ).copyWith(letterSpacing: 1.25),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _NetworkMark(
                          network: product.network,
                          color: palette.foreground,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 38,
                    left: 20,
                    right: 20,
                    child: Text(
                      (userCard!.nickname?.trim().isNotEmpty == true
                              ? userCard!.nickname
                              : product.name)!
                          .toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        10,
                        weight: FontWeight.w600,
                        color: palette.foregroundMuted,
                      ).copyWith(letterSpacing: 0.7),
                    ),
                  ),
                  Positioned(
                    top: 62,
                    left: 20,
                    child: _CardChip(
                      gold: palette.chip,
                      foreground: palette.chipInk,
                    ),
                  ),
                  Positioned(
                    top: 93,
                    left: 20,
                    right: 20,
                    child: Text(
                      _maskedNumber(userCard!.last4),
                      maxLines: 1,
                      style: BambooFonts.ui(
                        17,
                        weight: FontWeight.w600,
                        color: palette.foreground,
                      ).copyWith(letterSpacing: 2.2),
                    ),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 12,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Row(
                            children: [
                              Expanded(
                                child: _CardDataPoint(
                                  label: 'BILLING DAY',
                                  value: _dayLabel(userCard!.statementDay),
                                  foreground: palette.foreground,
                                  muted: palette.foregroundMuted,
                                ),
                              ),
                              Expanded(
                                child: _CardDataPoint(
                                  label: 'DUE DAY',
                                  value: _dayLabel(userCard!.dueDay),
                                  foreground: palette.foreground,
                                  muted: palette.foregroundMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (cycleSpend != null) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: _CardDataPoint(
                              label: 'SPENT THIS CYCLE',
                              value: cycleSpend!.format(hidePaise: true),
                              foreground: palette.foreground,
                              muted: palette.foregroundMuted,
                              alignEnd: true,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (latestSpend != null)
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 2,
                      child: Text(
                        'Latest ${_latestSpendLabel(latestSpend!)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: BambooFonts.ui(
                          8.5,
                          weight: FontWeight.w600,
                          color: palette.foregroundMuted,
                        ),
                      ),
                    ),
                ] else ...[
                  Positioned(
                    top: 11,
                    left: 15,
                    right: 15,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _issuerLabel(product),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(
                              11,
                              weight: FontWeight.w700,
                              color: palette.foreground,
                            ).copyWith(letterSpacing: 1.1),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _NetworkMark(
                          network: product.network,
                          color: palette.foreground,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 15,
                    top: 40,
                    child: _CardChip(
                      gold: palette.chip,
                      foreground: palette.chipInk,
                    ),
                  ),
                  if (showProductName)
                    Positioned(
                      left: 15,
                      right: 15,
                      bottom: 11,
                      child: Row(
                        children: [
                          Expanded(
                            child: FittedBox(
                              alignment: Alignment.centerLeft,
                              fit: BoxFit.scaleDown,
                              child: Text(
                                product.name.toUpperCase(),
                                maxLines: 1,
                                style: BambooFonts.ui(
                                  11,
                                  weight: FontWeight.w700,
                                  color: palette.foreground,
                                ).copyWith(letterSpacing: 0.55),
                              ),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Icon(
                            Icons.contactless_rounded,
                            size: 18,
                            color: palette.foreground.withValues(alpha: 0.9),
                          ),
                        ],
                      ),
                    )
                  else
                    Positioned(
                      right: 15,
                      bottom: 11,
                      child: Icon(
                        Icons.contactless_rounded,
                        size: 18,
                        color: palette.foreground.withValues(alpha: 0.9),
                      ),
                    ),
                ],
              ],
            ),
          ),
        );

        final sized = width != null || height != null
            ? SizedBox(width: width, height: height, child: card)
            : AspectRatio(aspectRatio: 1.586, child: card);

        return Semantics(
          label: '${product.name} card visual',
          image: true,
          child: sized,
        );
      },
    );
  }
}

class _CardPalette {
  final Color primary;
  final Color secondary;
  final Color chip;
  final Color chipInk;
  final Color foreground;
  final Color foregroundMuted;

  const _CardPalette({
    required this.primary,
    required this.secondary,
    required this.chip,
    required this.chipInk,
    required this.foreground,
    required this.foregroundMuted,
  });
}

_CardPalette _paletteFor(CardProduct product, {bool silver = false}) {
  if (silver) {
    return const _CardPalette(
      primary: Color(0xFFF0F2F4),
      secondary: Color(0xFF9FA7B0),
      chip: Color(0xFFD8A83E),
      chipInk: Color(0xFF6D4E16),
      foreground: Color(0xFF20262D),
      foregroundMuted: Color(0xFF5D6873),
    );
  }

  final custom = _parseHexColor(product.artPrimaryColor);
  final text = '${product.issuerName ?? ''} ${product.name}'.toLowerCase();

  final base = custom ?? _issuerBaseColor(text, product.id);
  final secondary = Color.lerp(base, Colors.black, 0.28)!;
  final foreground = base.computeLuminance() > 0.58
      ? BambooInk.ink900
      : Colors.white;

  return _CardPalette(
    primary: base,
    secondary: secondary,
    chip: base.computeLuminance() > 0.58
        ? const Color(0xFFD8A83E)
        : const Color(0xFFE6C46A),
    chipInk: const Color(0xFF6D4E16),
    foreground: foreground,
    foregroundMuted: foreground.withValues(alpha: 0.72),
  );
}

class _CardDataPoint extends StatelessWidget {
  final String label;
  final String value;
  final Color foreground;
  final Color muted;
  final bool alignEnd;

  const _CardDataPoint({
    required this.label,
    required this.value,
    required this.foreground,
    required this.muted,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: alignEnd
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: BambooFonts.ui(
          8,
          weight: FontWeight.w700,
          color: muted,
        ).copyWith(letterSpacing: 0.8),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: alignEnd ? TextAlign.end : TextAlign.start,
        style: BambooFonts.ui(11, weight: FontWeight.w700, color: foreground),
      ),
    ],
  );
}

String _maskedNumber(String? last4) {
  final suffix = last4?.trim();
  return suffix == null || suffix.isEmpty
      ? '••••  ••••  ••••  ••••'
      : '••••  ••••  ••••  $suffix';
}

String _dayLabel(int? day) {
  if (day == null) return 'Not set';
  final suffix = switch (day % 100) {
    11 || 12 || 13 => 'th',
    _ => switch (day % 10) {
      1 => 'st',
      2 => 'nd',
      3 => 'rd',
      _ => 'th',
    },
  };
  return '$day$suffix monthly';
}

String _latestSpendLabel(TransactionEntry transaction) {
  final local = transaction.occurredAt.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '${transaction.amount.format(hidePaise: true)} · ${local.day} ${_monthShort(local.month)} · $hour:$minute $period';
}

String _monthShort(int month) => const [
  '',
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month.clamp(1, 12).toInt()];

Color _issuerBaseColor(String text, String productId) {
  if (text.contains('swiggy')) return const Color(0xFFE75D4F);
  if (text.contains('icici')) return const Color(0xFF8E2345);
  if (text.contains('hdfc')) return const Color(0xFF0B4778);
  if (text.contains('sbi')) return const Color(0xFF07508E);
  if (text.contains('axis')) return const Color(0xFF5B1A49);
  if (text.contains('kotak')) return const Color(0xFFA82332);
  if (text.contains('amex') || text.contains('american express')) {
    return const Color(0xFF0864AE);
  }
  if (text.contains('amazon')) return const Color(0xFF173D67);
  return _fallbackColors[productId.hashCode.abs() % _fallbackColors.length];
}

const _fallbackColors = [
  Color(0xFF2B313A),
  Color(0xFF0E6670),
  Color(0xFF3F4C8A),
  Color(0xFF6A3A69),
  Color(0xFF315E48),
];

Color? _parseHexColor(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  var value = raw.trim().replaceFirst('#', '');
  if (value.startsWith('0x')) value = value.substring(2);
  if (value.length == 6) value = 'FF$value';
  if (value.length != 8) return null;
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? null : Color(parsed);
}

String _issuerLabel(CardProduct product) {
  final text = '${product.issuerName ?? ''} ${product.name}'.toLowerCase();
  if (text.contains('swiggy')) return 'SWIGGY';
  if (text.contains('icici')) return 'ICICI BANK';
  if (text.contains('hdfc')) return 'HDFC BANK';
  if (text.contains('sbi')) return 'SBI CARD';
  if (text.contains('axis')) return 'AXIS BANK';
  if (text.contains('kotak')) return 'KOTAK';
  final issuer = product.issuerName?.trim();
  if (issuer != null && issuer.isNotEmpty) return issuer.toUpperCase();
  return product.name.toUpperCase();
}

class _CardChip extends StatelessWidget {
  final Color gold;
  final Color foreground;
  final bool small;

  const _CardChip({
    required this.gold,
    required this.foreground,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: small ? 21 : 30,
      height: small ? 15 : 22,
      decoration: BoxDecoration(
        color: gold,
        borderRadius: BorderRadius.circular(small ? 4 : 5),
        border: Border.all(color: foreground.withValues(alpha: 0.18)),
      ),
      child: CustomPaint(
        painter: _ChipPainter(color: foreground.withValues(alpha: 0.45)),
      ),
    );
  }
}

class _NetworkMark extends StatelessWidget {
  final CardNetwork network;
  final Color color;
  final bool small;

  const _NetworkMark({
    required this.network,
    required this.color,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    if (network == CardNetwork.mastercard) {
      return SizedBox(
        width: small ? 23 : 34,
        height: small ? 12 : 18,
        child: Stack(
          children: [
            Positioned(
              left: 1,
              child: _NetworkCircle(
                color: const Color(0xFFE44D45),
                small: small,
              ),
            ),
            Positioned(
              right: 1,
              child: _NetworkCircle(
                color: const Color(0xFFF3C548),
                small: small,
              ),
            ),
          ],
        ),
      );
    }
    final label = switch (network) {
      CardNetwork.visa => 'VISA',
      CardNetwork.rupay => 'RuPay',
      CardNetwork.amex => 'AMEX',
      CardNetwork.diners => 'DINERS',
      CardNetwork.unknown => 'CARD',
      CardNetwork.mastercard => 'MC',
    };
    return Text(
      label,
      style: BambooFonts.ui(
        small ? 6.5 : 9,
        weight: FontWeight.w800,
        color: color,
      ),
    );
  }
}

class _NetworkCircle extends StatelessWidget {
  final Color color;
  final bool small;
  const _NetworkCircle({required this.color, this.small = false});

  @override
  Widget build(BuildContext context) => Container(
    width: small ? 11 : 17,
    height: small ? 11 : 17,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color.withValues(alpha: 0.92),
      border: Border.all(color: Colors.white.withValues(alpha: 0.34)),
    ),
  );
}

class _CardPatternPainter extends CustomPainter {
  final Color color;
  final int seed;

  const _CardPatternPainter({required this.color, required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final shift = (seed % 38).toDouble();
    canvas.drawCircle(
      Offset(size.width * 0.88, size.height * 0.2),
      size.height * 0.62,
      paint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.96 + shift / 5, size.height * 0.42),
      size.height * 0.4,
      paint,
    );
    canvas.drawLine(
      Offset(-20 + shift, size.height * 0.82),
      Offset(size.width * 0.58 + shift, -10),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CardPatternPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.seed != seed;
}

class _ChipPainter extends CustomPainter {
  final Color color;
  const _ChipPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(4, 4, size.width - 8, size.height - 8),
        const Radius.circular(2),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ChipPainter oldDelegate) =>
      oldDelegate.color != color;
}
