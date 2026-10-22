import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../data/spend_reports_repository.dart';
import '../cards/card_visual.dart';
import '../insights/spending_visuals.dart';

const _ink = Color(0xFF171C2A);
const _muted = Color(0xFF737987);
const _green = Color(0xFF005C37);
const _line = Color(0xFFE7EBF0);

TextStyle _type(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color color = _ink,
}) => BambooFonts.ui(size, weight: weight, color: color).copyWith(height: 1.15);

List<SpendBreakdownRow> _categories(SpendReport? report) =>
    (report?.byCategory ?? const <SpendBreakdownRow>[])
        .where((row) => row.total.paise > 0)
        .toList();

String _amount(Money? money) =>
    (money ?? Money.zero()).format(compact: true, hidePaise: true);
String _share(SpendBreakdownRow row, int total) =>
    '${total > 0 ? (row.total.paise * 100 / total).round() : 0}%';

class WidgetBrandMark extends StatelessWidget {
  const WidgetBrandMark({super.key});

  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/logo/pandapay_mark.png', fit: BoxFit.contain);
}

/// Both the ring width and its typography scale with the diameter. In
/// particular, resizing never turns the donut into a thin outline or a tiny
/// label surrounded by an oversized hole.
class WidgetSpendChart extends StatelessWidget {
  const WidgetSpendChart({super.key, required this.report, this.size = 144});

  final SpendReport? report;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        CustomPaint(
          size: Size.square(size),
          painter: _WidgetSpendChartPainter(_categories(report)),
        ),
        SizedBox(
          width: size * .66,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _amount(report?.spend.total),
                  style: BambooFonts.money(size * .137, color: _ink),
                ),
              ),
              SizedBox(height: size * .015),
              Text('spent', style: _type(size * .078, color: _muted)),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The approved composition: rewards in the header, a substantial donut next
/// to aligned category rows, and a blue recommendation panel below. Every
/// measurement follows the available canvas instead of fixed miniature caps.
class WidgetExpandedDetails extends StatelessWidget {
  const WidgetExpandedDetails({
    super.key,
    required this.report,
    required this.recommendation,
    this.showRecommendation = true,
    this.canvasSize = const Size(320, 320),
  });

  final SpendReport? report;
  final Recommendation? recommendation;
  final bool showRecommendation;
  final Size canvasSize;

