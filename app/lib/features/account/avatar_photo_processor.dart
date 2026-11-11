import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The side, in pixels, of the square photo that is uploaded. Big enough to look
/// sharp at the largest size the app draws it (~96 logical px at 3x), small enough
/// to stay a few tens of KB.
const int avatarPhotoSide = 384;

const int _jpegQuality = 82;

/// Why a chosen picture could not be turned into an avatar.
class AvatarPhotoException implements Exception {
  final String message;
  const AvatarPhotoException(this.message);
  @override
  String toString() => message;
}

/// Turns whatever the person picked into the upload: the camera's rotation is
/// applied, the middle square is cropped out, it is shrunk to [avatarPhotoSide]
/// and re-encoded as JPEG. Re-encoding also drops everything the original carried
/// besides pixels (location, device, time). Runs off the UI isolate: decoding a
/// 12-megapixel photo is far too slow for a frame.
Future<Uint8List> prepareAvatarPhoto(Uint8List original) {
  return Isolate.run(() => _prepare(original));
}

Uint8List _prepare(Uint8List original) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(original);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) {
    throw const AvatarPhotoException('That file isn’t a photo we can use. Choose a JPEG or PNG.');
  }
  final upright = img.bakeOrientation(decoded);
  final side = upright.width < upright.height ? upright.width : upright.height;
  if (side < 32) {
    throw const AvatarPhotoException('That photo is too small. Choose a larger one.');
  }
  final square = img.copyCrop(
    upright,
    x: (upright.width - side) ~/ 2,
    y: (upright.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final sized = side > avatarPhotoSide
      ? img.copyResize(
          square,
          width: avatarPhotoSide,
          height: avatarPhotoSide,
          interpolation: img.Interpolation.average,
        )
      : square;
  return Uint8List.fromList(img.encodeJpg(sized, quality: _jpegQuality));
}
