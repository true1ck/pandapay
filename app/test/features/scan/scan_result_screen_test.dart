import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/upi_payment_service.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/scan/scan_result_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(
  String id, {
  bool isUpiLinkable = true,
  double rate = 0.02,
  CardNetwork network = CardNetwork.visa,
}) => CardProduct(
  id: id,
  name: id,
  network: network,
  isUpiLinkable: isUpiLinkable,
  rewardRules: [
    RewardRule(
      id: '$id-rule',
      priority: 1,
      unit: RewardUnit.cashbackPercent,
      rate: rate,
    ),
  ],
);

class _FakeUpiService implements UpiPaymentService {
  _FakeUpiService({this.apps = const []});

  final List<UpiApp> apps;
  bool openResult = true;
  bool shareResult = true;
  final opened = <String>[];
  final shared = <({String package, String data})>[];

  @override
  Future<List<UpiApp>> installedApps() async => apps;

  @override
  Future<bool> openApp(String packageName) async {
    opened.add(packageName);
    return openResult;
  }

  @override
  Future<bool> shareQr({
    required String packageName,
    required String qrData,
  }) async {
    shared.add((package: packageName, data: qrData));
    return shareResult;
  }
}

const _gpay = UpiApp(
  packageName: 'com.google.android.apps.nbu.paisa.user',
  name: 'Google Pay',
);

UserCard _owned(String cardProductId) => UserCard(
  id: 'uc-$cardProductId',
  cardProductId: cardProductId,
  cardName: cardProductId,
  isDefault: false,
);

const _slice = UpiApp(packageName: 'in.slice.android', name: 'Slice');

const _shopQr = ParsedUpiQr(
  pa: 'shop@okhdfcbank',
  pn: 'DMart',
  mc: '5411',
  isLikelyP2P: false,
);

/// The last text the screen put on the clipboard, or null if none.
String? _clipboard;