  @override
  Widget build(BuildContext context) {
    final rows = _categories(report);
    final rec = recommendation?.isExcluded == false ? recommendation : null;
    final wide = canvasSize.aspectRatio >= 1.6;
    final inset = canvasSize.width * (wide ? .025 : .022);
    final gap = canvasSize.width * (wide ? .014 : .018);
    final headerHeight = wide
        ? canvasSize.height * .13
        : canvasSize.width * .105;
    final panelHeight = wide
        ? canvasSize.height * .28
        : math.min(canvasSize.width * .42, canvasSize.height * .30);

    return SizedBox.fromSize(
      size: canvasSize,
      child: ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: EdgeInsets.all(inset),
          child: Column(
            children: [
              SizedBox(
                height: headerHeight,
                child: _Header(report: report, compact: false),
              ),
              SizedBox(height: gap),
              Expanded(
                child: Container(
                  padding: EdgeInsets.all(canvasSize.width * .015),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(
                      canvasSize.width * .035,
                    ),
                    border: Border.all(color: const Color(0xFFF3F5F8)),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF192B48).withValues(alpha: .035),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final diameter = math.min(
                        constraints.maxHeight * .97,
                        constraints.maxWidth * (wide ? .27 : .425),
                      );
                      return Row(
                        children: [
                          WidgetSpendChart(report: report, size: diameter),
                          SizedBox(width: canvasSize.width * .024),
                          Expanded(
                            child: rows.isEmpty
                                ? Text(
                                    'Add a transaction to see your categories',
                                    style: _type(
                                      canvasSize.width * .03,
                                      color: _muted,
                                    ),
                                  )
                                : wide
                                ? _CategoryGrid(
                                    rows: rows,
                                    total: report?.spend.total.paise ?? 0,
                                  )
                                : _CategoryList(
                                    rows: rows,
                                    total: report?.spend.total.paise ?? 0,
                                    fontSize: math.min(
                                      canvasSize.width * .030,
                                      constraints.maxHeight / rows.length * .62,
                                    ),
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              if (showRecommendation) ...[
                SizedBox(height: gap),
                SizedBox(
                  height: panelHeight,
                  child: _RecommendationPanel(recommendation: rec, wide: wide),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The small widget is a summary of the same design. Resizing up reveals all
/// categories; it never scales an entire expanded screen down into a stamp.
class WidgetCompactDetails extends StatelessWidget {
  const WidgetCompactDetails({
    super.key,
    required this.report,
    required this.recommendation,
    this.showRecommendation = true,
    this.canvasSize = const Size(200, 220),
  });

  final SpendReport? report;
  final Recommendation? recommendation;
  final bool showRecommendation;
  final Size canvasSize;

  @override
  Widget build(BuildContext context) {
    final rows = _categories(report);
    final wide = canvasSize.aspectRatio > 1.5;
    final rec = recommendation?.isExcluded == false ? recommendation : null;
    return SizedBox.fromSize(
      size: canvasSize,
      child: ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Column(
            children: [
              const SizedBox(height: 1),
              SizedBox(
                height: 25,
                child: _Header(report: report, compact: true),
              ),
              const SizedBox(height: 5),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final diameter = math.min(
                      constraints.maxHeight - 2,
                      constraints.maxWidth * (wide ? .29 : .51),
                    );
                    return Row(
                      children: [
                        WidgetSpendChart(report: report, size: diameter),
                        const SizedBox(width: 8),
                        Expanded(
                          child: rows.isEmpty
                              ? Text(
                                  'Your spending at a glance',
                                  style: _type(10, color: _muted),
                                )
                              : _CategoryList(
                                  rows: rows.take(wide ? 3 : 2).toList(),
                                  total: report?.spend.total.paise ?? 0,
                                  fontSize: wide ? 10 : 8.5,
                                  stacked: !wide,
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (showRecommendation) ...[
                const SizedBox(height: 7),
                SizedBox(
                  height: wide ? 42 : 54,
                  child: _RecommendationPanel(
                    recommendation: rec,
                    wide: true,
                    compact: true,
                  ),
                ),
              ] else if (!wide && rows.length > 2) ...[
                const SizedBox(height: 5),
                SizedBox(
                  height: 38,
                  child: _CategoryGrid(
                    rows: rows.skip(2).take(2).toList(),
                    total: report?.spend.total.paise ?? 0,
                    columns: 2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.report, required this.compact});
  final SpendReport? report;
  final bool compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = compact ? 8.2 : constraints.maxHeight * .34;
      final markSize = constraints.maxHeight * .78;
      return Row(
        children: [
          SizedBox.square(dimension: markSize, child: const WidgetBrandMark()),
          SizedBox(width: compact ? 4 : 8),
          Expanded(
            child: Text(
              (report?.displayLabel ?? 'This month').toUpperCase(),
              maxLines: 1,
              style: _type(size, weight: FontWeight.w700, color: _muted),
            ),
          ),
          const SizedBox(width: 4),
          _RewardPill(
            value: (report?.spend.rewards ?? Money.zero()).format(
              compact: true,
            ),
            fontSize: size,
            label: compact ? null : 'Rewards',
            earned: false,
          ),
        ],
      );
    },
  );
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.rows,
    required this.total,
    required this.fontSize,
    this.stacked = false,
  });
  final List<SpendBreakdownRow> rows;
  final int total;
  final double fontSize;
  final bool stacked;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < rows.length; i++)
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: i == rows.length - 1
                  ? null
                  : const Border(bottom: BorderSide(color: _line, width: .5)),
            ),
            child: Row(
              children: [
                _CategoryDot(label: rows[i].label, size: fontSize * .91),
                SizedBox(width: fontSize * .5),
                Expanded(
                  child: stacked
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              rows[i].label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _type(fontSize),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${_amount(rows[i].total)} · ${_share(rows[i], total)}',
                              maxLines: 1,
                              style: _type(
                                fontSize + 1,
                                weight: FontWeight.w700,
                              ),
                            ),
                          ],
                        )
                      : FittedBox(
                          alignment: Alignment.centerLeft,
                          fit: BoxFit.scaleDown,
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: '${rows[i].label} · '),
                                TextSpan(
                                  text: _share(rows[i], total),
                                  style: const TextStyle(color: _muted),
                                ),
                              ],
                            ),
                            style: _type(fontSize),
                          ),
                        ),
                ),
                if (!stacked) ...[
                  SizedBox(width: fontSize * .8),
                  Text(
                    _amount(rows[i].total),
                    maxLines: 1,
                    style: BambooFonts.money(fontSize * 1.05, color: _ink),
                  ),
                  SizedBox(width: fontSize * .25),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: fontSize * 1.25,
                    color: const Color(0xFF9BA0AA),
                  ),
                ],
              ],
            ),
          ),
        ),
    ],
  );
}

class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({
    required this.rows,
    required this.total,
    this.columns = 3,
  });
  final List<SpendBreakdownRow> rows;
  final int total;
  final int columns;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final count = (rows.length / columns).ceil();
      if (count == 0) return const SizedBox.shrink();
      final font = math.min(
        13.0,
        math.min(
          constraints.maxHeight / count * .29,
          constraints.maxWidth / columns * .079,
        ),
      );
      return Column(
        children: [
          for (var y = 0; y < count; y++)
            Expanded(
              child: Row(
                children: [
                  for (var x = 0; x < columns; x++)
                    Expanded(
                      child: y * columns + x >= rows.length
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: font * .4,
                              ),
                              child: Row(
                                children: [
                                  _CategoryDot(
                                    label: rows[y * columns + x].label,
                                    size: font * .8,
                                  ),
                                  SizedBox(width: font * .4),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            '${rows[y * columns + x].label} · ${_share(rows[y * columns + x], total)}',
                                            style: _type(font),
                                          ),
                                        ),
                                        SizedBox(height: font * .25),
                                        Text(
                                          _amount(rows[y * columns + x].total),
                                          style: BambooFonts.money(
                                            font,
                                            color: _muted,
                                          ),
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
        ],
      );
    },
  );
}

class _CategoryDot extends StatelessWidget {
  const _CategoryDot({required this.label, required this.size});
  final String label;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: spendingCategoryVisual(label).accent,
      shape: BoxShape.circle,
    ),
  );
}

class _RecommendationPanel extends StatelessWidget {
  const _RecommendationPanel({
    required this.recommendation,
    required this.wide,
    this.compact = false,
  });
  final Recommendation? recommendation;
  final bool wide;
  final bool compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = constraints.maxHeight;
      final shallow = height < width * .33;
      final padding = compact
          ? 5.0
          : wide
          ? height * .09
          : width * .024;
      final artWidth = compact
          ? height * 1.05
          : wide
          ? height * 1.38
          : math.min(width * .435, (height - padding * 2) * 1.586);
      final nameSize = compact
          ? 9.0
          : wide
          ? height * .22
          : width * .049;
      final copySize = compact
          ? 7.0
          : wide
          ? height * .14
          : width * .033;
      final rewardSize = compact
          ? 8.0
          : wide
          ? height * .20
          : width * .038;
      return Container(
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFF1F8FF), Color(0xFFEDF5FF)],
          ),
          borderRadius: BorderRadius.circular(compact ? 10 : width * .04),
        ),
        child: recommendation == null
            ? Center(
                child: Text(
                  'Add a card to get your best pick',
                  style: _type(nameSize, color: _muted),
                ),
              )
            : Row(
                children: [
                  SizedBox(
                    width: artWidth,
                    height: artWidth / 1.586,
                    child: WidgetCardArt(product: recommendation!.card),
                  ),
                  SizedBox(width: compact ? 6 : width * .034),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!compact && !wide && !shallow) ...[
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: width * .017,
                              vertical: width * .010,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCEAFE),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'RECOMMENDED FOR YOU',
                              maxLines: 1,
                              style: _type(
                                width * .020,
                                weight: FontWeight.w700,
                                color: const Color(0xFF0648BA),
                              ),
                            ),
                          ),
                          SizedBox(height: width * .020),
                        ],
                        FittedBox(
                          alignment: Alignment.centerLeft,
                          fit: BoxFit.scaleDown,
                          child: Text(
                            recommendation!.card.name,
                            maxLines: 1,
                            style: _type(nameSize, weight: FontWeight.w700),
                          ),
                        ),
                        if (!compact && (!shallow || wide)) ...[
                          SizedBox(height: width * .01),
                          Text(
                            wide
                                ? 'Best card for your spending'
                                : 'Get rewarded on your\ndaily spends',
                            maxLines: 2,
                            style: _type(
                              copySize,
                              color: const Color(0xFF596273),
                            ),
                          ),
                        ],
                        if (!wide || compact) ...[
                          SizedBox(height: compact ? 2 : width * .025),
                          _RewardPill(
                            value: _amount(recommendation!.expectedValue),
                            fontSize: rewardSize,
                            label: 'Earn',
                            earned: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (wide && !compact) ...[
                    const SizedBox(width: 8),
                    _RewardPill(
                      value: _amount(recommendation!.expectedValue),
                      fontSize: rewardSize,
                      label: 'Earn',
                      earned: true,
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: rewardSize * 1.5,
                      color: _muted,
                    ),
                  ],
                ],
              ),
      );
    },
  );
}

