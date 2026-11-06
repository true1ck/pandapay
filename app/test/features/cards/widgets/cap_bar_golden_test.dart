import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/cards/cap_progress.dart';
import 'package:pandapay/features/cards/widgets/cap_bar.dart';

import '../../../support/v2_catalogue_fixtures.dart';

/// Alchemist golden for [CapBar]: every unit, the colour bands, the
/// approximate reset, and the "Updating" state.
final _now = DateTime(2026, 11, 15);

CapProgress _progress({
  required Object? native,
  String capKind = 'bonus_points',
  num capAmount = 1500,
  bool approximate = false,
}) {
  final product = parseCard(
    v2CardJson('p', capKind: capKind, capAmount: capAmount),
  );
  final owned = parseUserCard(
    userCardJson(
      'uc',
      'p',
      capStates: [
        capStateRowJson(
          'p-cap',
          consumed: 0,
          consumedNative: native,
          capKind: capKind,
          capAmount: capAmount,
          periodStart: '2026-11-01',
          periodEnd: '2026-11-30',
          approximate: approximate,
        ),
      ],
    ),
  );
  return capProgressFor(
    product: product,
    cap: product.capRules.single,
    owned: owned,
    now: _now,
  )!;
}

GoldenTestScenario _scenario(String name, CapProgress progress, {String? title}) =>
    GoldenTestScenario(
      name: name,
      child: SizedBox(
        width: 340,
        child: CapBar(progress: progress, title: title),
      ),
    );

void main() {
  setUpAll(() => BambooFonts.useSystemFontsForTests = true);
  tearDownAll(() => BambooFonts.useSystemFontsForTests = false);

  goldenTest(
    'CapBar renders each unit, colour band and the updating state',
    fileName: 'cap_bar',
    constraints: const BoxConstraints(maxWidth: 800),
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        _scenario(
          'points, room left',
          _progress(native: 300),
          title: 'Dining bonus points',
        ),
        _scenario(
          'points, past 80%',
          _progress(native: 1240),
          title: 'Dining bonus points',
        ),
        _scenario(
          'cashback, past 90%',
          _progress(
            native: 480,
            capKind: 'bonus_cashback',
            capAmount: 500,
          ),
          title: 'Online cashback',
        ),
        _scenario(
          'spend, reached',
          _progress(
            native: 20000,
            capKind: 'eligible_spend',
            capAmount: 20000,
          ),
          title: 'Fuel eligible spend',
        ),
        _scenario(
          'count of uses',
          _progress(native: 2, capKind: 'txn_count', capAmount: 3),
          title: 'Offers per month',
        ),
        _scenario(
          'total cap, approximate reset',
          _progress(
            native: 900,
            capKind: 'total_points',
            approximate: true,
          ),
          title: 'Total points',
        ),
        _scenario(
          'updating (native figure unknown)',
          _progress(native: null),
          title: 'Dining bonus points',
        ),
        _scenario('no title', _progress(native: 750)),
      ],
    ),
  );
}
