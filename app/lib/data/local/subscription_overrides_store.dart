import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:uuid/uuid.dart';

import '../local_first/pending_overlays.dart' show editedSeries;
import '../spend_reports_repository.dart';
import 'app_database.dart';

/// True for subscription ids the server can never know: SMS-v2 series
/// (`v2:...`, `v2:pattern:...`, `v2:notice:...`), projections and locally
/// added ones. Those edits stay on the phone; everything else is a server uuid.
bool isDeviceLocalSeriesId(String id) =>
    id.startsWith('v2:') ||
    id.startsWith('projection:') ||
    id.startsWith('manual:');

/// WP-C7: durable, device-local subscription overrides (hide, edit, manual add)
/// for series that have no server row. Table `subscription_overrides`, created
/// by `LocalFirstSchema` migration 2. Account-scoped by [namespace].
class SubscriptionOverridesStore {
  SubscriptionOverridesStore(this._db, this.namespace);
  final AppDatabase _db;
  final String namespace;

  void hide(String seriesId) => _put(seriesId, {'hidden': true});

  void edit(
    String seriesId, {
    required String displayName,
    required double amountInr,
    required int cadenceDays,
    required DateTime nextExpectedOn,
    required String autopayStatus,
  }) => _put(seriesId, {
    'displayName': displayName,
    'amountInr': amountInr,
    'cadenceDays': cadenceDays,
    'nextExpectedOn': _day(nextExpectedOn),
    'autopayStatus': autopayStatus,
  });

  /// A subscription typed in by the person; returns its `manual:<uuid>` id.
  String addManual({
    required String displayName,
    required double amountInr,
    required int cadenceDays,
    required DateTime nextExpectedOn,
    required String autopayStatus,
  }) {
    final id = 'manual:${const Uuid().v4()}';
    _put(id, {
      'manual': true,
      'displayName': displayName,
      'amountInr': amountInr,
      'cadenceDays': cadenceDays,
      'nextExpectedOn': _day(nextExpectedOn),
      'autopayStatus': autopayStatus,
    });
    return id;
  }

  Map<String, Map<String, Object?>> all() => {
    for (final row in _db.db.select(
      'SELECT series_id, payload FROM subscription_overrides WHERE namespace=?',
      [namespace],
    ))
      row['series_id'] as String: (jsonDecode(row['payload'] as String) as Map)
          .cast<String, Object?>(),
  };

  void _put(String id, Map<String, Object?> patch) {
    final merged = {...?all()[id], ...patch};
    if (patch.containsKey('displayName')) merged.remove('hidden');
    _db.db.execute(
      'INSERT OR REPLACE INTO subscription_overrides VALUES (?,?,?,?)',
      [
        namespace,
        id,
        jsonEncode(merged),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Pure: lays [overrides] over [base]. Hidden series disappear, edits replace
/// the shown fields, `manual:` entries are appended as
/// `RecurringSeries(detectionSource: 'manual')`. The headline total is
/// recomputed only when something changed.
RecurringReport applySubscriptionOverrides(
  RecurringReport base,
  Map<String, Map<String, Object?>> overrides,
) {
  if (overrides.isEmpty) return base;
  final series = <RecurringSeries>[];
  for (final s in base.series) {
    final o = overrides[s.id];
    if (o == null) {
      series.add(s);
    } else if (o['hidden'] != true && o['amountInr'] != null) {
      series.add(editedSeries(s, o));
    } else if (o['hidden'] != true) {
      series.add(s);
    }
  }
  for (final e in overrides.entries) {
    final o = e.value;
    if (o['manual'] != true || o['hidden'] == true) continue;
    final amount = Money.fromRupees((o['amountInr'] as num).toDouble());
    final cadence = (o['cadenceDays'] as num).toInt();
    series.add(
      RecurringSeries(
        id: e.key,
        displayName: o['displayName'] as String,
        typicalAmount: amount,
        cadenceDays: cadence,
        occurrenceCount: 0,
        annualCost: cadence <= 0
            ? const Money.zero()
            : Money.fromPaise((amount.paise * 365 / cadence).round()),
        nextExpectedOn: DateTime.tryParse('${o['nextExpectedOn']}'),
        autopayStatus: (o['autopayStatus'] as String?) ?? 'unknown',
        detectionSource: 'manual',
        isUserEdited: true,
      ),
    );
  }
  return RecurringReport(
    series: series,
    totalAnnual: Money.fromPaise(
      series.fold<int>(0, (sum, s) => sum + s.annualCost.paise),
    ),
  );
}