class _RewardPill extends StatelessWidget {
  const _RewardPill({
    required this.value,
    required this.fontSize,
    required this.label,
    required this.earned,
  });
  final String value;
  final double fontSize;
  final String? label;
  final bool earned;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: fontSize * .8,
      vertical: fontSize * .55,
    ),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFFEAFDD9), Color(0xFFF0FDE5)],
      ),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.card_giftcard_rounded, size: fontSize * 1.25, color: _green),
        SizedBox(width: fontSize * .45),
        if (label != null) ...[
          Text(
            label!,
            style: _type(
              fontSize,
              weight: earned ? FontWeight.w700 : FontWeight.w500,
              color: _green,
            ),
          ),
          if (!earned)
            Container(
              width: .6,
              height: fontSize,
              margin: EdgeInsets.symmetric(horizontal: fontSize * .5),
              color: const Color(0xFFB5D7A5),
            )
          else
            SizedBox(width: fontSize * .3),
        ],
        Text(value, style: BambooFonts.money(fontSize * 1.05, color: _green)),
        if (earned && fontSize > 10) ...[
          SizedBox(width: fontSize * .3),
          Icon(
            Icons.chevron_right_rounded,
            size: fontSize * 1.3,
            color: _green,
          ),
        ],
      ],
    ),
  );
}

