import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Lists and totals that show a transaction or card edit. A save spinner waits
/// for all of these, so the screen never closes before they show the change.
final List<FutureProvider<Object?>> editedMoneyViews = [
  userCardsProvider,
  myCardsProvider,
  transactionsProvider,
  utilizationTransactionsProvider,
  homeSummaryProvider,
  categorySpendProvider,
  budgetsProvider,
];

/// Invalidates [views] and waits until each has rebuilt from the saved data,
/// so a save spinner stays up until the change is visible everywhere.
///
/// The edit is already stored when this runs, so a slow or failing view never
/// fails the save: errors are ignored and the wait is capped at [limit].
// ponytail: one cap for all views; per-view progress only if a screen needs it.
Future<void> refreshViews(
  WidgetRef ref, {
  Iterable<FutureProvider<Object?>>? views,
  // Views read the phone's own copy, so this is normally a few milliseconds;
  // the cap only stops one slow view from holding the spinner.
  Duration limit = const Duration(seconds: 2),
}) async {
  final all = (views ?? editedMoneyViews).toList();
  // A family: every query is dropped and rebuilds when its screen next reads it.
  ref.invalidate(spendReportProvider);
  for (final view in all) {
    ref.invalidate(view);
  }
  // Read synchronously (before any await) so the ref is still valid.
  final rebuilt = [
    for (final view in all)
      ref.read(view.future).then<void>((_) {}, onError: (_) {}),
  ];
  await Future.wait(rebuilt).timeout(limit, onTimeout: () => const []);
}