void _mockClipboard(WidgetTester tester) {
  _clipboard = null;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        _clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

Future<void> _pumpScan(
  WidgetTester tester,
  _FakeUpiService fake, {
  ParsedUpiQr parsed = _shopQr,
  CardNetwork network = CardNetwork.visa,
}) async {
  _mockClipboard(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        upiPaymentServiceProvider.overrideWithValue(fake),
        catalogueProvider.overrideWith(
          (ref) async => [_card('c1', rate: 0.03, network: network)],
        ),
        categoriesProvider.overrideWith((ref) async => const []),
        userCardsProvider.overrideWith((ref) async => [_owned('c1')]),
        cardOverridesProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(home: ScanResultScreen(parsed: parsed)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapPay(WidgetTester tester) async {
  final pay = find.widgetWithText(FilledButton, 'Pay with c1');
  await tester.ensureVisible(pay);
  await tester.pumpAndSettle();
  await tester.tap(pay);
  await tester.pumpAndSettle();
}

Future<void> _enterAmountAndPay(WidgetTester tester, String amount) async {
  await tester.enterText(find.byType(TextField).last, amount);
  await tester.pump();
  await _tapPay(tester);
}

void main() {
  testWidgets(
    'a P2P-detected QR shows the personal-transfer notice, not a card list',
    (tester) async {
      const parsed = ParsedUpiQr(
        pa: 'friend@okaxis',
        pn: 'A Friend',
        isLikelyP2P: true,
      );
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: ScanResultScreen(parsed: parsed)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text("Credit cards can't be used for personal transfers"),
        findsOneWidget,
      );
    },
  );

  testWidgets('a merchant QR pre-fills the merchant name field from pn', (
    tester,
  ) async {
    const parsed = ParsedUpiQr(
      pa: 'shop@okhdfcbank',
      pn: 'DMart Powai',
      mc: '5411',
      isLikelyP2P: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'DMart Powai'), findsOneWidget);
  });

  testWidgets('a no-MCC fuel merchant auto-selects Fuel at scan time', (
    tester,
  ) async {
    const parsed = ParsedUpiQr(
      pa: 'merchant@okaxis',
      pn: 'QUALITY FUEL STATION',
      isLikelyP2P: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith(
            (ref) async => const [
              SpendCategory(id: 'fuel-id', slug: 'fuel', name: 'Fuel'),
            ],
          ),
          userCardsProvider.overrideWith((ref) async => const []),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    // The category chips: Fuel is picked for the user.
    final fuel = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Fuel'));
    expect(fuel.selected, isTrue);
  });

  testWidgets(
    'a RuPay-only card shows the engine exclusion reason verbatim, greyed',
    (tester) async {
      const parsed = ParsedUpiQr(
        pa: 'shop@okhdfcbank',
        pn: 'Local Store',
        isLikelyP2P: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogueProvider.overrideWith(
              (ref) async => [_card('rupay-card', isUpiLinkable: false)],
            ),
            categoriesProvider.overrideWith((ref) async => const []),
            userCardsProvider.overrideWith((ref) async => const []),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Not usable via UPI — swipe this instead.'),
        findsOneWidget,
      );
      // Excluded cards never get a "Pay with" action.
      expect(
        find.widgetWithText(FilledButton, 'Pay with rupay-card'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'tapping "Wasn\'t accepted" removes that card from the ranked list',
    (tester) async {
      // A non-zero `am` so the two cards' differing reward rates actually
      // produce different expectedValue results — at ₹0 spend the engine's
      // final card-id tie-break would rank card-a first regardless of rate,
      // which would make this test pass for the wrong reason.
      final parsed = ParsedUpiQr(
        pa: 'shop@okhdfcbank',
        pn: 'Local Store',
        isLikelyP2P: false,
        am: Money.fromRupees(1000),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogueProvider.overrideWith(
              (ref) async => [
                _card('card-a', rate: 0.05),
                _card('card-b', rate: 0.01),
              ],
            ),
            categoriesProvider.overrideWith((ref) async => const []),
            userCardsProvider.overrideWith(
              (ref) async => [_owned('card-a'), _owned('card-b')],
            ),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp(home: ScanResultScreen(parsed: parsed)),
        ),
      );
      await tester.pumpAndSettle();

      // card-a ranks first (higher rate) and shows a "Pay with card-a" button.
      expect(
        find.widgetWithText(FilledButton, 'Pay with card-a'),
        findsOneWidget,
      );

      final rejectedButton = find
          .widgetWithText(TextButton, "Wasn't accepted")
          .first;
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(rejectedButton);
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'Pay with card-a'),
        findsNothing,
      );
      expect(
        find.widgetWithText(FilledButton, 'Pay with card-b'),
        findsOneWidget,
      );

      // Reject the last one too -> not "No cards yet" (they own two), a
      // reversible dead end.
      final lastRejectedButton = find
          .widgetWithText(TextButton, "Wasn't accepted")
          .first;
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(lastRejectedButton);
      await tester.pumpAndSettle();
      expect(find.text('No other cards to try'), findsOneWidget);
      expect(find.text('No cards yet'), findsNothing);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Show them again'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(FilledButton, 'Pay with card-a'),
        findsOneWidget,
      );
    },
  );

  group('pay: the shop QR is shared into the UPI app', () {
    testWidgets(
      'shares the shop and amount into the chosen app, no dialog in between',
      (tester) async {
        final fake = _FakeUpiService(apps: const [_gpay]);
        await _pumpScan(tester, fake);

        // The QR carried no amount -> flagged inline, nothing is shared yet.
        await _tapPay(tester);
        expect(find.text('Enter an amount to pay'), findsOneWidget);
        expect(find.text('Open which UPI app?'), findsNothing);

        await _enterAmountAndPay(tester, '250');
        expect(find.text('Open which UPI app?'), findsOneWidget);

        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();

        // One QR, carrying the payee and the amount, goes to the app picked.
        expect(fake.shared, hasLength(1));
        expect(
          fake.shared.single.package,
          'com.google.android.apps.nbu.paisa.user',
        );
        final qr = Uri.parse(fake.shared.single.data);
        expect(qr.scheme, 'upi');
        expect(qr.host, 'pay');
        expect(qr.queryParameters['pa'], 'shop@okhdfcbank');
        expect(qr.queryParameters['pn'], 'DMart');
        expect(qr.queryParameters['am'], '250.00');
        expect(qr.queryParameters['mc'], '5411');
        expect(qr.queryParameters['cu'], 'INR');
        // Nothing else was needed: no guide, no app opened separately.
        expect(find.textContaining('Scan the QR in'), findsNothing);
        expect(fake.opened, isEmpty);
        expect(find.text('Continue in your UPI app'), findsOneWidget);
        expect(find.text('REWARD IF THIS COMPLETES'), findsOneWidget);
      },
    );

    testWidgets('a QR with no merchant code is shared without inventing one', (
      tester,
    ) async {
      // The Paytm shop QR a user scanned: only pa and pn.
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(
        tester,
        fake,
        parsed: const ParsedUpiQr(
          pa: 'paytmqr60fkly@ptys',
          pn: 'Paytm',
          isLikelyP2P: false,
        ),
      );

      await _enterAmountAndPay(tester, '120');
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();

      final qr = Uri.parse(fake.shared.single.data);
      expect(qr.queryParameters['pa'], 'paytmqr60fkly@ptys');
      expect(qr.queryParameters['pn'], 'Paytm');
      expect(qr.queryParameters['am'], '120.00');
      expect(qr.queryParameters.containsKey('mc'), isFalse);
      expect(qr.queryParameters.containsKey('tr'), isFalse);
    });

    testWidgets('shares into whichever app is picked when several exist', (
      tester,
    ) async {
      final fake = _FakeUpiService(apps: const [_gpay, _slice]);
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '30');
      await tester.tap(find.text('Slice'));
      await tester.pumpAndSettle();

      expect(fake.shared.single.package, 'in.slice.android');
      expect(fake.opened, isEmpty);
    });

    testWidgets('exactly ₹2,000 is still shared; above it the user scans', (
      tester,
    ) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(tester, fake);
      await _enterAmountAndPay(tester, '2000');
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();
      expect(fake.shared, hasLength(1));
      expect(find.textContaining('Scan the QR in'), findsNothing);
    });

    testWidgets(
      'above NPCI\'s ₹2,000 share limit it goes to the scan-it-yourself guide',
      (tester) async {
        final fake = _FakeUpiService(apps: const [_gpay]);
        await _pumpScan(tester, fake);

        await _enterAmountAndPay(tester, '2500');
        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();

        expect(fake.shared, isEmpty);
        expect(find.text('Scan the QR in Google Pay'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Open Google Pay'));
        await tester.pumpAndSettle();
        expect(fake.opened, ['com.google.android.apps.nbu.paisa.user']);
        expect(_clipboard, '2500');
        expect(find.text('REWARD IF THIS COMPLETES'), findsOneWidget);
      },
    );

    testWidgets(
      'an app that refuses the shared QR falls back to the guide',
      (tester) async {
        final fake = _FakeUpiService(apps: const [_gpay])..shareResult = false;
        await _pumpScan(tester, fake);

        await _enterAmountAndPay(tester, '250');
        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();

        expect(fake.shared, hasLength(1)); // tried first
        expect(find.text('Scan the QR in Google Pay'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Open Google Pay'));
        await tester.pumpAndSettle();

        expect(fake.opened, ['com.google.android.apps.nbu.paisa.user']);
        expect(_clipboard, '250');
        expect(find.text('Continue in your UPI app'), findsOneWidget);
      },
    );

    testWidgets('a paise amount is shared and copied exactly', (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay])..shareResult = false;
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '250.5');
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();
      expect(
        Uri.parse(fake.shared.single.data).queryParameters['am'],
        '250.50',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Open Google Pay'));
      await tester.pumpAndSettle();

      expect(_clipboard, '250.50');
    });

    testWidgets('dismissing the app picker does nothing', (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '250');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Open which UPI app?'), findsNothing);
      expect(find.textContaining('Scan the QR in'), findsNothing);
      expect(fake.shared, isEmpty);
      expect(fake.opened, isEmpty);
      expect(_clipboard, isNull);
      expect(find.text('REWARD IF THIS COMPLETES'), findsNothing);
    });

    testWidgets('cancelling the guide opens nothing and copies nothing', (
      tester,
    ) async {
      final fake = _FakeUpiService(apps: const [_gpay])..shareResult = false;
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '250');
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(fake.opened, isEmpty);
      expect(_clipboard, isNull);
      expect(find.text('REWARD IF THIS COMPLETES'), findsNothing);
      // Still on the scan screen, ready to try again.
      expect(find.widgetWithText(FilledButton, 'Pay with c1'), findsOneWidget);
    });

    testWidgets(
      'when sharing and opening both fail it says so and stays on the screen',
      (tester) async {
        final fake = _FakeUpiService(apps: const [_gpay])
          ..shareResult = false
          ..openResult = false;
        await _pumpScan(tester, fake);

        await _enterAmountAndPay(tester, '250');
        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Open Google Pay'));
        await tester.pumpAndSettle();

        expect(find.textContaining("Couldn't open Google Pay"), findsOneWidget);
        expect(find.text('REWARD IF THIS COMPLETES'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Pay with c1'), findsOneWidget);
      },
    );

    testWidgets(
      'with no UPI app to open (iOS), the guide says so and continues',
      (tester) async {
        final fake = _FakeUpiService();
        await _pumpScan(tester, fake);

        await _enterAmountAndPay(tester, '250');
        // Nothing to pick, so it goes straight to the guide.
        expect(find.text('Open which UPI app?'), findsNothing);
        expect(find.text('Scan the QR in your UPI app'), findsOneWidget);
        expect(find.text('Open your UPI app'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Got it'));
        await tester.pumpAndSettle();

        expect(fake.shared, isEmpty);
        expect(fake.opened, isEmpty);
        expect(_clipboard, '250');
        expect(find.text('REWARD IF THIS COMPLETES'), findsOneWidget);
      },
    );

    testWidgets(
      'a signed merchant QR is never redrawn: the user scans it in the app',
      (tester) async {
        final fake = _FakeUpiService(apps: const [_slice]);
        await _pumpScan(
          tester,
          fake,
          parsed: const ParsedUpiQr(
            pa: 'q@ybl',
            pn: 'Pump',
            mc: '5541',
            tr: 'ORD1',
            mode: '02',
            orgid: '159761',
            sign: 'a+b',
            isLikelyP2P: false,
          ),
        );

        await _enterAmountAndPay(tester, '500');
        await tester.tap(find.text('Slice'));
        await tester.pumpAndSettle();
        expect(fake.shared, isEmpty);
        await tester.tap(find.widgetWithText(FilledButton, 'Open Slice'));
        await tester.pumpAndSettle();

        expect(fake.opened, ['in.slice.android']);
      },
    );
  });

  group('a card that earns nothing here can still pay', () {
    // The Tata Neu RuPay card on the Paytm shop QR: no category chosen, no
    // reward rule, so the engine excludes it with "No applicable reward rule."
    // Before this it had no Pay button, and a Visa next to it (not UPI-linkable)
    // left the user with nothing to tap.
    CardProduct noRuleRupay() => const CardProduct(
      id: 'neu',
      name: 'Neu RuPay',
      network: CardNetwork.rupay,
      isUpiLinkable: true,
      rewardRules: [],
    );

    Future<void> pumpWith(
      WidgetTester tester,
      _FakeUpiService fake,
      List<CardProduct> catalogue,
      List<UserCard> wallet,
    ) async {
      _mockClipboard(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            upiPaymentServiceProvider.overrideWithValue(fake),
            catalogueProvider.overrideWith((ref) async => catalogue),
            categoriesProvider.overrideWith((ref) async => const []),
            userCardsProvider.overrideWith((ref) async => wallet),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(
            home: ScanResultScreen(
              parsed: ParsedUpiQr(
                pa: 'paytmqr60fkly@ptys',
                pn: 'Paytm',
                isLikelyP2P: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('keeps its Pay button and takes the amount', (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await pumpWith(
        tester,
        fake,
        [_card('visa', isUpiLinkable: false), noRuleRupay()],
        [_owned('visa'), _owned('neu')],
      );

      // Both reasons are still shown, but only the UPI-linkable card can pay.
      expect(
        find.text('Not usable via UPI — swipe this instead.'),
        findsOneWidget,
      );
      expect(find.text('No applicable reward rule.'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Pay with visa'),
        findsNothing,
      );
      expect(
        find.widgetWithText(FilledButton, 'Pay with Neu RuPay'),
        findsOneWidget,
      );
      // The amount goes on that card.
      expect(find.byType(TextField), findsNWidgets(2));

      await tester.enterText(find.byType(TextField).last, '180');
      await tester.pump();
      final pay = find.widgetWithText(FilledButton, 'Pay with Neu RuPay');
      await tester.ensureVisible(pay);
      await tester.pumpAndSettle();
      await tester.tap(pay);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();

      expect(fake.shared.single.package, 'com.google.android.apps.nbu.paisa.user');
      expect(
        Uri.parse(fake.shared.single.data).queryParameters['am'],
        '180.00',
      );
    });

    testWidgets('a card the user does not own is still not payable', (
      tester,
    ) async {
      await pumpWith(
        tester,
        _FakeUpiService(apps: const [_gpay]),
        [noRuleRupay()],
        const [],
      );

      expect(
        find.widgetWithText(FilledButton, 'Pay with Neu RuPay'),
        findsNothing,
      );
    });
  });

  testWidgets('Pay with a zero amount is blocked inline until one is entered', (
    tester,
  ) async {
    final fake = _FakeUpiService(apps: const [_gpay]);
    const parsed = ParsedUpiQr(
      pa: 'shop@okhdfcbank',
      pn: 'DMart',
      mc: '5411',
      isLikelyP2P: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          upiPaymentServiceProvider.overrideWithValue(fake),
          catalogueProvider.overrideWith(
            (ref) async => [_card('c1', rate: 0.03)],
          ),
          categoriesProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => [_owned('c1')]),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Pay with c1'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount to pay'), findsOneWidget);
    expect(fake.opened, isEmpty);
    expect(find.text('Open which UPI app?'), findsNothing);

    // Still below the ₹1 floor -> error stays, no hand-off.
    await tester.enterText(find.byType(TextField).last, '0');
    await tester.tap(find.widgetWithText(FilledButton, 'Pay with c1'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount to pay'), findsOneWidget);
    expect(fake.opened, isEmpty);

    // A valid amount clears it and lets the hand-off through.
    await tester.enterText(find.byType(TextField).last, '50');
    await tester.pump();
    expect(find.text('Enter an amount to pay'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Pay with c1'));
    await tester.pumpAndSettle();
    expect(find.text('Open which UPI app?'), findsOneWidget);
  });

  testWidgets(
    'the amount is entered on the hero card and the reward updates there',
    (tester) async {
      const parsed = ParsedUpiQr(
        pa: 'shop@okhdfcbank',
        pn: 'DMart',
        mc: '5411',
        isLikelyP2P: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            upiPaymentServiceProvider.overrideWithValue(
              _FakeUpiService(apps: const [_gpay]),
            ),
            catalogueProvider.overrideWith(
              (ref) async => [_card('c1', rate: 0.02)],
            ),
            categoriesProvider.overrideWith((ref) async => const []),
            userCardsProvider.overrideWith((ref) async => [_owned('c1')]),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
        ),
      );
      await tester.pumpAndSettle();

      // No standalone "Amount to pay" field any more — merchant field + the
      // on-card amount entry, and the reward is a prompt until an amount lands.
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('Enter an amount to see your reward'), findsOneWidget);
      expect(find.text('back'), findsNothing);
      // Text-only card rows, as on the original page: no card picture.
      expect(find.text('TAP THIS ONE'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '1000');
      await tester.pump();

      // Reward now resolves on the card itself.
      expect(find.text('Enter an amount to see your reward'), findsNothing);
      expect(find.text('back'), findsOneWidget);
    },
  );

  testWidgets(
    'empty wallet: a merchant QR offers "Add this card", not "Pay with"',
    (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      const parsed = ParsedUpiQr(
        pa: 'shop@okhdfcbank',
        pn: 'DMart',
        mc: '5411',
        isLikelyP2P: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            upiPaymentServiceProvider.overrideWithValue(fake),
            catalogueProvider.overrideWith(
              (ref) async => [_card('c1', rate: 0.03)],
            ),
            categoriesProvider.overrideWith((ref) async => const []),
            userCardsProvider.overrideWith((ref) async => const []),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'Add this card'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Pay with c1'), findsNothing);
      expect(find.textContaining('Add your own cards'), findsOneWidget);
    },
  );

  testWidgets(
    'a no-mc QR still lists a UPI-linkable RuPay card, not the P2P notice',
    (tester) async {
      const parsed = ParsedUpiQr(
        pa: 'q@ybl',
        pn: 'Corner Store',
        isLikelyP2P: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            upiPaymentServiceProvider.overrideWithValue(
              _FakeUpiService(apps: const [_gpay]),
            ),
            catalogueProvider.overrideWith(
              (ref) async => [
                _card(
                  'rupay-1',
                  network: CardNetwork.rupay,
                  isUpiLinkable: true,
                ),
              ],
            ),
            categoriesProvider.overrideWith((ref) async => const []),
            userCardsProvider.overrideWith(
              (ref) async => const [
                UserCard(
                  id: 'uc1',
                  cardProductId: 'rupay-1',
                  cardName: 'My RuPay',
                  isDefault: true,
                ),
              ],
            ),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text("Credit cards can't be used for personal transfers"),
        findsNothing,
      );
      expect(find.textContaining('no merchant code'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Pay with rupay-1'),
        findsOneWidget,
      );

      final payButton = find.widgetWithText(FilledButton, 'Pay with rupay-1');
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(payButton);
      await tester.pumpAndSettle();

      // Amount first (QR carried none) — flagged inline — then, once filled, the
      // business-payment gate, both before any app hand-off.
      expect(find.text('Enter an amount to pay'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '500');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Pay with rupay-1'));
      await tester.pumpAndSettle();

      expect(find.text('Is this a business payment?'), findsOneWidget);
    },
  );

  testWidgets(
    'a no-mc QR with no RuPay card in the wallet keeps the P2P notice',
    (tester) async {
      const parsed = ParsedUpiQr(pa: 'q@ybl', pn: 'Someone', isLikelyP2P: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // A real Visa card: not linkable to UPI, so a no-MCC QR has nothing
            // to offer and the personal-transfer notice stays.
            catalogueProvider.overrideWith(
              (ref) async => [_card('visa-1', isUpiLinkable: false)],
            ),
            categoriesProvider.overrideWith((ref) async => const []),
            userCardsProvider.overrideWith(
              (ref) async => const [
                UserCard(
                  id: 'uc1',
                  cardProductId: 'visa-1',
                  cardName: 'My Visa',
                  isDefault: true,
                ),
              ],
            ),
            cardOverridesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text("Credit cards can't be used for personal transfers"),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a no-mc QR asks "business payment?" first; Yes continues to the app picker',
    (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(
        tester,
        fake,
        parsed: const ParsedUpiQr(pa: 'q@ybl', pn: 'Corner', isLikelyP2P: true),
        network: CardNetwork.rupay,
      );

      await _enterAmountAndPay(tester, '500');
      expect(find.text('Is this a business payment?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Open which UPI app?'), findsNothing);
      expect(fake.opened, isEmpty);

      await _tapPay(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Yes, continue'));
      await tester.pumpAndSettle();
      expect(find.text('Open which UPI app?'), findsOneWidget);
    },
  );
}