class WidgetExpandedSpendingDetails extends StatelessWidget {
  const WidgetExpandedSpendingDetails({
    super.key,
    required this.report,
    this.canvasSize = const Size(280, 420),
  });
  final SpendReport? report;
  final Size canvasSize;
  @override
  Widget build(BuildContext context) => WidgetExpandedDetails(
    report: report,
    recommendation: null,
    showRecommendation: false,
    canvasSize: canvasSize,
  );
}

/// Card artwork stays horizontal at every size. Millennia uses the blue face
/// in the approved design; issuer, product and network labels come from the
/// actual recommended product.
class WidgetCardArt extends StatelessWidget {
  const WidgetCardArt({
    super.key,
    required this.product,
    this.width = 180,
    this.height = 108,
  });
  final CardProduct product;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 180,
        height: 113.5,
        child: product.name.toLowerCase().contains('millennia')
            ? _MillenniaFace(product: product)
            : Theme(
                data: AppTheme.light(),
                child: CardVisual(
                  product: product,
                  width: 180,
                  height: 113.5,
                  showProductName: true,
                ),
              ),
      ),
    ),
  );
}

class _MillenniaFace extends StatelessWidget {
  const _MillenniaFace({required this.product});
  final CardProduct product;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(9),
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF092545), Color(0xFF126ACC)],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _CardGridPainter())),
          Positioned(
            top: 13,
            left: 13,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 1),
              ),
              child: Text(
                (product.issuerName ?? 'HDFC Bank').toUpperCase(),
                style: _type(8, weight: FontWeight.w700, color: Colors.white),
              ),
            ),
          ),
          const Positioned(
            top: 13,
            right: 12,
            child: Icon(
              Icons.contactless_rounded,
              color: Colors.white,
              size: 19,
            ),
          ),
          Positioned(
            top: 48,
            left: 16,
            child: Container(
              width: 22,
              height: 17,
              decoration: BoxDecoration(
                color: const Color(0xFFDFC896),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: const Color(0xFFB09B70)),
              ),
              child: const Center(
                child: Icon(
                  Icons.grid_view_rounded,
                  color: Color(0xFFB09B70),
                  size: 16,
                ),
              ),
            ),
          ),
          Positioned(
            top: 54,
            left: 49,
            child: Text(
              'M I L L E N N I A',
              style: _type(9, weight: FontWeight.w600, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: 12,
            right: 12,
            child: Text(
              product.network.name.toUpperCase(),
              style: _type(
                13,
                weight: FontWeight.w800,
                color: Colors.white,
              ).copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CardGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .045)
      ..strokeWidth = .5;
    for (double x = -size.height; x < size.width + size.height; x += 12) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(x, 0),
        Offset(x - size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CardGridPainter oldDelegate) => false;
}

class _WidgetSpendChartPainter extends CustomPainter {
  const _WidgetSpendChartPainter(this.rows);
  final List<SpendBreakdownRow> rows;
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * .12;
    final rect = (Offset.zero & size).deflate(stroke / 2 + .5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      paint..color = BambooChartColors.chartTrack,
    );
    final total = rows.fold<int>(0, (sum, row) => sum + row.total.paise);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (final row in rows) {
      final sweep = math.pi * 2 * row.total.paise / total;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        paint..color = spendingCategoryVisual(row.label).accent,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _WidgetSpendChartPainter oldDelegate) =>
      oldDelegate.rows != rows;
}
