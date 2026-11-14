import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/design/merchant_brand.dart';
import 'package:pandapay/app/design/merchant_brand_colors.dart';
import 'package:pandapay/app/design/party_avatar.dart';
import 'package:pandapay/app/design/tile_tones.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
}

Future<TileTones> _tones(
  WidgetTester tester,
  Color? tone, {
  ThemeData? theme,
  bool onSlate = false,
}) async {
  late TileTones tones;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? ThemeData.light(),
      home: Builder(
        builder: (context) {
          tones = TileTones.of(context, tone, onSlate: onSlate);
          return const SizedBox();
        },
      ),
    ),
  );
  return tones;
}

void main() {
  final surfaces = <String, (ThemeData, bool)>{
    'light': (ThemeData.light(), false),
    'dark': (ThemeData.dark(), false),
    'slate': (ThemeData.light(), true),
  };

  testWidgets(
    'every brand mark is readable on its own tile, on every surface',
    (tester) async {
      final unreadable = <String>[];
      for (final MapEntry(key: surface, value: (theme, onSlate))
          in surfaces.entries) {
        for (final brand in MerchantBrand.values) {
          final tones = await _tones(
            tester,
            brand.color,
            theme: theme,
            onSlate: onSlate,
          );
          final ratio = _contrast(tones.mark, tones.background);
          // 3:1 is the floor for a graphic; neutral ink should be far above it.
          final floor = brand.color == null ? 7.0 : 3.0;
          if (ratio < floor) {
            unreadable.add(
              '${brand.name} on $surface: ${ratio.toStringAsFixed(2)}',
            );
          }
        }
      }
      expect(unreadable, isEmpty);
    },
  );

  testWidgets('a very pale brand colour becomes the tile, with a dark mark', (
    tester,
  ) async {
    final tones = await _tones(tester, MerchantBrand.blinkit.color);
    expect(tones.background, MerchantBrand.blinkit.color);
    expect(tones.mark, BambooInk.ink900);
  });

  testWidgets('a mid-strength brand colour keeps its hue as a soft tint', (
    tester,
  ) async {
    final swiggy = MerchantBrand.swiggy.color!;
    final tones = await _tones(tester, swiggy);
    // Tinted, not solid: lighter than the brand colour, and the mark is orange.
    expect(
      tones.background.computeLuminance(),
      greaterThan(swiggy.computeLuminance()),
    );
    expect(
      HSLColor.fromColor(tones.mark).hue,
      closeTo(HSLColor.fromColor(swiggy).hue, 12),
    );
  });

  testWidgets('a brand with black or white artwork gets a neutral tile', (
    tester,
  ) async {
    expect(MerchantBrand.apple.color, isNull);
    final tones = await _tones(tester, MerchantBrand.apple.color);
    expect(tones.mark, BambooInk.ink900);
    expect(tones.background, BambooInk.paperMuted);
  });

  test('most brands carry a colour; only the deliberate ones are neutral', () {
    final neutral = [
      for (final b in MerchantBrand.values)
        if (b.color == null) b.name,
    ];
    expect(neutral.length, lessThan(MerchantBrand.values.length ~/ 4));
    expect(neutral, containsAll(['apple', 'uber', 'steam', 'openai']));
  });

  test('every avatar kind has an icon of its own', () {
    final icons = {for (final k in AvatarKind.values) k.icon.codePoint};
    expect(icons.length, AvatarKind.values.length);
  });

  test('a person, a shop and a card are told apart by hue as well as icon', () {
    final hues = {
      AvatarKind.person.tone,
      AvatarKind.business.tone,
      AvatarKind.card.tone,
      AvatarKind.bank.tone,
    };
    expect(hues.length, 4);
  });

  testWidgets('every avatar is readable on light, dark and slate', (
    tester,
  ) async {
    final unreadable = <String>[];
    for (final MapEntry(key: surface, value: (theme, onSlate))
        in surfaces.entries) {
      for (final kind in AvatarKind.values) {
        final tones = await _tones(
          tester,
          kind.tone,
          theme: theme,
          onSlate: onSlate,
        );
        final ratio = _contrast(tones.mark, tones.background);
        if (ratio < 3.0) {
          unreadable.add(
            '${kind.name} on $surface: ${ratio.toStringAsFixed(2)}',
          );
        }
      }
    }
    expect(unreadable, isEmpty);
  });
}
