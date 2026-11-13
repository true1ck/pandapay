import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../data/authenticated_http_client.dart';
import '../../data/connectivity/reachability.dart';
import '../../data/user_settings_api.dart';
import '../account/account_local_first.dart' show kAccountLocalFirst;
import 'appearance_providers.dart';
import 'whats_new_providers.dart';

/// Plan Phase 1.1 — the client half of account-level preference sync.
///
/// The problem this exists to fix: every preference in the app lived only in
/// SharedPreferences, so signing in on a second phone re-ran onboarding for
/// an existing user and reset their theme, text scale, and number format.
/// Cards and transactions came back correctly (the app is server-
/// authoritative for those), which made it look worse, not better — the data
/// was there but the app felt like a stranger.
///
/// The design is deliberately a *registry over the existing preferences*
/// rather than a rewrite of the controllers that own them. Each controller
/// (`ThemeModeController`, `OnboardingController`, …) keeps SharedPreferences
/// as its source of truth and keeps working unchanged when signed out or
/// offline; this class mirrors a named subset of those keys to the server and
/// back. That keeps sync a bolt-on that can fail silently without breaking a
/// single screen, which is the right failure mode for a display preference.

/// The four SharedPreferences value shapes the registry needs to round-trip.
/// JSON gives back `List<dynamic>` for a string list and `num` for a double,
/// so each entry has to know what to cast to — a generic `Object?` write
/// would put an unusable `List<dynamic>` into a `getStringList` key.
enum SyncedPrefType { boolean, number, string, stringList }

class SyncedPref {
  final String key;
  final SyncedPrefType type;
  const SyncedPref(this.key, this.type);
}

/// The authoritative list of what follows the account. Adding a preference to
/// the app means adding one line here — there is no server-side change,
/// because `user_settings.settings` is an opaque jsonb blob (migration 0028).
///
/// Keys are duplicated as literals rather than imported from the files that
/// define them: those constants are private (`_themeModeKey` and friends),
/// and making them public purely to build this list would widen their API for
/// no other caller. [debugAssertRegistryKeysExist] in the test suite is what
/// keeps the two copies honest.
const kSyncedPrefs = <SyncedPref>[
  // First-run state. The single most valuable thing here: without it, an
  // existing user signing in on a new phone is walked through Welcome and
  // direct auth again as if they had never used the app.
  SyncedPref('pandapay_app.onboarding_complete_v1', SyncedPrefType.boolean),
  SyncedPref('pandapay_app.tutorial_seen_v1', SyncedPrefType.boolean),
  // H6 Appearance.
  SyncedPref('appearance_theme_mode_v1', SyncedPrefType.string),
  SyncedPref('appearance_text_scale_v1', SyncedPrefType.number),
  SyncedPref('appearance_number_format_v1', SyncedPrefType.string),
  // E8 due-date reminder toggles, keyed by user_card id — which are
  // server-issued and therefore stable across devices, so the set means the
  // same thing on a new handset. (A locally-generated id would not survive
  // this trip and must never be added to this registry.)
  SyncedPref('pandapay_app.due_date_reminders_v1', SyncedPrefType.stringList),
  // What's-new: prevents a new device from re-announcing a release the user
  // has already read about.
  SyncedPref('whats_new_last_seen_version_v1', SyncedPrefType.string),
];

/// Deliberately absent from [kSyncedPrefs], each for its own reason:
///
/// - `settings_biometric_lock_v1` — a statement about one handset's enrolled
///   biometrics. Syncing it would either silently disable a lock the user
///   believes is on, or turn one on that the new device cannot satisfy.
/// - the quick-add last-used-card key — a per-device convenience whose whole
///   value is "what I last did *on this phone*"; it is also already handled
///   as a sign-out privacy concern in `providers.dart`.
/// - anything in `cached_responses` / `transaction_outbox_entries` — those are
///   a cache and a pending-write queue, not preferences.
const kDeliberatelyDeviceLocalPrefs = <String>['settings_biometric_lock_v1'];

class SettingsSync {
  final Ref _ref;
  SettingsSync(this._ref);

  UserSettingsApi? get _api => _ref.read(userSettingsApiProvider);

  /// Keys changed on this phone whose push to the server has not succeeded
  /// yet. Without this a failed push was lost: the next pull let the server's
  /// older value overwrite the choice the person had just made.
  static const _dirtyKey = 'pandapay_app.settings_dirty_v1';

