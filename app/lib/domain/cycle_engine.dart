class CycleEngine {
  static int daysInMonth(int year, int month) {
    return DateTime(year, month + 1, 0).day;
  }

  static int clampDay(int year, int month, int targetDay) {
    final maxDay = daysInMonth(year, month);
    return targetDay > maxDay ? maxDay : (targetDay < 1 ? 1 : targetDay);
  }

  static DateTime clampedDate(int year, int month, int targetDay, [int hour = 0, int minute = 0, int second = 0]) {
    final clamped = clampDay(year, month, targetDay);
    return DateTime(year, month, clamped, hour, minute, second);
  }

  static DateTime nextOccurrence(int targetDay, DateTime now) {
    var candidate = clampedDate(now.year, now.month, targetDay);
    if (!candidate.isAfter(now)) {
      var nextMonth = now.month + 1;
      var nextYear = now.year;
      if (nextMonth > 12) {
        nextMonth = 1;
        nextYear++;
      }
      candidate = clampedDate(nextYear, nextMonth, targetDay);
    }
    return candidate;
  }
}
