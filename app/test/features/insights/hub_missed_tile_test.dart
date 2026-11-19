import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/insights/insights_hub_screen.dart';
import 'package:pandapay/features/insights/insights_overview.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

InsightsMissed _missed({
  int missedCount = 0,
  int comparedCount = 0,
  bool canCompare = true,
  bool failed = false,
  Money missed = const Money.zero(),
}) => InsightsMissed(
  missed: missed,
  missedCount: missedCount,
  comparedCount: comparedCount,
  canCompare: canCompare,
  failed: failed,
  top: const [],
);

/// The hub's "Left on the table" tile used to say "No missed rewards" whenever
/// the count was zero, which was always (the comparison read every card as 0%).
/// It may only reassure when spends were actually checked.
void main() {
  test('while the comparison runs there is no figure and no reassurance', () {
    expect(hubMissedValue(null), isNull);
    expect(hubMissedCaption(null), 'Checking your cards');
  });

  test('a failed comparison says so', () {
    final m = _missed(failed: true);
    expect(hubMissedValue(m), isNull);
    expect(hubMissedCaption(m), 'Could not check');
  });

  test('one card product cannot be compared', () {
    final m = _missed(canCompare: false);
    expect(hubMissedValue(m), isNull);
    expect(hubMissedCaption(m), 'Needs two cards');
  });

  test('nothing compared is not a clean sheet', () {
    final m = _missed();
    expect(hubMissedValue(m), isNull);
    expect(hubMissedCaption(m), 'Nothing to compare yet');
  });

  test('checked and nothing clear says how it was checked', () {
    final m = _missed(comparedCount: 12);
    expect(hubMissedValue(m), const Money.zero());
    expect(hubMissedCaption(m), 'No clear misses');
  });

  test('misses show the figure and the count', () {
    final one = _missed(
      missedCount: 1,
      comparedCount: 3,
      missed: Money.fromRupees(120),
    );
    expect(hubMissedValue(one), Money.fromRupees(120));
    expect(hubMissedCaption(one), '1 payment');
    expect(
      hubMissedCaption(_missed(missedCount: 4, comparedCount: 9)),
      '4 payments',
    );
  });
}
