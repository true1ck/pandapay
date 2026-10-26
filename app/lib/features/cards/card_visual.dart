import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../data/user_cards_repository.dart';

/// Stable, inspectable output of the generated card-skin resolver. The
/// preview/diagnostic screen uses this without duplicating the visual rules.
class CardVisualSpec {
  final String family;
  final String skin;
  final Color primary;
  final Color secondary;

  const CardVisualSpec({
    required this.family,
    required this.skin,
    required this.primary,
    required this.secondary,
  });
}

CardVisualSpec cardVisualSpecFor(CardProduct product) {
  final skin = _skinFor(product);
  final palette = _paletteFor(product, skin);
  return CardVisualSpec(
    family: _visualFamily(product).name,
    skin: skin.name,
    primary: palette.primary,
    secondary: palette.secondary,
  );
}

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
  final UserCard? userCard;
  final Money? cycleSpend;
  final TransactionEntry? latestSpend;
  final double? width;
  final double? height;
  final int? effectiveBillingDay;
  final int? effectiveDueDay;

  const CardVisual({
    super.key,
    required this.product,
    this.showProductName = true,
    this.userCard,
    this.cycleSpend,
    this.latestSpend,
    this.width,
    this.height,
    this.effectiveBillingDay,
    this.effectiveDueDay,
  });

  @override
  Widget build(BuildContext context) {
    // Card colour is always derived from the catalogue product/issuer. There
    // is intentionally no neutral/silver override: the same HDFC, Axis,
    // Kotak, etc. palette must follow the card everywhere in the app.
    final skin = _skinFor(product);
    final palette = _paletteFor(product, skin);
    final seed = _stableSeed('${product.id}:${product.name}');
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
                  painter: _CardSkinPainter(
                    color: palette.foreground.withValues(alpha: 0.16),
                    seed: seed,
                    skin: skin,
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
                                  value: _dayLabel(effectiveBillingDay ?? userCard!.statementDay),
                                  foreground: palette.foreground,
                                  muted: palette.foregroundMuted,
                                ),
                              ),
                              Expanded(
                                child: _CardDataPoint(
                                  label: 'DUE DAY',
                                  value: _dayLabel(effectiveDueDay ?? userCard!.dueDay),
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

enum _CardSkin {
  orbit,
  wave,
  grid,
  dots,
  prism,
  rings,
  diagonal,
  minimal,
}

enum _CardVisualFamily {
  coBranded,
  cashback,
  travel,
  premium,
  digital,
  debit,
  everyday,
}

_CardVisualFamily _visualFamily(CardProduct product) {
  final text = '${product.issuerName ?? ''} ${product.name}'.toLowerCase();
  final type = product.cardType?.toLowerCase() ?? '';

  if (type.contains('debit')) return _CardVisualFamily.debit;
  if (RegExp(
    r'amazon|flipkart|swiggy|tata\s+neu|airtel|indigo|ixigo|marriott|myntra|cleartrip|paytm|onecard|scapia',
  ).hasMatch(text)) {
    return _CardVisualFamily.coBranded;
  }
  if (RegExp(
    r'cashback|cash\s*back|moneyback|ace|simplyclick|sbi card cash',
  ).hasMatch(text)) {
    return _CardVisualFamily.cashback;
  }
  if (RegExp(
    r'travel|atlas|miles|vistara|flight|airport|voyage|scapia',
  ).hasMatch(text)) {
    return _CardVisualFamily.travel;
  }
  if (RegExp(
    r'infinite|signature|regalia|diners club|platinum|metal|reserve|elite',
  ).hasMatch(text)) {
    return _CardVisualFamily.premium;
  }
  if (RegExp(r'neo|coral|pay|upi|digital|virtual').hasMatch(text)) {
    return _CardVisualFamily.digital;
  }
  return _CardVisualFamily.everyday;
}

_CardSkin _skinFor(CardProduct product) {
  final text = '${product.issuerName ?? ''} ${product.name}'.toLowerCase();

  // A few recognisable families get a stable visual language. Everything
  // else is distributed across the remaining skins using the product id, so
  // two products from the same issuer do not all collapse into one template.
  if (text.contains('amazon')) return _CardSkin.diagonal;
  if (text.contains('swiggy')) return _CardSkin.dots;
  if (text.contains('tata neu')) return _CardSkin.wave;
  if (text.contains('moneyback')) return _CardSkin.prism;
  if (text.contains('amex') || text.contains('american express')) {
    return _CardSkin.rings;
  }

  final seed = _stableSeed('${product.id}:${product.name}');
  final familySkins = switch (_visualFamily(product)) {
    _CardVisualFamily.coBranded => const [
      _CardSkin.wave,
      _CardSkin.diagonal,
      _CardSkin.dots,
    ],
    _CardVisualFamily.cashback => const [
      _CardSkin.prism,
      _CardSkin.grid,
      _CardSkin.dots,
    ],
    _CardVisualFamily.travel => const [
      _CardSkin.rings,
      _CardSkin.orbit,
      _CardSkin.wave,
    ],
    _CardVisualFamily.premium => const [
      _CardSkin.minimal,
      _CardSkin.rings,
      _CardSkin.prism,
    ],
    _CardVisualFamily.digital => const [
      _CardSkin.grid,
      _CardSkin.diagonal,
      _CardSkin.wave,
    ],
    _CardVisualFamily.debit => const [
      _CardSkin.grid,
      _CardSkin.minimal,
      _CardSkin.dots,
    ],
    _CardVisualFamily.everyday => _CardSkin.values,
  };
  return familySkins[seed % familySkins.length];
}

_CardPalette _paletteFor(CardProduct product, _CardSkin skin) {
  final custom = _parseHexColor(product.artPrimaryColor);
  final text = '${product.issuerName ?? ''} ${product.name}'.toLowerCase();

  final seed = _stableSeed('${product.id}:${product.name}');
  final base = custom ?? _productBaseColor(product, text, seed);
  final secondary = _secondaryColor(base, seed, skin);
  final backgroundTone = Color.lerp(base, secondary, 0.42)!;
  final foreground = backgroundTone.computeLuminance() > 0.58
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

Color _productBaseColor(CardProduct product, String text, int seed) {
  // Product-specific colours take precedence over the issuer colour. These
  // are visual identifiers, not claims that the generated face is an exact
  // reproduction of the bank's current artwork.
  if (text.contains('tata neu')) return const Color(0xFF17856F);
  if (text.contains('moneyback')) return const Color(0xFF0B4778);
  if (text.contains('regalia')) return const Color(0xFF343A46);
  if (text.contains('millennia')) return const Color(0xFF8E2345);
  if (text.contains('amazon')) return const Color(0xFF173D67);
  if (text.contains('swiggy')) return const Color(0xFFE75D4F);

  final issuer = _issuerBaseColor(text);
  final familyBase = switch (_visualFamily(product)) {
    _CardVisualFamily.coBranded => const Color(0xFF168A78),
    _CardVisualFamily.cashback => const Color(0xFFB24A3A),
    _CardVisualFamily.travel => const Color(0xFF145A78),
    _CardVisualFamily.premium => const Color(0xFF343A46),
    _CardVisualFamily.digital => const Color(0xFF5B3A85),
    _CardVisualFamily.debit => const Color(0xFF26705B),
    _CardVisualFamily.everyday => const Color(0xFF3F4C8A),
  };
  final variants = [
    familyBase,
    const Color(0xFF146C94),
    const Color(0xFF6A3A69),
    const Color(0xFF247A68),
    const Color(0xFF9A5C2E),
    const Color(0xFF343B70),
    const Color(0xFF7B304C),
  ];
  return Color.lerp(issuer, variants[seed % variants.length], 0.48)!;
}

Color _secondaryColor(Color base, int seed, _CardSkin skin) {
  final accents = <Color>[
    const Color(0xFF071B33),
    const Color(0xFF0C5E67),
    const Color(0xFF44235F),
    const Color(0xFF8E3B37),
    const Color(0xFFBE8C29),
    const Color(0xFF202A4C),
    Colors.black,
    const Color(0xFF3A493F),
  ];
  final accent = accents[(seed + skin.index) % accents.length];
  final amount = switch (skin) {
    _CardSkin.minimal => 0.16,
    _CardSkin.prism => 0.34,
    _ => 0.28,
  };
  return Color.lerp(base, accent, amount)!;
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

Color _issuerBaseColor(String text) {
  if (text.contains('icici')) return const Color(0xFF8E2345);
  if (text.contains('hdfc')) return const Color(0xFF0B4778);
  if (text.contains('sbi')) return const Color(0xFF07508E);
  if (text.contains('axis')) return const Color(0xFF5B1A49);
  if (text.contains('kotak')) return const Color(0xFFA82332);
  if (text.contains('amex') || text.contains('american express')) {
    return const Color(0xFF0864AE);
  }
  return _fallbackColors[_stableSeed(text) % _fallbackColors.length];
}

/// String.hashCode is not a suitable visual identity key: its implementation
/// is allowed to change between Dart versions. This small stable hash keeps a
/// product's generated skin consistent across app versions and platforms.
int _stableSeed(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
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

class _CardSkinPainter extends CustomPainter {
  final Color color;
  final int seed;
  final _CardSkin skin;

  const _CardSkinPainter({
    required this.color,
    required this.seed,
    required this.skin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final shift = (seed % 38).toDouble();

    switch (skin) {
      case _CardSkin.orbit:
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
      case _CardSkin.wave:
        final path = Path();
        for (var row = 0; row < 4; row++) {
          final y = size.height * (0.18 + row * 0.22);
          path.moveTo(-10, y);
          path.cubicTo(
            size.width * 0.25,
            y - 20,
            size.width * 0.48,
            y + 20,
            size.width + 10,
            y - 8,
          );
        }
        canvas.drawPath(path, paint);
      case _CardSkin.grid:
        for (var x = -1; x < 9; x++) {
          final dx = x * size.width / 7 + shift / 3;
          canvas.drawLine(Offset(dx, 0), Offset(dx + size.height, size.height), paint);
        }
        for (var y = -1; y < 6; y++) {
          final dy = y * size.height / 4;
          canvas.drawLine(Offset(0, dy), Offset(size.width, dy + size.width * 0.18), paint);
        }
      case _CardSkin.dots:
        final dotPaint = Paint()..color = color..style = PaintingStyle.fill;
        for (var row = 0; row < 5; row++) {
          for (var column = 0; column < 9; column++) {
            final dx = column * size.width / 8 + (row.isEven ? 8 : 0);
            final dy = row * size.height / 4.2 + size.height * 0.04;
            canvas.drawCircle(
              Offset(dx, dy),
              1.5 + ((seed + row + column) % 3) * 0.45,
              dotPaint,
            );
          }
        }
      case _CardSkin.prism:
        final path = Path()
          ..moveTo(-10, size.height * 0.82)
          ..lineTo(size.width * 0.35, -10)
          ..lineTo(size.width * 0.7, -10)
          ..lineTo(size.width * 0.22, size.height + 10)
          ..close();
        canvas.drawPath(path, paint);
        canvas.drawLine(
          Offset(size.width * 0.55, -10),
          Offset(size.width + 10, size.height * 0.7),
          paint,
        );
        canvas.drawLine(
          Offset(size.width * 0.72, -10),
          Offset(size.width + 10, size.height * 0.48),
          paint,
        );
      case _CardSkin.rings:
        for (var i = 0; i < 4; i++) {
          canvas.drawCircle(
            Offset(size.width * 0.86, size.height * 0.48),
            size.height * (0.25 + i * 0.16),
            paint,
          );
        }
      case _CardSkin.diagonal:
        for (var i = -2; i < 9; i++) {
          final x = i * size.width / 6 + shift / 4;
          canvas.drawLine(
            Offset(x, size.height + 12),
            Offset(x + size.height * 0.95, -12),
            paint,
          );
        }
      case _CardSkin.minimal:
        final accentPaint = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        canvas.drawOval(
          Rect.fromLTWH(
            size.width * 0.62,
            -size.height * 0.35,
            size.width * 0.8,
            size.height * 1.5,
          ),
          accentPaint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _CardSkinPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.seed != seed ||
      oldDelegate.skin != skin;
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

/// A miniature credit card visual intended for compact lists, table rows,
/// and due bill tiles (e.g. 50x32px), rendering the card's distinctive
/// skin, palette, mini chip, contactless mark, and last4 / network mark.
class MiniCardVisual extends StatelessWidget {
  final CardProduct? product;
  final UserCard? userCard;
  final double width;
  final double height;
  final double borderRadius;

  const MiniCardVisual({
    super.key,
    this.product,
    this.userCard,
    this.width = 50,
    this.height = 32,
    this.borderRadius = 6,
  });

  @override
  Widget build(BuildContext context) {
    final (skin, palette, seed, network, last4) = _resolveVisualProps();

    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [palette.primary, palette.secondary],
            ),
            boxShadow: [
              BoxShadow(
                color: palette.primary.withValues(alpha: 0.28),
                blurRadius: 4,
                offset: const Offset(0, 1.5),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _CardSkinPainter(
                  color: palette.foreground.withValues(alpha: 0.16),
                  seed: seed,
                  skin: skin,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3.5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Top row: mini chip + issuer/network mark
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          width: 8,
                          height: 5.5,
                          decoration: BoxDecoration(
                            color: palette.chip,
                            borderRadius: BorderRadius.circular(1),
                            border: Border.all(
                              color: palette.chipInk.withValues(alpha: 0.35),
                              width: 0.5,
                            ),
                          ),
                        ),
                        _buildNetworkOrIssuerMark(network, palette.foreground),
                      ],
                    ),
                    // Bottom row: last4 + contactless
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Flexible(
                          child: Text(
                            last4 != null && last4.isNotEmpty
                                ? '•• $last4'
                                : '••••',
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: BambooFonts.ui(
                              6.5,
                              weight: FontWeight.w700,
                              color: palette.foreground.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                        Icon(
                          Icons.contactless_rounded,
                          size: 7.5,
                          color: palette.foreground.withValues(alpha: 0.85),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetworkOrIssuerMark(CardNetwork network, Color color) {
    if (network == CardNetwork.mastercard) {
      return SizedBox(
        width: 14,
        height: 8,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFE44D45),
                ),
              ),
            ),
            Positioned(
              right: 0,
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFF3C548),
                ),
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
      _ => null,
    };
    if (label != null) {
      return Text(
        label,
        style: BambooFonts.ui(
          6,
          weight: FontWeight.w800,
          color: color,
        ),
      );
    }
    final isHdfc = (userCard?.cardName.toLowerCase().contains('hdfc') == true) ||
        (product?.issuerName?.toLowerCase().contains('hdfc') == true);
    if (isHdfc) {
      return Text(
        'HDFC',
        style: BambooFonts.ui(
          6,
          weight: FontWeight.w800,
          color: color,
        ),
      );
    }
    return Icon(
      Icons.credit_card_rounded,
      size: 7.5,
      color: color.withValues(alpha: 0.8),
    );
  }

  (_CardSkin, _CardPalette, int, CardNetwork, String?) _resolveVisualProps() {
    if (product != null) {
      final p = product!;
      final skin = _skinFor(p);
      final palette = _paletteFor(p, skin);
      final seed = _stableSeed('${p.id}:${p.name}');
      return (skin, palette, seed, p.network, userCard?.last4);
    }
    final name = (userCard?.nickname?.trim().isNotEmpty == true
            ? userCard!.nickname
            : userCard?.cardName) ??
        'Card';
    final text = name.toLowerCase();
    final seed = _stableSeed('${userCard?.id ?? name}:$name');
    final base = _issuerBaseColor(text);
    final skin = _CardSkin.values[seed % _CardSkin.values.length];
    final secondary = _secondaryColor(base, seed, skin);
    final backgroundTone = Color.lerp(base, secondary, 0.42)!;
    final foreground = backgroundTone.computeLuminance() > 0.58
        ? BambooInk.ink900
        : Colors.white;
    final palette = _CardPalette(
      primary: base,
      secondary: secondary,
      chip: base.computeLuminance() > 0.58
          ? const Color(0xFFD8A83E)
          : const Color(0xFFE6C46A),
      chipInk: const Color(0xFF6D4E16),
      foreground: foreground,
      foregroundMuted: foreground.withValues(alpha: 0.72),
    );
    final network = text.contains('visa')
        ? CardNetwork.visa
        : text.contains('master')
        ? CardNetwork.mastercard
        : text.contains('rupay')
        ? CardNetwork.rupay
        : text.contains('amex')
        ? CardNetwork.amex
        : CardNetwork.unknown;
    return (skin, palette, seed, network, userCard?.last4);
  }
}
