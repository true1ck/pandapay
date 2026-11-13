import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/avatar_api.dart';

/// The avatar the person has chosen: the preset id and, when there is one, the
/// photo bytes already downloaded.
class AvatarState {
  final String? preset;
  final Uint8List? photo;

  /// Whether Split members may see the photo (the owner's own setting).
  final bool sharePhoto;
  const AvatarState({this.preset, this.photo, this.sharePhoto = false});
}

/// The signed-in person's avatar. Null while signed out or when it cannot be
/// loaded: every screen then simply shows the initial letter, as it always did,
/// instead of an error for something decorative.
final avatarProvider = FutureProvider<AvatarState?>((ref) async {
  final api = ref.watch(avatarApiProvider);
  if (api == null) return null;
  try {
    final info = await api.info();
    Uint8List? photo;
    if (info.hasPhoto) {
      try {
        photo = await api.fetchPhoto();
      } catch (_) {
        photo = null;
      }
    }
    return AvatarState(preset: info.preset, photo: photo, sharePhoto: info.sharePhoto);
  } catch (_) {
    return null;
  }
});

/// The avatar shown to the owner. An unsynced preset takes precedence over a
/// server read, which can still contain the avatar it replaces.
final displayAvatarProvider = Provider<AvatarState?>((ref) {
  final local = ref.watch(avatarPresetSelectionProvider);
  final remote = ref.watch(avatarProvider);
  if (local != null && (local.pending || remote.isLoading)) {
    return AvatarState(preset: local.preset);
  }
  return remote.valueOrNull ??
      (local == null ? null : AvatarState(preset: local.preset));
});

final avatarPresetSelectionProvider =
    StateNotifierProvider<AvatarPresetController, AvatarPresetSelection?>((
      ref,
    ) {
      final api = ref.watch(avatarApiProvider);
      final namespace = ref.watch(cacheNamespaceProvider);
      final controller = AvatarPresetController(
        api,
        'avatar-preset:${api?.authBaseUrl}:$namespace',
        () => ref.read(isOnlineProvider).valueOrNull == false,
        () => ref.invalidate(avatarProvider),
      );
      if (api != null) {
        ref.listen(isOnlineProvider, (_, next) {
          if (next.valueOrNull == true) unawaited(controller.sync());
        });
        final lifecycle = AppLifecycleListener(
          onResume: () => unawaited(controller.sync()),
        );
        ref.onDispose(lifecycle.dispose);
      }
      return controller;
    });

class AvatarPresetSelection {
  const AvatarPresetSelection(this.preset, {required this.pending, this.error});

  final String? preset;
  final bool pending;
  final String? error;
}

class AvatarPresetController extends StateNotifier<AvatarPresetSelection?> {
  AvatarPresetController(this._api, this._key, this._isOffline, this._refreshAvatar)
    : super(null) {
    if (_api != null) unawaited(_restore());
  }

