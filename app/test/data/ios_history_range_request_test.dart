import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_history_range_request.dart';

void main() {
  test('September includes every final-day instant and excludes October', () {
    final range = IosHistoryRangeRequest.days(
      id: 'test',
      firstDay: DateTime(2026, 9, 1, 18),
      lastDay: DateTime(2026, 9, 30, 4),
    );
    expect(range.start, DateTime(2026, 9, 1));
    expect(range.endExclusive, DateTime(2026, 10, 1));
    expect(range.contains(range.start), isTrue);
    expect(
      range.contains(
        range.endExclusive.subtract(const Duration(microseconds: 1)),
      ),
      isTrue,
    );
    expect(range.contains(range.endExclusive), isFalse);
    final json = jsonDecode(range.json) as Map;
    expect(
      DateTime.parse(json['start_inclusive'] as String),
      range.start.toUtc(),
    );
    expect(json['version'], 2);
  });
  test('calendar boundaries cover leap day and year rollover', () {
    final leap = IosHistoryRangeRequest.days(
      id: 'leap',
      firstDay: DateTime(2024, 2, 1),
      lastDay: DateTime(2024, 2, 29),
    );
    expect(leap.endExclusive, DateTime(2024, 3, 1));
    final year = IosHistoryRangeRequest.days(
      id: 'year',
      firstDay: DateTime(2026, 12, 31),
      lastDay: DateTime(2026, 12, 31),
    );
    expect(year.endExclusive, DateTime(2027, 1, 1));
    expect(
      () => IosHistoryRangeRequest.days(
        id: 'bad',
        firstDay: DateTime(2026, 10, 2),
        lastDay: DateTime(2026, 10, 1),
      ),
      throwsArgumentError,
    );
  });
  test('next midnight uses the local calendar across DST', () {
    final range = IosHistoryRangeRequest.days(
      id: 'dst',
      firstDay: DateTime(2026, 3, 8),
      lastDay: DateTime(2026, 3, 8),
    );
    expect(range.endExclusive, DateTime(2026, 3, 9));
    // This assertion exercises DST when run with TZ=America/New_York.
    if (range.start.timeZoneOffset != range.endExclusive.timeZoneOffset) {
      expect(
        range.endExclusive.difference(range.start),
        const Duration(hours: 23),
      );
    }
  });
}
