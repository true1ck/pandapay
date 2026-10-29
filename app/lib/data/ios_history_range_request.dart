import 'dart:convert';

/// Selected days use device-local calendar boundaries. Construct the next
/// calendar midnight (rather than adding 24 hours) to handle DST transitions.
class IosHistoryRangeRequest {
  final String id;
  final DateTime start, endExclusive;
  IosHistoryRangeRequest.days({
    required this.id,
    required DateTime firstDay,
    required DateTime lastDay,
  }) : start = DateTime(firstDay.year, firstDay.month, firstDay.day),
       endExclusive = DateTime(lastDay.year, lastDay.month, lastDay.day + 1) {
    if (!start.isBefore(endExclusive)) {
      throw ArgumentError('Reversed history range');
    }
  }
  bool contains(DateTime date) =>
      !date.isBefore(start) && date.isBefore(endExclusive);
  String get json => jsonEncode({
    'version': 2,
    'run_id': id,
    'start_inclusive': start.toUtc().toIso8601String(),
    'end_exclusive': endExclusive.toUtc().toIso8601String(),
  });
}
