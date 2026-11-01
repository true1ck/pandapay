import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';

enum MonthCoverage { imported, partial, missing, importing, waiting, future }

class HistoryMonth {
  final DateTime start;
  final DateTime end;
  final MonthCoverage status;
  const HistoryMonth(this.start, this.end, this.status);

  String get label => DateFormat('MMMM yyyy').format(start);
  bool get canImport =>
      status == MonthCoverage.missing || status == MonthCoverage.partial;
}

/// The last [count] months (local time), oldest first, with how much of each
/// is imported. [coverage] is every imported range; [jobWindows] are the
/// active import's windows, used to mark months being imported or waiting.
List<HistoryMonth> buildHistoryMonths({
  required DateTime now,
  required List<(DateTime, DateTime)> coverage,
  List<Map<String, Object?>> jobWindows = const [],
  int count = 24,
}) {
  final months = <HistoryMonth>[];
  for (var i = count - 1; i >= 0; i--) {
    final start = DateTime(now.year, now.month - i);
    final end = DateTime(start.year, start.month + 1);
    if (start.isAfter(now)) {
      months.add(HistoryMonth(start, end, MonthCoverage.future));
      continue;
    }
    final until = end.isAfter(now) ? now : end;
    var covered = Duration.zero;
    for (final (s, e) in coverage) {
      final from = s.isAfter(start) ? s : start;
      final to = e.isBefore(until) ? e : until;
      if (to.isAfter(from)) covered += to.difference(from);
    }
    final missing = until.difference(start) - covered;
    // The current month is "imported" when the gap is just today's newest
    // messages, which the daily check picks up.
    final tolerance = end.isAfter(now)
        ? const Duration(days: 1)
        : const Duration(hours: 1);
    MonthCoverage status;
    if (missing <= tolerance) {
      status = MonthCoverage.imported;
    } else {
      status = covered > Duration.zero
          ? MonthCoverage.partial
          : MonthCoverage.missing;
    }
    if (status != MonthCoverage.imported) {
      for (final window in jobWindows) {
        final ws = DateTime.tryParse(window['start'] as String? ?? '');
        final we = DateTime.tryParse(window['end'] as String? ?? '');
        if (ws == null || we == null) continue;
        if (!(ws.isBefore(until) && we.isAfter(start))) continue;
        final state = window['state'];
        if (const ['waiting', 'running', 'finished'].contains(state)) {
          status = MonthCoverage.importing;
          break;
        }
        if (state == 'queued' || state == 'partial') {
          status = MonthCoverage.waiting;
        }
      }
    }
    months.add(HistoryMonth(start, end, status));
  }
  return months;
}

/// A compact calendar strip: one row per year, one cell per month.
class HistoryCoverageStrip extends StatelessWidget {
  final List<HistoryMonth> months;
  final void Function(HistoryMonth month) onTap;
  const HistoryCoverageStrip({
    super.key,
    required this.months,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (months.isEmpty) return const SizedBox.shrink();
    final byYear = <int, Map<int, HistoryMonth>>{};
    for (final month in months) {
      (byYear[month.start.year] ??= {})[month.start.month] = month;
    }
    const initials = [
      'J',
      'F',
      'M',
      'A',
      'M',
      'J',
      'J',
      'A',
      'S',
      'O',
      'N',
      'D',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(width: 40),
            for (final letter in initials)
              Expanded(
                child: Text(
                  letter,
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(10.5, color: BambooInk.ink500),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (final MapEntry(key: year, value: cells) in byYear.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    '$year',
                    style: BambooFonts.ui(
                      12,
                      color: BambooInk.ink700,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                for (var m = 1; m <= 12; m++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: cells[m] == null
                          ? const SizedBox(height: 26)
                          : _Cell(month: cells[m]!, onTap: onTap),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpace.sm),
        const Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.xs,
          children: [
            _Legend(MonthCoverage.imported, 'Imported'),
            _Legend(MonthCoverage.partial, 'Partly'),
            _Legend(MonthCoverage.missing, 'Not imported'),
            _Legend(MonthCoverage.importing, 'Importing'),
          ],
        ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  final HistoryMonth month;
  final void Function(HistoryMonth month) onTap;
  const _Cell({required this.month, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final future = month.status == MonthCoverage.future;
    return Semantics(
      button: !future,
      label: '${month.label}: ${coverageLabel(month.status)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: future ? null : () => onTap(month),
        child: SizedBox(height: 26, child: _Swatch(status: month.status)),
      ),
    );
  }
}

String coverageLabel(MonthCoverage status) => switch (status) {
  MonthCoverage.imported => 'Imported',
  MonthCoverage.partial => 'Partly imported',
  MonthCoverage.missing => 'Not imported',
  MonthCoverage.importing => 'Importing now',
  MonthCoverage.waiting => 'Waiting in this import',
  MonthCoverage.future => 'Not yet',
};

class _Swatch extends StatelessWidget {
  final MonthCoverage status;
  final double size;
  const _Swatch({required this.status, this.size = double.infinity});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(6);
    Widget box(Color fill, {Color? border}) => Container(
      width: size,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: Border.all(color: border ?? fill, width: 1.2),
      ),
    );
    return switch (status) {
      MonthCoverage.imported => box(BambooInk.jade),
      MonthCoverage.importing => box(BambooInk.lime, border: BambooInk.slate),
      MonthCoverage.waiting => box(BambooInk.paper, border: BambooInk.ink500),
      MonthCoverage.missing => box(
        BambooInk.paper,
        border: BambooInk.hairlineOnPaper,
      ),
      MonthCoverage.future => box(Colors.transparent),
      MonthCoverage.partial => ClipRRect(
        borderRadius: radius,
        child: Container(
          width: size,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: BambooInk.jade, width: 1.2),
            gradient: const LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              stops: [0.5, 0.5],
              colors: [BambooInk.jade, BambooInk.paper],
            ),
          ),
        ),
      ),
    };
  }
}

class _Legend extends StatelessWidget {
  final MonthCoverage status;
  final String text;
  const _Legend(this.status, this.text);

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(width: 12, height: 12, child: _Swatch(status: status, size: 12)),
      const SizedBox(width: 6),
      Text(text, style: BambooFonts.ui(11.5, color: BambooInk.ink700)),
    ],
  );
}