  final AvatarApi? _api;
  final String _key;
  final bool Function() _isOffline;
  final void Function() _refreshAvatar;
  Future<void>? _syncInFlight;
  Future<void>? _localWrite;
  Timer? _retry;
  bool _uploadingPhoto = false;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || state != null) return;
      final saved = prefs.getString(_key);
      if (saved == null) return;
      final json = jsonDecode(saved) as Map<String, dynamic>;
      state = AvatarPresetSelection(
        json['preset'] as String?,
        pending: json['pending'] == true,
      );
    } catch (_) {
      return;
    }
    await sync();
  }

  Future<void> choose(String? preset) async {
    final choice = AvatarPresetSelection(preset, pending: true);
    state = choice;
    final write = _persist(choice, ifCurrent: choice);
    _localWrite = write;
    try {
      await write;
    } catch (_) {
      if (mounted && identical(state, choice)) state = null;
      rethrow;
    } finally {
      if (identical(_localWrite, write)) _localWrite = null;
    }
    if (mounted) unawaited(sync());
  }

  Future<void> _persist(
    AvatarPresetSelection? value, {
    required AvatarPresetSelection? ifCurrent,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || !identical(state, ifCurrent)) return;
    final saved = value == null
        ? await prefs.remove(_key)
        : await prefs.setString(
            _key,
            jsonEncode({'preset': value.preset, 'pending': value.pending}),
          );
    if (!saved) {
      throw StateError(
        'Could not save your avatar on this phone. Please try again.',
      );
    }
  }

  Future<void> sync() async {
    if (!mounted ||
        _api == null ||
        _isOffline() ||
        _uploadingPhoto ||
        state?.pending != true) {
      return;
    }
    final inFlight = _syncInFlight;
    if (inFlight != null) return inFlight;
    _retry?.cancel();
    final sending = _sendPending(_api);
    _syncInFlight = sending;
    try {
      await sending;
    } finally {
      _syncInFlight = null;
    }
  }

  Future<void> _sendPending(AvatarApi api) async {
    while (mounted && !_uploadingPhoto && !_isOffline()) {
      final choice = state;
      if (choice == null || !choice.pending) return;
      try {
        await _localWrite;
        if (!mounted || !identical(state, choice)) continue;
        if (_uploadingPhoto || _isOffline()) return;
        final remote = await api.setPreset(choice.preset);
        if (!mounted) return;
        // The server can have a photo even when the phone hasn't loaded it yet.
        if (remote.hasPhoto) await api.removePhoto();
        if (!mounted || !identical(state, choice)) continue;
        final confirmed = AvatarPresetSelection(choice.preset, pending: false);
        await _persist(confirmed, ifCurrent: choice);
        if (!mounted || !identical(state, choice)) continue;
        _refreshAvatar();
        state = confirmed;
      } catch (error) {
        if (!mounted || !identical(state, choice)) continue;
        final retryable =
            isTransientNetworkFailure(error) ||
            (error is ApiException && error.statusCode == 429);
        if (retryable) {
          _retry = Timer(const Duration(minutes: 1), () => unawaited(sync()));
        } else {
          state = AvatarPresetSelection(
            choice.preset,
            pending: true,
            error: userFacingErrorMessage(error),
          );
        }
        return;
      }
    }
  }

  /// Wait for any preset request already in flight before replacing it with a
  /// photo. Otherwise the preset request could delete the newly uploaded photo.
  Future<void> uploadPhoto(Uint8List jpeg) async {
    final api = _api;
    if (api == null) return;
    _uploadingPhoto = true;
    try {
      await _syncInFlight;
      if (!mounted) return;
      await api.uploadPhoto(jpeg);
      if (!mounted) return;
      if (state != null) await _persist(null, ifCurrent: state);
      if (!mounted) return;
      state = null;
    } finally {
      _uploadingPhoto = false;
      if (mounted) unawaited(sync());
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }
}

/// Another Split member's avatar, by profile id. Cached for the session (and
/// reset on account switch, since the API provider is rebuilt). Null on any
/// failure or when the server has nothing to show: it is decorative, so every
/// screen then draws the initial letter and never an error.
final memberAvatarProvider = FutureProvider.family<AvatarState?, String>((ref, profileId) async {
  final api = ref.watch(memberAvatarApiProvider);
  if (api == null) return null;
  try {
    final info = await api.info(profileId);
    if (info == null) return null;
    Uint8List? photo;
    if (info.hasPhoto) {
      try {
        photo = await api.photo(profileId);
      } catch (_) {
        photo = null;
      }
    }
    return AvatarState(preset: info.preset, photo: photo);
  } catch (_) {
    return null;
  }
});

/// Another Split member's own PandaPay name, by profile id: what they call
/// themselves, shown under the name the signed-in person saved for them. Cached
/// for the session. Null on any failure or when there is none to show.
final memberProfileNameProvider = FutureProvider.family<String?, String>((ref, profileId) async {
  final api = ref.watch(memberAvatarApiProvider);
  if (api == null) return null;
  try {
    return await api.profileName(profileId);
  } catch (_) {
    return null;
  }
});

enum AvatarPhotoSource { gallery, camera }

/// Lets the person pick or take a photo. A provider so tests can replace the
/// system picker with fixed bytes.
abstract class AvatarPhotoPicker {
  /// The picked picture's bytes, or null when the person backed out.
  Future<Uint8List?> pick(AvatarPhotoSource source);
}

class SystemAvatarPhotoPicker implements AvatarPhotoPicker {
  final ImagePicker _picker = ImagePicker();

  @override
  Future<Uint8List?> pick(AvatarPhotoSource source) async {
    final file = await _picker.pickImage(
      source: source == AvatarPhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
      // Shrinks before decoding so a 50-megapixel photo cannot exhaust memory;
      // the exact square crop and size are done afterwards.
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 90,
    );
    return file == null ? null : await file.readAsBytes();
  }
}

final avatarPhotoPickerProvider = Provider<AvatarPhotoPicker>((ref) => SystemAvatarPhotoPicker());