  Future<void> _markDirty(SharedPreferences prefs, String key, bool dirty) async {
    final keys = (prefs.getStringList(_dirtyKey) ?? const <String>[]).toSet();
    if (dirty ? !keys.add(key) : !keys.remove(key)) return;
    await prefs.setStringList(_dirtyKey, keys.toList());
  }

  /// Pulls the server blob and applies it locally, then pushes back any
  /// registry key this device has that the server doesn't.
  ///
  /// That second half is what makes the *first* sync after an update correct.
  /// An existing user has real preferences on their phone and an empty server
  /// blob; a plain "server wins" pull would wipe them, and a plain "local
  /// wins" push would break every subsequent device switch. Server-wins for
  /// keys the server has, local-seeds-server for keys it doesn't, is the only
  /// combination that is right in both directions.
  ///
  /// Returns the keys that were changed locally, so the caller can invalidate
  /// exactly the providers that need to re-read — and, more usefully, so a
  /// test can assert what happened rather than inferring it.
  Future<List<String>> pullAndApply() async {
    final api = _api;
    if (api == null) return const [];

    final snapshot = await api.fetch();
    final prefs = await SharedPreferences.getInstance();
    final applied = <String>[];
    final toSeed = <String, Object?>{};
    final dirty = (prefs.getStringList(_dirtyKey) ?? const <String>[]).toSet();

    for (final pref in kSyncedPrefs) {
      final remote = snapshot.settings[pref.key];
      if (dirty.contains(pref.key)) {
        // A choice made on this phone that never reached the server: send it
        // instead of letting the older server value replace it.
        toSeed[pref.key] = _readLocal(prefs, pref);
      } else if (remote != null) {
        if (await _writeLocal(prefs, pref, remote)) applied.add(pref.key);
      } else {
        final local = _readLocal(prefs, pref);
        if (local != null) toSeed[pref.key] = local;
      }
    }

    if (toSeed.isNotEmpty) {
      await api.patch(toSeed);
      for (final key in toSeed.keys) {
        await _markDirty(prefs, key, false);
      }
    }
    return applied;
  }

  /// Mirrors one key to the server. Fire-and-forget by design — see
  /// [pushKeyQuietly], which is what the preference controllers actually call.
  Future<void> pushKey(String key) async {
    final api = _api;
    if (api == null) return;
    SyncedPref? pref;
    for (final candidate in kSyncedPrefs) {
      if (candidate.key == key) pref = candidate;
    }
    if (pref == null) return;
    final prefs = await SharedPreferences.getInstance();
    // Remember the change before trying: if the push fails the key stays
    // dirty and goes out on the next pull or the next push of any key.
    await _markDirty(prefs, key, true);
    final pending = <String, Object?>{};
    for (final candidate in kSyncedPrefs) {
      if ((prefs.getStringList(_dirtyKey) ?? const <String>[]).contains(
        candidate.key,
      )) {
        pending[candidate.key] = _readLocal(prefs, candidate);
      }
    }
    await api.patch(pending);
    for (final sent in pending.keys) {
      await _markDirty(prefs, sent, false);
    }
  }

  /// Reads a registry key out of SharedPreferences as a JSON-encodable value.
  /// `null` means "never set on this device", which the server stores as a
  /// key deletion rather than a null (see the PUT route's doc comment).
  Object? _readLocal(SharedPreferences prefs, SyncedPref pref) {
    return switch (pref.type) {
      SyncedPrefType.boolean => prefs.getBool(pref.key),
      SyncedPrefType.number => prefs.getDouble(pref.key),
      SyncedPrefType.string => prefs.getString(pref.key),
      SyncedPrefType.stringList => prefs.getStringList(pref.key),
    };
  }

