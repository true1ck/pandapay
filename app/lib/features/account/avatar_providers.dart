import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import 'avatar_cache.dart';

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
bool _sameAvatar(AvatarState a, AvatarState b) =>
    a.preset == b.preset &&
    a.sharePhoto == b.sharePhoto &&
    (a.photo?.length ?? -1) == (b.photo?.length ?? -1);

/// Clears the saved own-avatar copy (called after the person changes it, so the
/// next read is the live one rather than the previous picture).
Future<void> clearOwnAvatarCache(dynamic ref) async =>
    (await AvatarCache.open(ref))?.clear('own');

final avatarProvider = FutureProvider<AvatarState?>((ref) async {
  final api = ref.watch(avatarApiProvider);
  if (api == null) return null;
  final cache = await AvatarCache.open(ref);
  Future<AvatarState?> fetch() async {
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
  }

  if (cache == null) {
    try {
      return await fetch();
    } catch (_) {
      return null;
    }
  }
  return cacheFirst<AvatarState>(
    cached: () => cache.read('own'),
    fetch: fetch,
    save: (s) => cache.write('own', s),
    same: _sameAvatar,
    onChanged: ref.invalidateSelf,
  );
});

/// Another Split member's avatar, by profile id. Saved on the phone and shown
/// cache-first (WP-C11). Null on any failure or when the server has nothing to
/// show: it is decorative, so every screen then draws the initial letter and
/// never an error.
final memberAvatarProvider = FutureProvider.family<AvatarState?, String>((ref, profileId) async {
  final api = ref.watch(memberAvatarApiProvider);
  if (api == null) return null;
  final cache = await AvatarCache.open(ref);
  Future<AvatarState?> fetch() async {
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
  }

  if (cache == null) {
    try {
      return await fetch();
    } catch (_) {
      return null;
    }
  }
  return cacheFirst<AvatarState>(
    cached: () => cache.read('member:$profileId'),
    fetch: fetch,
    save: (s) => cache.write('member:$profileId', s),
    same: _sameAvatar,
    onChanged: () => ref.invalidateSelf(),
  );
});

/// Another Split member's own PandaPay name, by profile id: what they call
/// themselves, shown under the name the signed-in person saved for them. Saved
/// on the phone (WP-C11). Null on any failure or when there is none to show.
final memberProfileNameProvider = FutureProvider.family<String?, String>((ref, profileId) async {
  final api = ref.watch(memberAvatarApiProvider);
  if (api == null) return null;
  final cache = await AvatarCache.open(ref);
  return cacheFirst<String>(
    cached: () async => cache == null ? null : await cache.readText('name:$profileId'),
    fetch: () => api.profileName(profileId),
    save: (n) async => cache?.writeText('name:$profileId', n),
    same: (a, b) => a == b,
    onChanged: () => ref.invalidateSelf(),
  );
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
