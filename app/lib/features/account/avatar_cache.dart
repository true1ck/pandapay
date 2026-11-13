import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../app/providers.dart' show cacheNamespaceProvider, responseCacheProvider;
import '../../data/connectivity/known_connectivity.dart';
import 'account_local_first.dart';
import 'avatar_providers.dart' show AvatarState;

/// WP-C11 (R-07): avatars and member names are kept in the account-scoped
/// response cache so they paint at once and never wait 15-20 s on a dead
/// network. [ref] is a provider `Ref`.
class AvatarCache {
  AvatarCache._(this._cache, this._prefix);
  final dynamic _cache;
  final String _prefix;

  static Future<AvatarCache?> open(dynamic ref) async {
    if (!kAccountLocalFirst) return null;
    try {
      final cache = await ref.read(responseCacheProvider.future);
      return AvatarCache._(cache, '${ref.read(cacheNamespaceProvider)}:avatar:');
    } catch (_) {
      return null;
    }
  }

  Future<AvatarState?> read(String key) async {
    try {
      final raw = await _cache.get('$_prefix$key') as String?;
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final photo = m['photo'] as String?;
      return AvatarState(
        preset: m['preset'] as String?,
        photo: photo == null ? null : base64Decode(photo),
        sharePhoto: m['share'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, AvatarState s) async {
    try {
      await _cache.put(
        '$_prefix$key',
        jsonEncode({
          'preset': s.preset,
          'photo': s.photo == null ? null : base64Encode(s.photo as Uint8List),
          'share': s.sharePhoto,
        }),
      );
    } catch (_) {}
  }

  Future<String?> readText(String key) async {
    try {
      return await _cache.get('$_prefix$key') as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeText(String key, String value) async {
    try {
      await _cache.put('$_prefix$key', value);
    } catch (_) {}
  }

  Future<void> clear(String key) async {
    try {
      await _cache.clear('$_prefix$key');
    } catch (_) {}
  }
}

/// Cache-first load: the saved copy at once, refreshed in the background
/// (skipped while known offline); with no saved copy, one live attempt bounded
/// by [timeout]. Failures give null, as the avatar providers always did.
Future<T?> cacheFirst<T>({
  required Future<T?> Function() cached,
  required Future<T?> Function() fetch,
  required Future<void> Function(T) save,
  required bool Function(T a, T b) same,
  required void Function() onChanged,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final saved = await cached();
  if (saved != null) {
    if (!KnownConnectivity.knownOffline) {
      unawaited(
        fetch().timeout(timeout).then((fresh) async {
          if (fresh == null) return;
          if (!same(saved, fresh)) {
            await save(fresh);
            onChanged();
          }
        }).catchError((_) {}),
      );
    }
    return saved;
  }
  if (KnownConnectivity.knownOffline) return null;
  try {
    final fresh = await fetch().timeout(timeout);
    if (fresh != null) await save(fresh);
    return fresh;
  } catch (_) {
    return null;
  }
}
