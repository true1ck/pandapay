import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/subscription_overrides_store.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

RecurringSeries _s(String id, double rupees) => RecurringSeries(
  id: id,
  displayName: 'Synthetic $id',
  typicalAmount: Money.fromRupees(rupees),
  cadenceDays: 30,
  occurrenceCount: 3,
  annualCost: Money.fromRupees(rupees * 12),
);

void main() {
  late AppDatabase db;
  setUp(() => db = openInMemoryForTesting());
  tearDown(() => db.close());

  test('which ids stay on the phone', () {
    expect(isDeviceLocalSeriesId('v2:abc'), isTrue);
    expect(isDeviceLocalSeriesId('v2:pattern:abc'), isTrue);
    expect(isDeviceLocalSeriesId('v2:notice:abc'), isTrue);
    expect(isDeviceLocalSeriesId('projection:abc'), isTrue);
    expect(isDeviceLocalSeriesId('manual:abc'), isTrue);
    expect(
      isDeviceLocalSeriesId('3f2504e0-4f89-41d3-9a0c-0305e82c3301'),
      isFalse,
    );
  });

  test('hide, edit and manual add survive a restart (new store, same file)', () {
    final first = SubscriptionOverridesStore(db, 'user:a');
    first.hide('v2:gone');
    first.edit(
      'v2:edit',
      displayName: 'Renamed',
      amountInr: 250,
      cadenceDays: 30,
      nextExpectedOn: DateTime(2026, 12, 5),
      autopayStatus: 'on',
    );
    final manualId = first.addManual(
      displayName: 'Gym',
      amountInr: 100,
      cadenceDays: 30,
      nextExpectedOn: DateTime(2026, 12, 9),
      autopayStatus: 'unknown',
    );

    final restarted = SubscriptionOverridesStore(db, 'user:a');
    final report = applySubscriptionOverrides(
      RecurringReport(
        series: [_s('v2:gone', 99), _s('v2:edit', 150), _s('v2:keep', 10)],
        totalAnnual: Money.fromRupees(3000),
      ),
      restarted.all(),
    );
    final byId = {for (final s in report.series) s.id: s};
    expect(byId.containsKey('v2:gone'), isFalse);
    expect(byId['v2:edit']!.displayName, 'Renamed');
    expect(byId['v2:edit']!.typicalAmount, Money.fromRupees(250));
    expect(byId['v2:keep'], isNotNull);
    expect(byId[manualId]!.detectionSource, 'manual');
    expect(byId[manualId]!.annualCost, Money.fromPaise((10000 * 365 / 30).round()));
    // Another account sees none of it.
    expect(SubscriptionOverridesStore(db, 'user:b').all(), isEmpty);
  });

  test('a hidden manual subscription disappears', () {
    final store = SubscriptionOverridesStore(db, 'user:a');
    final id = store.addManual(
      displayName: 'Gym',
      amountInr: 100,
      cadenceDays: 30,
      nextExpectedOn: DateTime(2026, 12, 9),
      autopayStatus: 'unknown',
    );
    store.hide(id);
    final report = applySubscriptionOverrides(
      const RecurringReport(series: [], totalAnnual: Money.zero()),
      store.all(),
    );
    expect(report.series, isEmpty);
  });
}
