import 'package:flutter/material.dart';

/// Counts share one scale; each date exposes exact values and rates to readers.
class RuleMetricChart extends StatelessWidget {
  const RuleMetricChart({super.key, required this.rows, required this.days});
  final List<Map> rows;
  final int days;
  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text('No reported activity in the last $days days.');
    }
    final sorted = [...rows]
      ..sort((a, b) => '${a['day']}'.compareTo('${b['day']}'));
    final now = DateTime.now().toUtc();
    final end = DateTime.utc(now.year, now.month, now.day);
    final start = end.subtract(Duration(days: days - 1));
    final selected = sorted
        .where(
          (r) =>
              !DateTime.parse('${r['day']}'.substring(0, 10)).isBefore(start) &&
              !DateTime.parse('${r['day']}'.substring(0, 10)).isAfter(end),
        )
        .toList();
    if (selected.isEmpty) {
      return Text('No reported activity in the last $days days.');
    }
    final max = selected.fold<double>(
      1,
      (m, r) =>
          (r['hits'] as num).toDouble() > m ? (r['hits'] as num).toDouble() : m,
    );
    final colors = [Colors.blue, Colors.orange, Colors.red];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Hits (blue) · Review (orange) · Corrections (red)'),
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final row in selected)
                Expanded(
                  child: Tooltip(
                    message:
                        '${row['day']}: ${row['hits']} hits, ${row['toReview']} review, ${row['corrected']} corrected',
                    child: Semantics(
                      label:
                          '${row['day']}: ${row['hits']} hits, ${row['toReview']} review, ${row['corrected']} corrected',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final (index, field) in [
                              'hits',
                              'toReview',
                              'corrected',
                            ].indexed)
                              Expanded(
                                child: Container(
                                  height:
                                      120 *
                                      ((row[field] as num?)?.toDouble() ?? 0) /
                                      max,
                                  color: colors[index],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Text('${selected.first['day']} — ${selected.last['day']}'),
      ],
    );
  }
}
