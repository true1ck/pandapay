import '../understanding/date_grammar.dart';
import '../voice_format.dart';

/// How a period is named in an answer, and which period came before it.
class PeriodWords {
  const PeriodWords._();

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// "this month", "last week", "October", "yesterday", "the last 7 days".
  static String label(TimeSpan p, DateTime now) {
    final today = _day(now);
    final containsToday = !p.from.isAfter(today) && !p.to.isBefore(today);
    switch (p.kind) {
      case TimeSpanKind.day:
        final d = VoiceFormat.day(p.from, now);
        return d == 'Today' || d == 'Yesterday' ? d.toLowerCase() : d;
      case TimeSpanKind.week:
        if (containsToday) return 'this week';
        final prevWeek = p.from.add(const Duration(days: 7));
        if (!prevWeek.isAfter(today) &&
            !prevWeek.add(const Duration(days: 6)).isBefore(today)) {
          return 'last week';
        }
        return VoiceFormat.range(p.from, p.to, now);
      case TimeSpanKind.month:
        if (containsToday) return 'this month';
        final last = DateTime(today.year, today.month - 1);
        if (p.from.year == last.year && p.from.month == last.month) {
          return 'last month';
        }
        final name = _months[p.from.month - 1];
        return p.from.year == today.year ? name : '$name ${p.from.year}';
      case TimeSpanKind.quarter:
        if (containsToday) return 'this quarter';
        final lastQ = DateTime(
          today.year,
          ((today.month - 1) ~/ 3) * 3 + 1 - 3,
        );
        if (p.from.year == lastQ.year && p.from.month == lastQ.month) {
          return 'last quarter';
        }
        return 'Q${(p.from.month - 1) ~/ 3 + 1} ${p.from.year}';
      case TimeSpanKind.year:
        if (containsToday) return 'this year';
        if (p.from.year == today.year - 1) return 'last year';
        return '${p.from.year}';
      case TimeSpanKind.financialYear:
        if (containsToday) return 'this financial year';
        final y = p.from.year;
        return 'FY $y-${(y + 1) % 100}';
      case TimeSpanKind.rolling:
        final n = p.to.difference(p.from).inDays + 1;
        return 'the last $n days';
      case TimeSpanKind.since:
        return 'since ${VoiceFormat.day(p.from, now)}';
      case TimeSpanKind.toDate:
        return p.from.month == 1 && p.from.day == 1
            ? 'this year so far'
            : 'this month so far';
      case TimeSpanKind.allTime:
        return 'all time';
      case TimeSpanKind.range:
        return VoiceFormat.range(p.from, p.to, now);
    }
  }

  /// The period that came right before [p], aligned to the calendar where
  /// [p] is a calendar period, otherwise the same number of days. Null when
  /// there is no sensible one ("all time").
  static TimeSpan? previous(TimeSpan p) {
    TimeSpan make(DateTime from, DateTime to) => TimeSpan(
      startToken: p.startToken,
      endToken: p.endToken,
      from: from,
      to: to,
      kind: p.kind == TimeSpanKind.day ? TimeSpanKind.day : p.kind,
    );
    switch (p.kind) {
      case TimeSpanKind.allTime:
        return null;
      case TimeSpanKind.day:
        final d = DateTime(p.from.year, p.from.month, p.from.day - 1);
        return make(d, d);
      case TimeSpanKind.week:
        return make(
          DateTime(p.from.year, p.from.month, p.from.day - 7),
          DateTime(p.to.year, p.to.month, p.to.day - 7),
        );
      case TimeSpanKind.month:
        final from = DateTime(p.from.year, p.from.month - 1);
        return make(from, DateTime(from.year, from.month + 1, 0));
      case TimeSpanKind.quarter:
        final from = DateTime(p.from.year, p.from.month - 3);
        return make(from, DateTime(from.year, from.month + 3, 0));
      case TimeSpanKind.year:
        return make(
          DateTime(p.from.year - 1),
          DateTime(p.from.year - 1, 12, 31),
        );
      case TimeSpanKind.financialYear:
        return make(DateTime(p.from.year - 1, 4), DateTime(p.from.year, 3, 31));
      case TimeSpanKind.rolling:
      case TimeSpanKind.since:
      case TimeSpanKind.toDate:
      case TimeSpanKind.range:
        final days = p.to.difference(p.from).inDays + 1;
        final to = DateTime(p.from.year, p.from.month, p.from.day - 1);
        final from = DateTime(to.year, to.month, to.day - (days - 1));
        return make(from, to);
    }
  }

  /// "last month" when [p] is the current period, otherwise "the month
  /// before".
  static String previousLabel(TimeSpan p, DateTime now) {
    final today = _day(now);
    final current = !p.from.isAfter(today) && !p.to.isBefore(today);
    String unit(String last, String before) => current ? last : before;
    return switch (p.kind) {
      TimeSpanKind.day => unit('yesterday', 'the day before'),
      TimeSpanKind.week => unit('last week', 'the week before'),
      TimeSpanKind.month => unit('last month', 'the month before'),
      TimeSpanKind.quarter => unit('last quarter', 'the quarter before'),
      TimeSpanKind.year => unit('last year', 'the year before'),
      TimeSpanKind.financialYear => 'the previous financial year',
      _ => 'the same number of days before',
    };
  }
}
