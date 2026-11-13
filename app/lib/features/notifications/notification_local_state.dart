import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart'
    show
        cacheNamespaceProvider,
        commandOutboxProvider,
        isOnlineProvider,
        notificationPreferencesProvider,
        responseCacheProvider;
import '../../data/api_exception.dart';
import '../../data/local/response_cache.dart';
import '../../data/notification_preferences_repository.dart';
import 'notification_commands.dart';

/// WP-C4: the phone's own copy of the notification preferences and the muted
/// merchants, kept in the account-scoped [ResponseCache] (keys
/// `<namespace>:notification_preferences` and
/// `<namespace>:notification_muted_merchants`).
///
/// Every local alert (caps, bills, renewals, budgets, geofence ...) is decided
/// against these two, so they must be readable with no network. Reads are
/// cache first with a background refresh; a failed fetch never turns into a
/// cached error, it falls back to the cached copy and then to
/// [NotificationPreferences.defaults].
class NotificationLocalState {
  NotificationLocalState._(this._cache, this.namespace);

  final ResponseCache _cache;
  final String namespace;

  static const preferencesKey = 'notification_preferences';
  static const mutedMerchantsKey = 'notification_muted_merchants';

  /// Null when signed out, or when the local database is not available (the
  /// cache is always best effort).
  static Future<NotificationLocalState?> open(dynamic ref) async {
    try {
      final namespace = ref.read(cacheNamespaceProvider) as String;
      if (namespace == 'signed-out') return null;
      final cache = await ref.read(responseCacheProvider.future) as ResponseCache;
      return NotificationLocalState._(cache, namespace);
    } catch (_) {
      return null;
    }
  }

  String _key(String name) => '$namespace:$name';

  Future<({NotificationPreferences prefs, DateTime fetchedAt})?>
  readPreferences() async {
    try {
      final hit = await _cache.read(_key(preferencesKey));
      if (hit == null) return null;
      final json = jsonDecode(hit.rawJson) as Map<String, dynamic>;
      return (
        prefs: NotificationPreferences.fromJson(json),
        fetchedAt: hit.fetchedAt,
      );
    } catch (_) {
      return null; // unreadable copy counts as no copy
    }
  }

  Future<void> writePreferences(NotificationPreferences prefs) async {
    try {
      await _cache.put(_key(preferencesKey), jsonEncode(prefs.toJson()));
    } catch (_) {}
  }

