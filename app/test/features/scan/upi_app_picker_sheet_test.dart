import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/upi_payment_service.dart';
import 'package:pandapay/features/scan/upi_app_picker_sheet.dart';

const _gpay = UpiApp(packageName: 'gpay', name: 'Google Pay');
const _scapia = UpiApp(
  packageName: 'scapia',
  name: 'Scapia',
  prefillsPayment: false,
  logoAsset: 'assets/upi_apps/scapia.png',
);
const _tataNeu = UpiApp(packageName: 'tataneu', name: 'Tata Neu');
const _cred = UpiApp(packageName: 'cred', name: 'CRED');

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  group('which app a card is usually linked in', () {
    test('a card named for an app matches that app', () {
      expect(upiAppMatchesCard(_scapia, 'Scapia Federal Bank Credit Card'), isTrue);
      expect(upiAppMatchesCard(_tataNeu, 'Tata Neu Infinity HDFC Bank Credit Card'), isTrue);
      expect(
        upiAppMatchesCard(
          const UpiApp(packageName: 'p', name: 'PhonePe'),
          'SBI Card PhonePe PURPLE',
        ),
        isTrue,
      );
    });

    test('Android names with extra words still match', () {
      expect(
        upiAppMatchesCard(
          const UpiApp(packageName: 'a', name: 'Amazon Pay UPI'),
          'Amazon Pay ICICI Bank Credit Card',
        ),
        isTrue,
      );
    });

    test('a different app, or a card that is not named for one, does not match', () {
      expect(upiAppMatchesCard(_gpay, 'Scapia Federal Bank Credit Card'), isFalse);
      expect(upiAppMatchesCard(_scapia, 'HDFC Millennia Credit Card'), isFalse);
      expect(upiAppMatchesCard(_scapia, 'your bank account'), isFalse);
    });

    test('the word Credit is not the CRED app', () {
      expect(upiAppMatchesCard(_cred, 'Scapia Federal Bank Credit Card'), isFalse);
      expect(upiAppMatchesCard(_cred, 'Axis Bank Credit Card'), isFalse);
    });
  });

  group('the chooser', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required List<UpiApp> apps,
      String cardName = 'Scapia Federal Bank Credit Card',
      bool fromBankAccount = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: UpiAppPickerSheet(
              apps: apps,
              cardName: cardName,
              fromBankAccount: fromBankAccount,
            ),
          ),
        ),
      ),
    );

    testWidgets('shows what is being paid with in its own box', (tester) async {
      await pumpSheet(tester, apps: const [_gpay, _scapia]);
      expect(find.text('Open which UPI app?'), findsOneWidget);
      expect(find.text('Paying with'), findsOneWidget);
      expect(find.text('Scapia Federal Bank Credit Card'), findsOneWidget);
    });

    testWidgets('the app that matches the card comes first and is marked', (tester) async {
      await pumpSheet(tester, apps: const [_gpay, _cred, _scapia]);
      expect(find.text('Matches this card'), findsOneWidget);
      final names = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => ((t.title as Text).data))
          .toList();
      expect(names, ['Scapia', 'Google Pay', 'CRED']);
    });

    testWidgets('a bank account payment marks nothing and says so', (tester) async {
      await pumpSheet(
        tester,
        apps: const [_gpay, _scapia],
        cardName: 'your bank account',
        fromBankAccount: true,
      );
      expect(find.text('Your bank account'), findsOneWidget);
      expect(find.text('Matches this card'), findsNothing);
      final names = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => ((t.title as Text).data))
          .toList();
      expect(names, ['Google Pay', 'Scapia']);
    });

    testWidgets('tapping an app returns it', (tester) async {
      UpiApp? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => chosen = await UpiAppPickerSheet.show(
                  context,
                  apps: const [_gpay, _scapia],
                  cardName: 'Scapia Federal Bank Credit Card',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();
      expect(chosen, _gpay);
    });

    testWidgets('uses the real icon on Android and the bundled logo on iOS', (tester) async {
      final png = Uint8List.fromList(const [
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
        8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255,
        255, 63, 0, 5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
        130,
      ]);
      await pumpSheet(
        tester,
        apps: [
          UpiApp(packageName: 'android', name: 'On Android', iconPng: png),
          _scapia,
          _gpay,
        ],
        cardName: 'your bank account',
        fromBankAccount: true,
      );
      final providers = tester.widgetList<Image>(find.byType(Image)).map((i) => i.image).toList();
      expect(providers.whereType<MemoryImage>(), hasLength(1));
      expect(providers.whereType<AssetImage>().single.assetName, 'assets/upi_apps/scapia.png');
      // The app with neither gets the plain wallet.
      expect(find.byIcon(Icons.account_balance_wallet_rounded), findsOneWidget);
    });
  });
}
