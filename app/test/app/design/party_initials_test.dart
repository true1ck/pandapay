import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/design/party_avatar.dart';
import 'package:pandapay/app/design/party_initials.dart';

void main() {
  group('PartyInitials', () {
    test('a business is its first two words, a single word is one letter', () {
      expect(PartyInitials.of('OWNLY'), 'O');
      expect(PartyInitials.of('SHILPA'), 'S');
      expect(PartyInitials.of('MANGALORESEAPARK'), 'M');
      expect(PartyInitials.of('AVIGHNA ENTERPRISE'), 'AE');
      expect(PartyInitials.of('Shree Ganesh Kirana Stores'), 'SG');
    });

    test('a person is first name plus last name', () {
      expect(PartyInitials.of('Rahul Kumar Sharma', person: true), 'RS');
      expect(PartyInitials.of('Transfer to RAMESH KUMAR', person: true), 'RK');
      expect(PartyInitials.of('Transfer to Ramesh', person: true), 'R');
    });

    test('company suffixes and titles do not become initials', () {
      expect(PartyInitials.of('ACME TECHNOLOGIES PVT LTD'), 'AT');
      expect(PartyInitials.of('Dr Mehta Clinic'), 'MC');
      expect(PartyInitials.of('Mr Anil Gupta', person: true), 'AG');
      expect(PartyInitials.of('Pvt Ltd'), 'PL');
    });

    test('punctuation splits words and is never an initial', () {
      expect(PartyInitials.of('  *Anand-Bhavan  '), 'AB');
      expect(PartyInitials.of('7 Eleven'), '7E');
      expect(PartyInitials.of('दीपक शर्मा', person: true), 'दश');
    });

    test('a name that says nothing gives no initials', () {
      for (final name in [
        null,
        '',
        '   ',
        'UNKNOWN',
        'Unknown merchant',
        'Unknown sender',
        '9876543210',
        'rahul@okhdfc',
        'Transfer to',
        '---',
      ]) {
        expect(PartyInitials.of(name), '', reason: '$name');
      }
    });
  });

  group('PartyAvatar initials', () {
    Future<void> pump(WidgetTester tester, Widget child) =>
        tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));

    setUp(() => BambooFonts.useSystemFontsForTests = true);
    tearDown(() => BambooFonts.useSystemFontsForTests = false);

    testWidgets('a shop with a name shows its initials, not the icon', (
      tester,
    ) async {
      await pump(
        tester,
        const PartyAvatar(AvatarKind.business, name: 'AVIGHNA ENTERPRISE'),
      );
      expect(find.text('AE'), findsOneWidget);
      expect(find.byIcon(AvatarKind.business.icon), findsNothing);
    });

    testWidgets('a person shows first and last initials', (tester) async {
      await pump(
        tester,
        const PartyAvatar(AvatarKind.person, name: 'Transfer to RAMESH KUMAR'),
      );
      expect(find.text('RK'), findsOneWidget);
      expect(find.byIcon(AvatarKind.person.icon), findsNothing);
    });

    testWidgets('the tile keeps its tint: only the mark changes', (
      tester,
    ) async {
      await pump(tester, const PartyAvatar(AvatarKind.business));
      final plain = tester.widget<Container>(
        find.descendant(
          of: find.byType(TintedIconTile),
          matching: find.byType(Container),
        ),
      );
      await pump(
        tester,
        const PartyAvatar(AvatarKind.business, name: 'COMPASS'),
      );
      final lettered = tester.widget<Container>(
        find.descendant(
          of: find.byType(TintedIconTile),
          matching: find.byType(Container),
        ),
      );
      expect(lettered.decoration, plain.decoration);
    });

    testWidgets('no name, or a name that says nothing, keeps the icon', (
      tester,
    ) async {
      for (final name in [null, 'Unknown merchant', '98765 43210']) {
        await pump(tester, PartyAvatar(AvatarKind.business, name: name));
        expect(
          find.byIcon(AvatarKind.business.icon),
          findsOneWidget,
          reason: '$name',
        );
      }
    });

    testWidgets('kinds that are not a person or shop keep their icon', (
      tester,
    ) async {
      await pump(
        tester,
        const PartyAvatar(AvatarKind.card, name: 'HDFC Credit Card'),
      );
      expect(find.byIcon(AvatarKind.card.icon), findsOneWidget);
      expect(find.text('HC'), findsNothing);
    });
  });
}
