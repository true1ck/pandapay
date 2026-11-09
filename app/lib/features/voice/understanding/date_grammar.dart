import 'language_pack.dart';
import 'number_grammar.dart';
import 'tokens.dart';

enum TimeSpanKind {
  day,
  week,
  month,
  quarter,
  year,
  financialYear,
  rolling,
  range,
  since,
  toDate,
  allTime,
}

/// A day or a stretch of days found in a sentence. [from] and [to] are
/// inclusive local dates at midnight, so a single day has `from == to`.
class TimeSpan {
  const TimeSpan({
    required this.startToken,
    required this.endToken,
    required this.from,
    required this.to,
    required this.kind,
    this.yearInferredBack = false,
    this.monthless = false,
  });

  /// Only a day of the month was named ("the 3rd"); the month was inferred.
  /// A range such as "3rd and 5th of October" lets the later date supply it.
  final bool monthless;

  final int startToken;
  final int endToken;
  final DateTime from;
  final DateTime to;
  final TimeSpanKind kind;

  /// The phrase named no year and this year's occurrence is still ahead, so
  /// [from] and [to] point at the most recent past one. Spend entries treat
  /// this as a future date; questions simply use the past occurrence.
  final bool yearInferredBack;

  bool get isSingleDay => from == to;
  int get length => endToken - startToken;

  bool isFuture(DateTime today) => from.isAfter(today);

  String text(String source, List<Token> tokens) =>
      source.substring(tokens[startToken].start, tokens[endToken - 1].end);
}

/// Finds every date or period in [tokens] relative to [now]. Small grammar,
/// no sentence templates: "last Friday", "3rd of November", "2 days ago",
/// "since Monday", "between 1 Oct and 15 Oct", "this financial year".
List<TimeSpan> findTimeSpans(
  List<Token> tokens,
  LanguagePack pack,
  DateTime now,
) {
  final reader = _TimeReader(
    tokens,
    pack,
    DateTime(now.year, now.month, now.day),
  );
  final spans = <TimeSpan>[];
  var i = 0;
  while (i < tokens.length) {
    final span = reader.at(i);
    if (span == null) {
      i++;
      continue;
    }
    spans.add(span);
    i = span.endToken;
  }
  return spans;
}

class _TimeReader {
  _TimeReader(this.t, this.p, this.today);

  final List<Token> t;
  final LanguagePack p;
  final DateTime today;

  bool has(int k) => k >= 0 && k < t.length;
  String w(int k) => has(k) && t[k].isWord ? t[k].text : '';
  bool isW(int k, Set<String> set) => set.contains(w(k));

  DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
  DateTime monday(DateTime d) => addDays(d, 1 - d.weekday);
  DateTime? mk(int y, int m, int d) {
    final x = DateTime(y, m, d);
    return x.month == m && x.day == d ? x : null;
  }

  DateTime lastOfMonth(int y, int m) => DateTime(y, m + 1, 0);

  TimeSpan day(
    int start,
    int end,
    DateTime d, {
    bool back = false,
    bool monthless = false,
  }) => TimeSpan(
    startToken: start,
    endToken: end,
    from: d,
    to: d,
    kind: TimeSpanKind.day,
    yearInferredBack: back,
    monthless: monthless,
  );

  TimeSpan span(
    int start,
    int end,
    DateTime from,
    DateTime to,
    TimeSpanKind kind, {
    bool back = false,
  }) => TimeSpan(
    startToken: start,
    endToken: end,
    from: from,
    to: to,
    kind: kind,
    yearInferredBack: back,
  );

  TimeSpan? at(int i) {
    final word = w(i);
    if (word.isNotEmpty) {
      if (p.sinceWords.contains(word)) {
        final inner = single(i + 1);
        if (inner != null) {
          return span(
            i,
            inner.endToken,
            inner.from,
            today,
            TimeSpanKind.since,
          );
        }
      }
      if (p.rangeStartWords.contains(word)) {
        final a = single(i + 1);
        if (a != null) {
          final j = a.endToken;
          if (isW(j, p.rangeJoinWords) || (has(j) && t[j].text == '-')) {
            final b = single(j + 1);
            if (b != null) {
              var from = a.from;
              if (a.monthless && b.isSingleDay && !b.monthless) {
                final x = mk(b.from.year, b.from.month, a.from.day);
                if (x != null && !x.isAfter(b.from)) from = x;
              }
              return span(i, b.endToken, from, b.to, TimeSpanKind.range);
            }
          }
        }
      }
    }
    return single(i);
  }

