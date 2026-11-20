import 'package:flutter/material.dart';

import 'app_theme.dart';

/// One calendar that picks a date range: tap the start day, then the end day.
///
/// Looks like the app's single-date calendar (slate header, month arrows,
/// slate day circles) so every date prompt reads as the same calendar. Flutter's
/// own `showDateRangePicker` is a different, full-screen scrolling layout, and
/// the stock month calendar has no range mode, hence this widget.
///
/// Tapping a day on or after the start sets the end; tapping before the start,
/// or after a finished range, starts a new range. Apply stays disabled until a
/// start day exists, and a lone start day applies as a one-day range.
Future<DateTimeRange?> showBambooDateRangeDialog({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTimeRange? initialRange,
  String helpText = 'Select dates',
  String confirmText = 'Apply',
}) {
  return showDialog<DateTimeRange>(
    context: context,
    builder: (_) => _RangeCalendar(
      firstDate: _dateOnly(firstDate),
      lastDate: _dateOnly(lastDate),
      initialRange: initialRange,
      helpText: helpText,
      confirmText: confirmText,
    ),
  );
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class _RangeCalendar extends StatefulWidget {
  const _RangeCalendar({
    required this.firstDate,
    required this.lastDate,
    required this.initialRange,
    required this.helpText,
    required this.confirmText,
  });

  final DateTime firstDate;
  final DateTime lastDate;
  final DateTimeRange? initialRange;
  final String helpText;
  final String confirmText;

  @override
  State<_RangeCalendar> createState() => _RangeCalendarState();
}

class _RangeCalendarState extends State<_RangeCalendar> {
  static const _rows = 6; // fixed, so the dialog never changes height
  static const _cell = 44.0;

  late DateTime? _start;
  late DateTime? _end;
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final r = widget.initialRange;
    _start = r == null ? null : _dateOnly(r.start);
    _end = r == null ? null : _dateOnly(r.end);
    final shown = _start ?? widget.lastDate;
    _month = DateTime(shown.year, shown.month);
  }

  bool _enabled(DateTime d) =>
      !d.isBefore(widget.firstDate) && !d.isAfter(widget.lastDate);

  void _tap(DateTime day) {
    setState(() {
      final start = _start;
      if (start == null || _end != null || day.isBefore(start)) {
        _start = day;
        _end = null;
      } else {
        _end = day;
      }
    });
  }

  bool get _canGoBack => DateTime(
    _month.year,
    _month.month,
  ).isAfter(DateTime(widget.firstDate.year, widget.firstDate.month));

  bool get _canGoForward => DateTime(
    _month.year,
    _month.month,
  ).isBefore(DateTime(widget.lastDate.year, widget.lastDate.month));

  void _page(int delta) =>
      setState(() => _month = DateTime(_month.year, _month.month + delta));

  String _headline(MaterialLocalizations l) {
    final s = _start;
    if (s == null) return 'Start date – End date';
    String f(DateTime d) => l.formatMediumDate(d);
    final e = _end;
    return e == null ? '${f(s)} – End date' : '${f(s)} – ${f(e)}';
  }

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    return Dialog(
      backgroundColor: BambooInk.paper,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(l),
            _monthBar(l),
            _weekdays(l),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _grid(l),
            ),
            _actions(l),
          ],
        ),
      ),
    );
  }

  Widget _header(MaterialLocalizations l) => Container(
    color: BambooInk.slate,
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.helpText,
          style: BambooFonts.ui(
            12.5,
            weight: FontWeight.w600,
            color: BambooInk.lime,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _headline(l),
          key: const Key('range-calendar-headline'),
          style: BambooFonts.heading(22, color: BambooInk.lime),
        ),
      ],
    ),
  );

  Widget _monthBar(MaterialLocalizations l) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
    child: Row(
      children: [
        IconButton(
          tooltip: l.previousMonthTooltip,
          onPressed: _canGoBack ? () => _page(-1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            l.formatMonthYear(_month),
            textAlign: TextAlign.center,
            style: BambooFonts.ui(
              14.5,
              weight: FontWeight.w600,
              color: BambooInk.ink900,
            ),
          ),
        ),
        IconButton(
          tooltip: l.nextMonthTooltip,
          onPressed: _canGoForward ? () => _page(1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );

  Widget _weekdays(MaterialLocalizations l) {
    final first = l.firstDayOfWeekIndex;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: SizedBox(
                height: 32,
                child: Center(
                  child: Text(
                    l.narrowWeekdays[(first + i) % 7],
                    style: BambooFonts.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: BambooInk.ink500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _grid(MaterialLocalizations l) {
    final days = DateUtils.getDaysInMonth(_month.year, _month.month);
    final offset = DateUtils.firstDayOffset(_month.year, _month.month, l);
    return Column(
      children: [
        for (var r = 0; r < _rows; r++)
          Row(
            children: [
              for (var c = 0; c < 7; c++)
                Expanded(child: _dayCell(l, r * 7 + c - offset + 1, days)),
            ],
          ),
      ],
    );
  }

  Widget _dayCell(MaterialLocalizations l, int dayOfMonth, int daysInMonth) {
    if (dayOfMonth < 1 || dayOfMonth > daysInMonth) {
      return const SizedBox(height: _cell);
    }
    final day = DateTime(_month.year, _month.month, dayOfMonth);
    final enabled = _enabled(day);
    final start = _start;
    final end = _end;
    final isStart = start != null && day == start;
    final isEnd = end != null && day == end;
    final selected = isStart || isEnd;
    final inside =
        start != null && end != null && day.isAfter(start) && day.isBefore(end);
    final today = day == _dateOnly(DateTime.now());
    // The soft band runs between the two end circles, half-width on each end.
    final bandLeft = inside || (isEnd && start != end);
    final bandRight = inside || (isStart && end != null && start != end);

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: l.formatFullDate(day),
      excludeSemantics: true,
      onTap: enabled ? () => _tap(day) : null,
      child: SizedBox(
        height: _cell,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (bandLeft || bandRight)
              Positioned.fill(
                top: 4,
                bottom: 4,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ColoredBox(
                        color: bandLeft ? BambooInk.wash : Colors.transparent,
                      ),
                    ),
                    Expanded(
                      child: ColoredBox(
                        color: bandRight ? BambooInk.wash : Colors.transparent,
                      ),
                    ),
                  ],
                ),
              ),
            InkResponse(
              onTap: enabled ? () => _tap(day) : null,
              customBorder: const CircleBorder(),
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? BambooInk.slate : null,
                  border: today && !selected
                      ? Border.all(color: BambooInk.slate)
                      : null,
                ),
                child: Text(
                  '$dayOfMonth',
                  style: BambooFonts.ui(
                    14,
                    weight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: !enabled
                        ? BambooInk.ink500.withValues(alpha: 0.5)
                        : selected
                        ? BambooInk.lime
                        : BambooInk.ink900,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(MaterialLocalizations l) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancelButtonLabel),
        ),
        TextButton(
          onPressed: _start == null
              ? null
              : () => Navigator.of(
                  context,
                ).pop(DateTimeRange(start: _start!, end: _end ?? _start!)),
          child: Text(widget.confirmText),
        ),
      ],
    ),
  );
}
