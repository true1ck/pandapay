import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/changelog_repository.dart';
import 'settings_sync.dart';
import '../../app/env.dart';

/// Task H10 (What's New). Deliberately not imported from app/providers.dart
/// — this file is self-contained so it can be built as a new file alongside
/// several other parallel-agent screens without touching the shared
/// providers.dart (which several sibling tasks are also editing this same
/// session). Matches api/'s default local dev port exactly as
/// app/providers.dart's own `_apiBaseUrl` constant does.
const _apiBaseUrl = Env.apiBaseUrl; // plan Phase 0.3 — see app/env.dart

final changelogRepositoryProvider = Provider<ChangelogRepository>(
  (ref) => ChangelogRepository(apiBaseUrl: _apiBaseUrl),
);

/// The changelog feed, newest first, max 20 entries — no auth required.
///
/// WP-C11: the last good copy is kept on the phone (public release notes, no
/// account data). A slow or missing network shows it instead of a spinner.
const changelogCacheKey = 'whats_new_changelog_cache_v1';

Future<List<ChangelogEntry>?> readChangelogCache() async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(changelogCacheKey);
    if (raw == null) return null;
    return [
      for (final m in jsonDecode(raw) as List)
        ChangelogEntry.fromJson(Map<String, dynamic>.from(m as Map)),
    ];
  } catch (_) {
    return null;
  }
}

final changelogProvider = FutureProvider<List<ChangelogEntry>>((ref) async {
  final repo = ref.watch(changelogRepositoryProvider);
  try {
    final entries = await repo.fetch();
    try {
      await (await SharedPreferences.getInstance()).setString(
        changelogCacheKey,
        jsonEncode([for (final e in entries) e.toJson()]),
      );
    } catch (_) {}
    return entries;
  } catch (_) {
    final cached = await readChangelogCache();
    if (cached != null) return cached;
    rethrow;
  }
});

/// "Last version the What's New sheet was shown/dismissed for". Follows the
/// exact SharedPreferences-backed StateNotifierProvider pattern
/// OnboardingController/TutorialController use in app/lib/app/providers.dart
/// (load on construction, one persisted mutator), and as of plan Phase 1.1
/// mirrors the key to `user_settings` so a second device doesn't re-announce
/// a release the user has already read about.
const _lastSeenAppVersionKey = 'whats_new_last_seen_version_v1';

final lastSeenAppVersionProvider = StateNotifierProvider<LastSeenVersionController, AsyncValue<String?>>(
  LastSeenVersionController.new,
);

class LastSeenVersionController extends StateNotifier<AsyncValue<String?>> {
  final Ref _ref;
  LastSeenVersionController(this._ref) : super(const AsyncValue.loading()) {
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
    _ref.read(settingsSyncProvider).pushKeyQuietly(_lastSeenAppVersionKey);
  }
}