  TimeSpan? single(int i) {
    if (!has(i)) return null;
    return phrase(i) ??
        dayBeforeYesterday(i) ??
        relativeDay(i) ??
        ago(i) ??
        rolling(i) ??
        calendarUnit(i) ??
        weekday(i) ??
        dayMonth(i) ??
        numeric(i) ??
        monthOnly(i) ??
        yearOnly(i);
  }

  TimeSpan? phrase(int i) {
    for (final entry in p.timePhrases.entries) {
      for (final words in entry.value) {
        var ok = true;
        for (var k = 0; k < words.length; k++) {
          if (w(i + k) != words[k]) {
            ok = false;
            break;
          }
        }
        if (!ok) continue;
        final end = i + words.length;
        return switch (entry.key) {
          'allTime' => span(
            i,
            end,
            DateTime(2000),
            today,
            TimeSpanKind.allTime,
          ),
          'yearToDate' => span(
            i,
            end,
            DateTime(today.year),
            today,
            TimeSpanKind.toDate,
          ),
          'monthToDate' => span(
            i,
            end,
            DateTime(today.year, today.month),
            today,
            TimeSpanKind.toDate,
          ),
          _ => null,
        };
      }
    }
    return null;
  }

  TimeSpan? dayBeforeYesterday(int i) {
    if (w(i) == 'day' &&
        isW(i + 1, p.beforeWords) &&
        isW(i + 2, p.yesterdayWords)) {
      return day(i, i + 3, addDays(today, -2));
    }
    return null;
  }

  TimeSpan? relativeDay(int i) {
    if (isW(i, p.yesterdayWords)) {
      final end = isW(i + 1, p.partOfDayWords) ? i + 2 : i + 1;
      return day(i, end, addDays(today, -1));
    }
    if (isW(i, p.lastWords) && w(i + 1) == 'night') {
      return day(i, i + 2, addDays(today, -1));
    }
    if (isW(i, p.todayWords)) return day(i, i + 1, today);
    if (isW(i, p.thisWords) && isW(i + 1, p.partOfDayWords)) {
      return day(i, i + 2, today);
    }
    return null;
  }

  DateTime addMonths(DateTime d, int n) {
    final total = d.year * 12 + (d.month - 1) + n;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final last = lastOfMonth(y, m).day;
    return DateTime(y, m, d.day > last ? last : d.day);
  }

  TimeSpan? ago(int i) {
    int? n;
    var k = i;
    final num = numberAt(t, i, p);
    if (num != null) {
      n = num.value.round();
      k = num.endToken;
    } else if (isW(i, p.articleWords)) {
      n = 1;
      k = i + 1;
    }
    if (n == null) return null;
    final unit = p.unitWords[w(k)];
    if (unit == null || !isW(k + 1, p.agoWords)) return null;
    final d = switch (unit) {
      'day' => addDays(today, -n),
      'week' => addDays(today, -7 * n),
      'month' => addMonths(today, -n),
      'year' => addMonths(today, -12 * n),
      'quarter' => addMonths(today, -3 * n),
      _ => today,
    };
    return day(i, k + 2, d);
  }

  TimeSpan? rolling(int i) {
    final last = isW(i, p.lastWords);
    final past = isW(i, p.pastWords);
    if (!last && !past) return null;
    var n = 1;
    var k = i + 1;
    final num = numberAt(t, i + 1, p);
    if (num != null) {
      n = num.value.round();
      k = num.endToken;
    } else if (last) {
      return null; // "last week" is a calendar week
    }
    final unit = p.unitWords[w(k)];
    if (unit == null || n < 1) return null;
    final from = switch (unit) {
      'day' => addDays(today, -(n - 1)),
      'week' => addDays(today, -(7 * n - 1)),
      'month' => addDays(addMonths(today, -n), 1),
      'year' => addDays(addMonths(today, -12 * n), 1),
      'quarter' => addDays(addMonths(today, -3 * n), 1),
      _ => today,
    };
    return span(i, k + 1, from, today, TimeSpanKind.rolling);
  }

