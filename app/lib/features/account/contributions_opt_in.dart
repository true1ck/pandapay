import '../../app/providers.dart'
    show
        profileProvider,
        profileSnapshotWriterProvider,
        userCardsRepositoryProvider;
import 'account_local_first.dart';

/// WP-C11: the "Share what you see" switch. Sent now, or queued when the
/// server cannot be reached; either way the profile cache shows the new value
/// at once. [ref] is a `WidgetRef`.
Future<AccountWrite> setContributionsOptInLocalFirst(dynamic ref, bool optIn) async {
  final repo = ref.read(userCardsRepositoryProvider);
  if (repo == null) return AccountWrite.sent;
  final result = await sendOrQueue(
    ref,
    kind: AccountCommand.contributionsOptIn,
    target: 'contributions_opt_in',
    payload: {'optIn': optIn},
    live: () => repo.setContributionsOptIn(optIn) as Future<void>,
  );
  if (result == AccountWrite.queued) {
    final current =
        (ref.read(profileProvider).value as Map<String, dynamic>?) ??
        const {};
    await ref.read(profileSnapshotWriterProvider)({
      ...current,
      'contributions_opt_in': optIn,
    });
  } else {
    ref.invalidate(profileProvider);
  }
  return result;
}
