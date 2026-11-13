import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, AssetMetadata;
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:google_fonts/src/google_fonts_base.dart' as google_fonts_base;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// `google_fonts` downloads Outfit / IBM Plex on first use. Under the widget
/// test binding every HTTP request is answered with status 400, so the
/// download fails and `google_fonts` rethrows an unhandled async error. That
/// error only surfaces if real time passes before the test ends, which makes
/// it a race: widget tests that wait with `tester.runAsync(Future.delayed)`
/// (for SharedPreferences) failed on the Linux CI runner and passed on a
/// developer machine. Tests never need the real fonts (text is laid out with
/// the test font), so make the download simply never answer: no network, no
/// error, no race.
class _NeverRespondingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// The app now bundles Outfit / IBM Plex Sans under `assets/google_fonts/`, and
/// `google_fonts` prefers a bundled asset over everything else. Under the widget
/// test binding that makes the font really load (real async asset + engine
/// work) in the middle of a test, which changes text metrics between layout and
/// paint (`debugSize == size` assertion in `TextPainter.paint`, then a cascade)
/// and can hang `pumpAndSettle`. Widget tests never need the real fonts, so
/// present `google_fonts` with an asset manifest that lists nothing: the font
/// then takes the same inert path it did before the fonts were bundled (the
/// never-answering client below). `test/app/offline_fonts_test.dart` resets this
/// to the real manifest to prove the bundled assets resolve.
class _NoAssetsManifest implements AssetManifest {
  @override
  List<String> listAssets() => const <String>[];

  @override
  List<AssetMetadata>? getAssetVariants(String key) => null;
}

/// `flutter test` runs on the headless `flutter_tester` harness, which never
/// registers real platform plugins — `FlutterSecureStorage`'s default
/// `MethodChannelFlutterSecureStorage` implementation has nothing on the
/// other end of its channel there, so every read/write would hang or throw.
/// Swapping in a plain in-memory `Map`-backed platform implementation here
/// (once, for the whole suite, via this file's `testExecutable`) is the
/// package's own documented way to make it testable — no per-test-file
/// mocking needed for anything that goes through TokenStore.
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final _values = <String, String>{};

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async {
    _values[key] = value;
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => _values[key];

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async =>
      _values.containsKey(key);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {
    _values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(_values);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _values.clear();
  }

  void clear() => _values.clear();
}

/// Largest share of pixels a golden may differ by (0.5%). The committed `ci/`
/// goldens use the Ahem font, but anti-aliased edges and shadows still
/// rasterise a few pixels differently on macOS and on the Linux CI runner
/// (0.27% at most when this was set). A layout or colour change moves far more.
const _goldenTolerance = 0.005;

/// Flutter's own [LocalFileComparator.compare], plus [_goldenTolerance].
class _TolerantGoldenComparator extends LocalFileComparator {
  _TolerantGoldenComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final ComparisonResult result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _goldenTolerance) {
      result.dispose();
      return true;
    }
    final String error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  google_fonts_base.httpClient = _NeverRespondingClient();
  google_fonts_base.assetManifest = _NoAssetsManifest();
  final fakeSecureStorage = _FakeSecureStoragePlatform();
  FlutterSecureStoragePlatform.instance = fakeSecureStorage;
  // A single fake instance backs the whole test run (one process, every
  // file) — without resetting it, one test's rotated tokens leak into the
  // next test's "fresh SharedPreferences.setMockInitialValues" setup,
  // since TokenStore.load()'s legacy-migration path only reads the old
  // plaintext values when secure storage is still empty. setUp here is
  // global across every test declared in every file, same as this
  // function wrapping every file's main().
  setUp(fakeSecureStorage.clear);
  // ApiRequestHeadersClient reads the app version from PackageInfo before each
  // API request; without a mock that platform call never completes under
  // FakeAsync and leaves the request in flight when a widget test ends.
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'PandaPay',
      packageName: 'com.pandapay.app',
      version: '0.0.0-test',
      buildNumber: '0',
      buildSignature: '',
    ),
  );
  final comparator = goldenFileComparator;
  if (comparator is LocalFileComparator) {
    goldenFileComparator = _TolerantGoldenComparator(
      comparator.basedir.resolve('flutter_test_config.dart'),
    );
  }
  // Only the platform-independent `ci/` goldens (Ahem font, colour blocks
  // for text) are committed and compared. Alchemist 0.14 enables the
  // per-platform variants for every host with no CI detection, so on a Linux
  // runner it would look for `goldens/linux/*.png`, which nobody commits (they
  // are machine-specific). Plan C8/D30b.
  return AlchemistConfig.runWithConfig(
    config: const AlchemistConfig(
      platformGoldensConfig: PlatformGoldensConfig(enabled: false),
    ),
    run: testMain,
  );
}