  TimeSpan? calendarUnit(int i) {
    final thisW = isW(i, p.thisWords);
    final lastW = isW(i, p.lastWords);
    if (!thisW && !lastW) return null;
    final back = lastW ? 1 : 0;
    // Financial year: Apr 1 to Mar 31.
    var fyEnd = -1;
    if (isW(i + 1, p.financialWords) && w(i + 2) == 'year') {
      fyEnd = i + 3;
    } else if (isW(i + 1, p.fyWords)) {
      fyEnd = i + 2;
    }
    if (fyEnd > 0) {
      final startYear = (today.month >= 4 ? today.year : today.year - 1) - back;
      return span(
        i,
        fyEnd,
        DateTime(startYear, 4),
        DateTime(startYear + 1, 3, 31),
        TimeSpanKind.financialYear,
      );
    }
    final unit = p.unitWords[w(i + 1)];
    if (unit == null) return null;
    switch (unit) {
      case 'week':
        final start = addDays(monday(today), -7 * back);
        return span(
          i,
          i + 2,
          start,
          addDays(start, 6),
          TimeSpanKind.week,
        );
      case 'month':
        final first = addMonths(DateTime(today.year, today.month), -back);
        return span(
          i,
          i + 2,
          first,
          lastOfMonth(first.year, first.month),
          TimeSpanKind.month,
        );
      case 'quarter':
        final qStart = DateTime(
          today.year,
          ((today.month - 1) ~/ 3) * 3 + 1,
        );
        final first = addMonths(qStart, -3 * back);
        final end = addMonths(first, 2);
        return span(
          i,
          i + 2,
          first,
          lastOfMonth(end.year, end.month),
          TimeSpanKind.quarter,
        );
      case 'year':
        final y = today.year - back;
        return span(
          i,
          i + 2,
          DateTime(y),
          DateTime(y, 12, 31),
          TimeSpanKind.year,
        );
    }
    return null;
  }

  TimeSpan? weekday(int i) {
    var k = i;
    String modifier = '';
    if (isW(i, p.lastWords)) {
      modifier = 'last';
      k = i + 1;
    } else if (isW(i, p.thisWords)) {
      modifier = 'this';
      k = i + 1;
    } else if (isW(i, p.nextWords)) {
      modifier = 'next';
      k = i + 1;
    }
    final target = p.weekdayNames[w(k)];
    if (target == null) return null;
    final diff = (today.weekday - target) % 7;
    final d = switch (modifier) {
      'last' => addDays(today, -(diff == 0 ? 7 : diff)),
      'next' => addDays(today, diff == 0 ? 7 : 7 - diff),
      _ => addDays(today, -diff),
    };
    return day(i, k + 1, d);
  }

  /// Day of month at [k]: "3rd", "third", "twenty first", or a plain 1..31.
  ({int value, int end, bool ordinal})? dayAt(int k, {bool allowPlain = true}) {
    if (!has(k)) return null;
    final tok = t[k];
    if (tok.isNumber) {
      final v = tok.number!;
      if (v != v.roundToDouble() || v < 1 || v > 31) return null;
      if (p.ordinalSuffixes.contains(tok.suffix)) {
        return (value: v.toInt(), end: k + 1, ordinal: true);
      }
      if (allowPlain && tok.suffix.isEmpty) {
        return (value: v.toInt(), end: k + 1, ordinal: false);
      }
      return null;
    }
    final ord = p.ordinalWords[w(k)];
    if (ord != null) return (value: ord, end: k + 1, ordinal: true);
    final tens = p.numberTens[w(k)];
    if (tens != null && tens >= 20 && tens <= 30) {
      var n = k + 1;
      if (has(n) && t[n].text == '-') n++;
      final unit = p.ordinalWords[w(n)];
      if (unit != null && unit >= 1 && unit <= 9 && tens + unit <= 31) {
        return (value: tens + unit, end: n + 1, ordinal: true);
      }
    }
    return null;
  }

  int? yearAt(int k) {
    if (!has(k) || !t[k].isNumber || t[k].suffix.isNotEmpty) return null;
    final v = t[k].number!;
    if (v == v.roundToDouble() && v >= 1990 && v <= 2100) return v.toInt();
    return null;
  }