  /// Writes a value pulled from the server into SharedPreferences, casting it
  /// back to the shape the owning controller's `get…` call expects. Returns
  /// whether anything actually changed, so the caller only invalidates
  /// providers when there is something new to read.
  ///
  /// A value of the wrong JSON type is skipped rather than thrown on: it can
  /// only come from a newer app version having stored something this build
  /// doesn't understand, and a preference blob must never be able to crash an
  /// older client on sign-in.
  Future<bool> _writeLocal(
    SharedPreferences prefs,
    SyncedPref pref,
    Object remote,
  ) async {
    switch (pref.type) {
      case SyncedPrefType.boolean:
        if (remote is! bool || prefs.getBool(pref.key) == remote) return false;
        await prefs.setBool(pref.key, remote);
        return true;
      case SyncedPrefType.number:
        if (remote is! num) return false;
        final value = remote.toDouble();
        if (prefs.getDouble(pref.key) == value) return false;
        await prefs.setDouble(pref.key, value);
        return true;
      case SyncedPrefType.string:
        if (remote is! String || prefs.getString(pref.key) == remote) {
          return false;
        }
        await prefs.setString(pref.key, remote);
        return true;
      case SyncedPrefType.stringList:
        if (remote is! List) return false;
        final value = remote.whereType<String>().toList();
        final current = prefs.getStringList(pref.key);
        // Compared as sets: this key is a membership set of card ids
        // (`DueDateRemindersController` stores `Set<String>.toList()`), so a
        // different ordering is the same preference and must not count as a
        // change that invalidates providers.
        if (current != null &&
            current.toSet().difference(value.toSet()).isEmpty &&
            value.toSet().difference(current.toSet()).isEmpty) {
          return false;
        }
        await prefs.setStringList(pref.key, value);
        return true;
    }
  }

  /// What preference controllers call after they've already written to
  /// SharedPreferences and updated their own state.
  ///
  /// Swallowing the error is the correct behaviour here, not laziness: the
  /// local write has already succeeded, so the user's phone is in the state
  /// they asked for. A failed *mirror* of a theme choice must never surface
  /// an error toast over a settings screen, and must never be retried
  /// aggressively — the next successful [pullAndApply] on any device
  /// reconciles it, and the cost of losing one is that a preference doesn't
  /// travel until it's next changed.
  void pushKeyQuietly(String key) {
    unawaited(pushKey(key).catchError((_) {}));
  }
}

final settingsSyncProvider = Provider<SettingsSync>(SettingsSync.new);

/// Runs the pull once per sign-in transition. Watched from `_AppShell`
/// alongside `cacheLifecycleProvider`/`outboxFlushProvider` (router.dart) —
/// the one widget guaranteed to stay mounted for the app's whole lifetime.
///
/// Keyed off the access token rather than a route or a splash screen so it
/// covers all three ways a session begins: a fresh OTP sign-in, a cold start
/// that resolved a stored refresh token, and a token refresh after expiry.
/// The `previous == null && next != null` guard is what keeps it to actual
/// sign-ins rather than every rotation.
final settingsSyncLifecycleProvider = Provider<void>((ref) {
  var running = false;
  Future<void> sync({bool coldStart = false}) async {
    if (running || ref.read(cacheNamespaceProvider) == 'signed-out') return;
    // WP-C12b: the sign-in/cold-start pull is a background read; skip it while
    // the server is known unreachable (reconnect and resume still run it).
    if (coldStart &&
        ref.read(serverReachabilityProvider).shouldSkipBackgroundReads) {
      return;
    }
    running = true;
    try {
      final applied = await AuthenticatedHttpTimeoutPolicy.runBackground(
        () => ref.read(settingsSyncProvider).pullAndApply(),
      );
      if (applied.isEmpty) return;
      // The preference controllers load from SharedPreferences once, at
      // construction, so a value written underneath them is invisible until
      // they're rebuilt. Invalidating is cheap (each one re-reads a single
      // key) and is the only way to apply a pulled preference without
      // teaching every controller to listen for external writes.
      ref.invalidate(onboardingCompleteProvider);
      ref.invalidate(tutorialSeenProvider);
      ref.invalidate(dueDateRemindersProvider);
      ref.invalidate(themeModeProvider);
      ref.invalidate(textScaleProvider);
      ref.invalidate(numberFormatProvider);
      ref.invalidate(lastSeenAppVersionProvider);
    } catch (_) {
      // Offline, or the server is unreachable. Every preference is already
      // correct locally; changed keys stay marked dirty and go out on the
      // next trigger (reconnect, app resume, sign-in).
    } finally {
      running = false;
    }
  }

  ref.listen<String>(cacheNamespaceProvider, (previous, next) {
    if (previous != 'signed-out' || next == 'signed-out') return;
    unawaited(sync(coldStart: true));
  });
  // WP-C11: also replay dirty preferences and pull when the phone comes back
  // online and when the app returns to the foreground.
  if (kAccountLocalFirst) {
    ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
      if (previous?.valueOrNull == false && next.valueOrNull == true) {
        unawaited(sync());
      }
    });
    final observer = _ResumeObserver(() => unawaited(sync()));
    WidgetsBinding.instance.addObserver(observer);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  }
});

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this._onResume);
  final void Function() _onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResume();
  }
}
