import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:google_fonts/src/google_fonts_base.dart' as google_fonts_base;
import 'package:google_fonts/google_fonts.dart';
import 'package:pandapay/app/design/app_theme.dart';

/// P-01 (offline-first plan): the app's fonts must come from bundled assets so
/// a first-ever offline launch still renders Outfit / IBM Plex Sans, and so the
/// app can switch `GoogleFonts.config.allowRuntimeFetching` off.
///
/// Every weight the app requests is resolved through `google_fonts`' own
/// asset-manifest matching with runtime fetching disabled; a missing asset
/// makes `GoogleFonts.pendingFonts()` throw.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Weights the app actually asks for (grep of `FontWeight.wNNN` in lib/ plus
  // the Material text themes). Outfit: w400..w800. IBM Plex Sans (money
  // figures) is used with w500..w800; w800 resolves to Bold because the family
  // has no ExtraBold.
  const outfitWeights = <FontWeight>[
    FontWeight.w400,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
    FontWeight.w800,
  ];
  const plexWeights = <FontWeight>[
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
    FontWeight.w800,
  ];

  const bundledFiles = <String>[
    'assets/google_fonts/Outfit-Regular.ttf',
    'assets/google_fonts/Outfit-Medium.ttf',
    'assets/google_fonts/Outfit-SemiBold.ttf',
    'assets/google_fonts/Outfit-Bold.ttf',
    'assets/google_fonts/Outfit-ExtraBold.ttf',
    'assets/google_fonts/IBMPlexSans-Medium.ttf',
    'assets/google_fonts/IBMPlexSans-SemiBold.ttf',
    'assets/google_fonts/IBMPlexSans-Bold.ttf',
  ];

  setUp(() {
    // flutter_test_config.dart installs an empty manifest for widget tests;
    // this test needs google_fonts to read the real one.
    google_fonts_base.assetManifest = null;
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  tearDown(() {
    GoogleFonts.config.allowRuntimeFetching = true;
  });

  test('every bundled font file is declared in the asset manifest', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();
    for (final file in bundledFiles) {
      expect(assets, contains(file), reason: '$file is not a declared asset');
    }
    expect(
      assets.any((a) => a.startsWith('assets/google_fonts/') && a.contains('OFL')),
      isTrue,
      reason: 'the SIL OFL licence text must ship next to the fonts',
    );
  });

  test('every Outfit weight the app uses resolves to a bundled asset', () async {
    for (final w in outfitWeights) {
      GoogleFonts.outfit(fontWeight: w);
    }
    await GoogleFonts.pendingFonts();
  });

  test('every IBM Plex Sans weight the app uses resolves to a bundled asset',
      () async {
    for (final w in plexWeights) {
      GoogleFonts.ibmPlexSans(fontWeight: w);
    }
    await GoogleFonts.pendingFonts();
  });

  test('BambooFonts and both app themes resolve offline', () async {
    expect(BambooFonts.useSystemFontsForTests, isFalse);
    for (final w in outfitWeights) {
      BambooFonts.ui(14, weight: w);
      BambooFonts.heading(14, weight: w);
    }
    for (final w in plexWeights) {
      BambooFonts.money(14, weight: w);
    }
    BambooFonts.money(14); // default weight (w800 -> Bold)
    AppTheme.light();
    AppTheme.dark();
    await GoogleFonts.pendingFonts();
  });

  test('a weight with no bundled file fails loudly when fetching is off',
      () async {
    // IBM Plex Sans Regular is deliberately not bundled (no app call uses it):
    // this proves the coverage tests above can actually fail. The failed load
    // also surfaces as an unhandled async error, so catch it in a zone.
    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      GoogleFonts.ibmPlexSans(fontWeight: FontWeight.w400);
      await expectLater(GoogleFonts.pendingFonts(), throwsException);
    }, (error, _) => uncaught.add(error));
    expect(uncaught, isNotEmpty);
  });
}
