import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';

/// The avatar the person has chosen: the preset id and, when there is one, the
/// photo bytes already downloaded.
class AvatarState {
  final String? preset;
  final Uint8List? photo;
  const AvatarState({this.preset, this.photo});
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
    return AvatarState(preset: info.preset, photo: photo);
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
