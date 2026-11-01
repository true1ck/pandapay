import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/ios_history_coverage.dart';

void main() {
  final now = DateTime(2026, 11, 15, 12);

  HistoryMonth month(List<HistoryMonth> months, int year, int m) =>
      months.firstWhere((x) => x.start.year == year && x.start.month == m);

  test('two years of months, oldest first, ending this month', () {
    final months = buildHistoryMonths(now: now, coverage: const []);
    expect(months, hasLength(24));
    expect(months.first.start, DateTime(2024, 12));
    expect(months.last.start, DateTime(2026, 11));
    expect(months.every((m) => m.status == MonthCoverage.missing), isTrue);
  });

  test('full, partial and current-month coverage', () {
    final months = buildHistoryMonths(
      now: now,
      coverage: [
        (DateTime(2026, 6), DateTime(2026, 7)), // all of June
        (DateTime(2026, 8, 10), DateTime(2026, 8, 20)), // part of August
        (DateTime(2026, 11), DateTime(2026, 11, 15, 1)), // November to today
      ],
    );
    expect(month(months, 2026, 6).status, MonthCoverage.imported);
    expect(month(months, 2026, 8).status, MonthCoverage.partial);
    expect(month(months, 2026, 9).status, MonthCoverage.missing);
    expect(month(months, 2026, 11).status, MonthCoverage.imported,
        reason: 'only the last few hours of today are missing');
    expect(month(months, 2026, 9).canImport, isTrue);
    expect(month(months, 2026, 6).canImport, isFalse);
  });

  test('the active import marks its months', () {
    final months = buildHistoryMonths(
      now: now,
      coverage: const [],
      jobWindows: [
        {'start': '2026-09-01T00:00:00', 'end': '2026-10-01T00:00:00', 'state': 'running'},
        {'start': '2026-10-01T00:00:00', 'end': '2026-11-01T00:00:00', 'state': 'queued'},
      ],
    );
    expect(month(months, 2026, 9).status, MonthCoverage.importing);
    expect(month(months, 2026, 10).status, MonthCoverage.waiting);
    expect(month(months, 2026, 8).status, MonthCoverage.missing);
  });
}
