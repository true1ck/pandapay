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
  bool launchResult = true;
  bool shareResult = false;
  final opened = <String>[];
  final launched = <({String package, String uri})>[];
  final shared = <({String package, String data})>[];

  @override
  Future<List<UpiApp>> installedApps() async => apps;

  @override
  Future<bool> openApp(String packageName) async {
    opened.add(packageName);
    return openResult;
  }

  @override
  Future<bool> launchUpiLink({
    required String packageName,
    required String uri,
  }) async {
    launched.add((package: packageName, uri: uri));
    return launchResult;
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

/// An unmocked platform channel never answers in a widget test.
void _mockClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
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

/// The page is long; a tall screen builds every row, as a scroll would.
void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpScan(
  WidgetTester tester,
  _FakeUpiService fake, {
  ParsedUpiQr parsed = _shopQr,
  CardNetwork network = CardNetwork.visa,
}) async {
  _tallScreen(tester);
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
  final pay = find.byKey(const ValueKey('pay:c1'));
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

    // The category dropdown: Fuel is picked for the user.
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .initialValue,
      'fuel-id',
    );
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
        find.byKey(const ValueKey('pay:rupay-card')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'cards are compact rows: Pay on each, no "always use" or "wasn\'t accepted"',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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

      expect(find.byKey(const ValueKey('pay:card-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('pay:card-b')), findsOneWidget);
      // The better card is first and marked.
      expect(find.text('BEST'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('card-a')).dy,
        lessThan(tester.getTopLeft(find.text('card-b')).dy),
      );
      expect(find.text("Wasn't accepted"), findsNothing);
      expect(find.text('Always use this card here'), findsNothing);
      // Paying from the bank account is the last thing on the page.
      expect(
        tester.getTopLeft(find.text('Continue without card')).dy,
        greaterThan(tester.getTopLeft(find.text('card-b')).dy),
      );
    },
  );

  group('pay: the chosen UPI app opens with the payment filled in', () {
    testWidgets(
      'opens the picked app with the payee and amount, no dialog in between',
      (tester) async {
        final fake = _FakeUpiService(apps: const [_gpay]);
        await _pumpScan(tester, fake);

        // The QR carried no amount -> flagged inline, nothing opens yet.
        await _tapPay(tester);
        expect(find.text('Enter an amount to pay'), findsOneWidget);
        expect(find.text('Open which UPI app?'), findsNothing);

        await _enterAmountAndPay(tester, '250');
        expect(find.text('Open which UPI app?'), findsOneWidget);

        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();

        expect(fake.launched, hasLength(1));
        expect(
          fake.launched.single.package,
          'com.google.android.apps.nbu.paisa.user',
        );
        final link = Uri.parse(fake.launched.single.uri);
        expect(link.scheme, 'upi');
        expect(link.host, 'pay');
        expect(link.queryParameters['pa'], 'shop@okhdfcbank');
        expect(link.queryParameters['pn'], 'DMart');
        expect(link.queryParameters['am'], '250.00');
        expect(link.queryParameters['mc'], '5411');
        expect(link.queryParameters['cu'], 'INR');
        // No how-to dialog, nothing else needed.
        expect(find.textContaining('Scan the QR in'), findsNothing);
        expect(fake.shared, isEmpty);
        expect(find.text('Continue in your UPI app'), findsOneWidget);
        expect(find.text('REWARD IF THIS COMPLETES'), findsOneWidget);
      },
    );

    testWidgets('a QR with no merchant code is not given one', (tester) async {
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

      final link = Uri.parse(fake.launched.single.uri);
      expect(link.queryParameters['pa'], 'paytmqr60fkly@ptys');
      expect(link.queryParameters['pn'], 'Paytm');
      expect(link.queryParameters['am'], '120.00');
      expect(link.queryParameters.containsKey('mc'), isFalse);
      expect(link.queryParameters.containsKey('tr'), isFalse);
    });

    testWidgets('opens whichever app is picked when several exist', (
      tester,
    ) async {
      final fake = _FakeUpiService(apps: const [_gpay, _slice]);
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '30');
      await tester.tap(find.text('Slice'));
      await tester.pumpAndSettle();

      expect(fake.launched.single.package, 'in.slice.android');
    });

    testWidgets(
      'an app with no known payment link is opened and the UPI ID is copied',
      (tester) async {
        const scapia = UpiApp(
          packageName: 'scapia',
          name: 'Scapia',
          prefillsPayment: false,
        );
        final fake = _FakeUpiService(apps: const [_gpay, scapia]);
        await _pumpScan(tester, fake);
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );

        await _enterAmountAndPay(tester, '30');
        await tester.tap(find.text('Scapia'));
        await tester.pumpAndSettle();

        expect(fake.launched.single.package, 'scapia');
        expect(copied, ['shop@okhdfcbank']);
        expect(find.textContaining('UPI ID copied'), findsOneWidget);
      },
    );

    testWidgets('an app that takes the link does not touch the clipboard', (
      tester,
    ) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(tester, fake);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );

      await _enterAmountAndPay(tester, '30');
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();

      expect(copied, isEmpty);
      expect(find.textContaining('UPI ID copied'), findsNothing);
    });

    testWidgets('a signed merchant QR keeps its signature and references', (
      tester,
    ) async {
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

      final link = Uri.parse(fake.launched.single.uri);
      expect(link.queryParameters['tr'], 'ORD1');
      expect(link.queryParameters['sign'], 'a+b');
      expect(link.queryParameters['orgid'], '159761');
    });

    testWidgets('any amount opens the app, there is no cap', (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(tester, fake);
      await _enterAmountAndPay(tester, '25000');
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();
      expect(
        Uri.parse(fake.launched.single.uri).queryParameters['am'],
        '25000.00',
      );
    });

    testWidgets(
      'an app that cannot take the link is handed the payment as a shared QR',
      (tester) async {
        final fake = _FakeUpiService(apps: const [_gpay])
          ..launchResult = false
          ..shareResult = true;
        await _pumpScan(tester, fake);

        await _enterAmountAndPay(tester, '250');
        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();

        expect(fake.launched, hasLength(1));
        expect(find.textContaining('Scan the QR in'), findsNothing);
        expect(find.text('Continue in your UPI app'), findsOneWidget);
      },
    );

    testWidgets('when nothing works it says so and stays on the page', (
      tester,
    ) async {
      final fake = _FakeUpiService(apps: const [_gpay])..launchResult = false;
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '250');
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't open Google Pay"), findsOneWidget);
      expect(find.text('Continue in your UPI app'), findsNothing);
      expect(find.byKey(const ValueKey('pay:c1')), findsOneWidget);
    });

    testWidgets('dismissing the app picker does nothing', (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '250');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Open which UPI app?'), findsNothing);
      expect(fake.launched, isEmpty);
      expect(fake.shared, isEmpty);
      expect(find.text('Continue in your UPI app'), findsNothing);
    });
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
      _tallScreen(tester);
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

      // The Visa is shown as unusable; the RuPay card is a normal card with
      // its ₹0.00 and the best-card badge, not a blocked one.
      expect(
        find.text('Not usable via UPI — swipe this instead.'),
        findsOneWidget,
      );
      expect(find.text('No applicable reward rule.'), findsNothing);
      expect(find.text('BEST'), findsOneWidget);
      // The card that can pay comes before the one that cannot be used.
      expect(
        tester.getTopLeft(find.text('Neu RuPay')).dy,
        lessThan(tester.getTopLeft(find.text('visa')).dy),
      );
      expect(find.byKey(const ValueKey('pay:visa')), findsNothing);
      expect(
        find.byKey(const ValueKey('pay:Neu RuPay')),
        findsOneWidget,
      );
      // The amount goes on that card.
      expect(find.byType(TextField), findsNWidgets(2));

      await tester.enterText(find.byType(TextField).last, '180');
      await tester.pump();
      final pay = find.byKey(const ValueKey('pay:Neu RuPay'));
      await tester.ensureVisible(pay);
      await tester.pumpAndSettle();
      await tester.tap(pay);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();

      expect(
        fake.launched.single.package,
        'com.google.android.apps.nbu.paisa.user',
      );
      expect(
        Uri.parse(fake.launched.single.uri).queryParameters['am'],
        '180.00',
      );
    });

    testWidgets('a card the user does not own is still not payable', (
      tester,
    ) async {
      await pumpWith(tester, _FakeUpiService(apps: const [_gpay]), [
        noRuleRupay(),
      ], const []);

      expect(
        find.byKey(const ValueKey('pay:Neu RuPay')),
        findsNothing,
      );
    });
  });

  testWidgets('Pay with a zero amount is blocked inline until one is entered', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

    await tester.tap(find.byKey(const ValueKey('pay:c1')));
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount to pay'), findsOneWidget);
    expect(fake.opened, isEmpty);
    expect(find.text('Open which UPI app?'), findsNothing);

    // Still below the ₹1 floor -> error stays, no hand-off.
    await tester.enterText(find.byType(TextField).last, '0');
    await tester.tap(find.byKey(const ValueKey('pay:c1')));
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount to pay'), findsOneWidget);
    expect(fake.opened, isEmpty);

    // A valid amount clears it and lets the hand-off through.
    await tester.enterText(find.byType(TextField).last, '50');
    await tester.pump();
    expect(find.text('Enter an amount to pay'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pay:c1')));
    await tester.pumpAndSettle();
    expect(find.text('Open which UPI app?'), findsOneWidget);
  });

  testWidgets(
    'the amount has its own card with quick amounts and the reward updates',
    (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(tester, fake);

      // Merchant name + the amount, in its own card, with quick amounts.
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('Enter amount'), findsOneWidget);
      for (final v in ['₹100', '₹200', '₹500', '₹1,000']) {
        expect(find.text(v), findsOneWidget);
      }
      expect(find.text('Recommended cards'), findsOneWidget);
      expect(find.text('Continue without card'), findsOneWidget);
      expect(find.text('back'), findsNothing);

      // A quick amount fills the box and the best card shows what it earns.
      await tester.tap(find.text('₹1,000'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '1000',
      );
      expect(find.text('back'), findsOneWidget);

      // The clear button empties it again.
      await tester.tap(find.byTooltip('Clear amount'));
      await tester.pump();
      expect(find.text('back'), findsNothing);
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
        find.byKey(const ValueKey('add:c1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('pay:c1')), findsNothing);
      expect(find.textContaining('Add your own cards'), findsOneWidget);
    },
  );

  testWidgets(
    'a no-mc QR still lists a UPI-linkable RuPay card, not the P2P notice',
    (tester) async {
      _tallScreen(tester);
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
        find.byKey(const ValueKey('pay:rupay-1')),
        findsOneWidget,
      );

      final payButton = find.byKey(const ValueKey('pay:rupay-1'));
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(payButton);
      await tester.pumpAndSettle();

      // Amount first (QR carried none) — flagged inline — then, once filled, the
      // business-payment gate, both before any app hand-off.
      expect(find.text('Enter an amount to pay'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '500');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pay:rupay-1')));
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
      await tester.tap(find.widgetWithText(FilledButton, 'Yes'));
      await tester.pumpAndSettle();
      expect(find.text('Open which UPI app?'), findsOneWidget);
    },
  );

  group('continue without credit card: a scan is never a dead end', () {
    Future<_FakeUpiService> pumpWith(
      WidgetTester tester, {
      required List<CardProduct> catalogue,
      required List<UserCard> wallet,
      required ParsedUpiQr parsed,
      List<UpiApp> apps = const [_gpay],
    }) async {
      final fake = _FakeUpiService(apps: apps);
      _tallScreen(tester);
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
          child: MaterialApp(home: ScanResultScreen(parsed: parsed)),
        ),
      );
      await tester.pumpAndSettle();
      return fake;
    }

    Future<void> tapContinue(WidgetTester tester) async {
      final button = find.widgetWithText(FilledButton, 'Continue without card');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'no card can pay by UPI: enter the amount, continue, pick the app, pay from the bank',
      (tester) async {
        final fake = await pumpWith(
          tester,
          catalogue: [_card('visa', isUpiLinkable: false)],
          wallet: [_owned('visa')],
          parsed: _shopQr,
        );

        // The card is shown as unusable, and the way out is right there.
        expect(
          find.text('Not usable via UPI — swipe this instead.'),
          findsOneWidget,
        );
        expect(find.text('Continue without card'), findsOneWidget);

        // Same steps as paying with a card: the amount comes first.
        await tapContinue(tester);
        expect(find.text('Enter an amount to pay'), findsOneWidget);
        expect(find.text('Open which UPI app?'), findsNothing);

        await tester.enterText(find.byType(TextField).last, '300');
        await tester.pump();
        await tapContinue(tester);

        // The same app list as for a card, naming the bank account.
        expect(find.text('Open which UPI app?'), findsOneWidget);
        expect(find.text('Paying with'), findsOneWidget);
        expect(find.text('Your bank account'), findsOneWidget);
        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();

        final qr = Uri.parse(fake.launched.single.uri);
        expect(qr.queryParameters['pa'], 'shop@okhdfcbank');
        expect(qr.queryParameters['am'], '300.00');
        expect(fake.launched.single.package, _gpay.packageName);
        // No card, so no reward and no manual log on the next screen.
        expect(find.text('Continue in your UPI app'), findsOneWidget);
        expect(find.text('REWARD IF THIS COMPLETES'), findsNothing);
        expect(find.text('No SMS? Log this spend manually'), findsNothing);
      },
    );

    testWidgets('a person QR with no card to use can still be paid', (
      tester,
    ) async {
      final fake = await pumpWith(
        tester,
        catalogue: [_card('visa', isUpiLinkable: false)],
        wallet: [_owned('visa')],
        parsed: const ParsedUpiQr(
          pa: 'friend@okaxis',
          pn: 'A Friend',
          isLikelyP2P: true,
        ),
      );

      expect(
        find.text("Credit cards can't be used for personal transfers"),
        findsOneWidget,
      );
      expect(find.text('Continue without card'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '75');
      await tester.pump();
      await tapContinue(tester);
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();

      final qr = Uri.parse(fake.launched.single.uri);
      expect(qr.queryParameters['pa'], 'friend@okaxis');
      expect(qr.queryParameters['am'], '75.00');
    });

    testWidgets(
      'a card exists but is not accepted here: continue without it, using the amount already typed',
      (tester) async {
        final fake = await pumpWith(
          tester,
          catalogue: [_card('c1', rate: 0.03)],
          wallet: [_owned('c1')],
          parsed: _shopQr,
        );

        // Empty amount: flagged on the card's own field, nothing opens.
        await tapContinue(tester);
        expect(find.text('Enter an amount to pay'), findsOneWidget);
        expect(find.text('Open which UPI app?'), findsNothing);

        await tester.enterText(find.byType(TextField).last, '150');
        await tester.pump();
        await tapContinue(tester);
        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();

        expect(
          Uri.parse(fake.launched.single.uri).queryParameters['am'],
          '150.00',
        );
        expect(find.text('REWARD IF THIS COMPLETES'), findsNothing);
      },
    );

    testWidgets('dismissing the app list does nothing', (tester) async {
      final fake = await pumpWith(
        tester,
        catalogue: [_card('c1', rate: 0.03)],
        wallet: [_owned('c1')],
        parsed: _shopQr,
      );

      await tester.enterText(find.byType(TextField).last, '150');
      await tester.pump();
      await tapContinue(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(fake.launched, isEmpty);
      expect(find.text('Continue in your UPI app'), findsNothing);
    });
  });
}