  Future<({List<MutedMerchant> items, DateTime fetchedAt})?>
  readMutedMerchants() async {
    try {
      final hit = await _cache.read(_key(mutedMerchantsKey));
      if (hit == null) return null;
      final rows = (jsonDecode(hit.rawJson) as List).cast<Map<String, dynamic>>();
      return (
        items: rows.map(MutedMerchant.fromJson).toList(),
        fetchedAt: hit.fetchedAt,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> writeMutedMerchants(List<MutedMerchant> items) async {
    try {
      await _cache.put(
        _key(mutedMerchantsKey),
        jsonEncode([for (final m in items) m.toJson()]),
      );
    } catch (_) {}
  }
}

/// A cached copy younger than this is not refreshed again.
const _refreshAfter = Duration(seconds: 30);

/// The longest a first-ever (uncached) fetch may hold a notification decision.
const _liveFetchTimeout = Duration(seconds: 8);

/// With no cache and no network the defaults are used; ask the server again
/// after this long so a captive-Wi-Fi fallback does not last the whole session.
const _defaultsRecheck = Duration(minutes: 2);

bool _samePrefs(NotificationPreferences a, NotificationPreferences b) =>
    jsonEncode(a.toJson()) == jsonEncode(b.toJson());

bool _sameMuted(List<MutedMerchant> a, List<MutedMerchant> b) =>
    jsonEncode([for (final m in a) m.toJson()]) ==
    jsonEncode([for (final m in b) m.toJson()]);

/// Body of `notificationPreferencesProvider`. Returns null only for a rejected
/// session (as before). Never throws, so the provider can never hold an error.
Future<NotificationPreferences?> loadNotificationPreferences(
  Ref ref,
  NotificationPreferencesRepository repo,
) async {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  // Coming back online re-reads at once; this is what clears a fallback that
  // was taken while the network was down.
  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
    if (next.valueOrNull == true && previous?.valueOrNull == false) {
      ref.invalidateSelf();
    }
  });

  final state = await NotificationLocalState.open(ref);
  final cached = await state?.readPreferences();
  if (cached != null) {
    if (DateTime.now().difference(cached.fetchedAt) >= _refreshAfter) {
      unawaited(() async {
        try {
          // A toggle still waiting to sync is newer than the server's copy.
          final commands = await ref.read(commandOutboxProvider.future);
          if (commands.pendingOf({
            NotificationCommand.updatePreferences,
          }).isNotEmpty) {
            return;
          }
          final fresh = await repo.fetch().timeout(_liveFetchTimeout);
          // A toggle made while the fetch was in flight is newer than this
          // answer (WP-H2): it either queued a command or rewrote the cached
          // copy. Drop the stale server copy.
          final after = await ref.read(commandOutboxProvider.future);
          final rewritten = await state!.readPreferences();
          if (after.pendingOf({NotificationCommand.updatePreferences}).isNotEmpty ||
              rewritten?.fetchedAt != cached.fetchedAt) {
            return;
          }
          await state.writePreferences(fresh);
          if (!disposed && !_samePrefs(fresh, cached.prefs)) {
            ref.invalidateSelf();
          }
        } catch (_) {
          // Offline: the cached copy stays in use.
        }
      }());
    }
    return cached.prefs;
  }

  try {
    final fresh = await repo.fetch().timeout(_liveFetchTimeout);
    await state?.writePreferences(fresh);
    return fresh;
  } catch (error) {
    if (isAuthenticationFailure(error)) return null;
    final timer = Timer(_defaultsRecheck, () {
      if (!disposed) ref.invalidateSelf();
    });
    ref.onDispose(timer.cancel);
    return NotificationPreferences.defaults;
  }
}

/// The muted merchants, cache first with a background refresh; empty when
/// there is neither a network nor a cached copy. [onRefreshed] runs when the
/// background refresh found something different (a screen can rebuild).
Future<List<MutedMerchant>> loadMutedMerchants(
  dynamic ref,
  NotificationPreferencesRepository repo, {
  void Function()? onRefreshed,
}) async {
  final state = await NotificationLocalState.open(ref);
  final cached = await state?.readMutedMerchants();
  if (cached != null) {
    if (DateTime.now().difference(cached.fetchedAt) >= _refreshAfter) {
      final commandsFuture = ref.read(commandOutboxProvider.future);
      unawaited(() async {
        try {
          final commands = await commandsFuture;
          if (commands.pendingOf({
            NotificationCommand.muteMerchant,
            NotificationCommand.unmuteMerchant,
          }).isNotEmpty) {
            return;
          }
          final fresh = await repo.fetchMutedMerchants().timeout(
            _liveFetchTimeout,
          );
          await state!.writeMutedMerchants(fresh);
          if (!_sameMuted(fresh, cached.items)) onRefreshed?.call();
        } catch (_) {}
      }());
    }
    return cached.items;
  }
  try {
    final fresh = await repo.fetchMutedMerchants().timeout(_liveFetchTimeout);
    await state?.writeMutedMerchants(fresh);
    return fresh;
  } catch (_) {
    // A failed check must never block an otherwise-valid notification.
    return const [];
  }
}

/// Used by the write helpers: the invalidation a screen needs after the
/// cached preferences changed under it.
void refreshNotificationPreferences(dynamic ref) {
  try {
    ref.invalidate(notificationPreferencesProvider);
  } catch (_) {}
}