  TimeSpan? resolveDayMonth(int start, int end, int d, int m, int? year) {
    if (year != null) {
      final x = mk(year, m, d);
      return x == null ? null : day(start, end, x);
    }
    final thisYear = mk(today.year, m, d);
    if (thisYear == null) return null;
    if (!thisYear.isAfter(today)) return day(start, end, thisYear);
    final prior = mk(today.year - 1, m, d);
    return prior == null ? null : day(start, end, prior, back: true);
  }

  TimeSpan? dayMonth(int i) {
    // 3rd of November, 3 Nov 2025, twenty first of march
    final first = dayAt(i);
    if (first != null) {
      var k = first.end;
      if (isW(k, p.ofWords)) k++;
      final m = p.monthNames[w(k)];
      if (m != null) {
        final y = yearAt(k + 1);
        return resolveDayMonth(i, y != null ? k + 2 : k + 1, first.value, m, y);
      }
      // "on the 3rd", "the third": day of the current or previous month.
      if (first.ordinal && (t[i].isNumber || isW(i - 1, p.theWords))) {
        return dayOfMonth(i, first.end, first.value);
      }
      return null;
    }
    // November 3, nov 3rd 2025
    final m = p.monthNames[w(i)];
    if (m != null) {
      final d = dayAt(i + 1);
      if (d != null) {
        final y = yearAt(d.end);
        return resolveDayMonth(i, y != null ? d.end + 1 : d.end, d.value, m, y);
      }
    }
    return null;
  }

  TimeSpan? dayOfMonth(int start, int end, int d) {
    var y = today.year;
    var m = today.month;
    if (d > today.day) {
      m -= 1;
      if (m == 0) {
        m = 12;
        y -= 1;
      }
    }
    final x = mk(y, m, d);
    return x == null ? null : day(start, end, x, monthless: true);
  }

  TimeSpan? numeric(int i) {
    // 3/11 or 03/11/2026, day first as in India
    if (!has(i + 2) || !t[i].isNumber || t[i].suffix.isNotEmpty) return null;
    if (t[i + 1].text != '/' || !t[i + 2].isNumber) return null;
    final a = t[i].number!;
    final b = t[i + 2].number!;
    if (a != a.roundToDouble() || b != b.roundToDouble()) return null;
    if (a < 1 || a > 31 || b < 1 || b > 12) return null;
    var end = i + 3;
    int? year;
    if (has(i + 4) && t[i + 3].text == '/' && t[i + 4].isNumber) {
      final yv = t[i + 4].number!;
      year = yv < 100 ? 2000 + yv.toInt() : yv.toInt();
      end = i + 5;
    }
    return resolveDayMonth(i, end, a.toInt(), b.toInt(), year);
  }

  TimeSpan? monthOnly(int i) {
    var k = i;
    String modifier = '';
    if (isW(i, p.lastWords)) {
      modifier = 'last';
      k = i + 1;
    } else if (isW(i, p.thisWords)) {
      modifier = 'this';
      k = i + 1;
    }
    final m = p.monthNames[w(k)];
    if (m == null) return null;
    final y = yearAt(k + 1);
    final named = modifier.isNotEmpty ||
        y != null ||
        isW(k - 1, p.monthPrepositions);
    if (!named) return null;
    int year;
    var back = false;
    if (y != null) {
      year = y;
    } else if (modifier == 'last') {
      year = m >= today.month ? today.year - 1 : today.year;
    } else {
      year = m <= today.month ? today.year : today.year - 1;
      back = m > today.month;
    }
    return span(
      i,
      y != null ? k + 2 : k + 1,
      DateTime(year, m),
      lastOfMonth(year, m),
      TimeSpanKind.month,
      back: back,
    );
  }

  TimeSpan? yearOnly(int i) {
    final y = yearAt(i);
    if (y == null) return null;
    final prev = w(i - 1);
    if (!(p.monthPrepositions.contains(prev) || prev == 'year')) return null;
    return span(
      i,
      i + 1,
      DateTime(y),
      DateTime(y, 12, 31),
      TimeSpanKind.year,
    );
  }
}
