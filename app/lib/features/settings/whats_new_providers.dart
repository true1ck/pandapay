import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/changelog_repository.dart';

/// Task H10 (What's New). Deliberately not imported from app/providers.dart
/// — this file is self-contained so it can be built as a new file alongside
/// several other parallel-agent screens without touching the shared
/// providers.dart (which several sibling tasks are also editing this same
/// session). Matches api/'s default local dev port exactly as
/// app/providers.dart's own `_apiBaseUrl` constant does.
const _apiBaseUrl = 'http://localhost:4000';

final changelogRepositoryProvider =
    Provider<ChangelogRepository>((ref) => ChangelogRepository(apiBaseUrl: _apiBaseUrl));

/// The changelog feed, newest first, max 20 entries — no auth required.
final changelogProvider = FutureProvider<List<ChangelogEntry>>((ref) {
  return ref.watch(changelogRepositoryProvider).fetch();
});

/// Local, on-device "last version the What's New sheet was shown/dismissed
/// for". Follows the exact SharedPreferences-backed StateNotifierProvider
/// pattern OnboardingController/TutorialController use in
/// app/lib/app/providers.dart (load on construction, one persisted mutator).
const _lastSeenAppVersionKey = 'whats_new_last_seen_version_v1';

final lastSeenAppVersionProvider =
    StateNotifierProvider<LastSeenVersionController, AsyncValue<String?>>(
        (ref) => LastSeenVersionController());

class LastSeenVersionController extends StateNotifier<AsyncValue<String?>> {
  LastSeenVersionController() : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AsyncValue.data(prefs.getString(_lastSeenAppVersionKey));
  }

  Future<void> markSeen(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSeenAppVersionKey, version);
    state = AsyncValue.data(version);
  }
}
