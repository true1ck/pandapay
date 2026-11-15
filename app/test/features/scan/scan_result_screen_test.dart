import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/upi_payment_service.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/scan/scan_result_screen.dart';
import 'package:pandapay/features/cards/card_visual.dart';
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
  final opened = <String>[];

  @override
  Future<List<UpiApp>> installedApps() async => apps;

  @override
  Future<bool> openApp(String packageName) async {
    opened.add(packageName);
    return openResult;
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

    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(find.text('Fuel'), findsOneWidget);
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

  group('guided pay: the user scans the QR inside the UPI app', () {
    testWidgets(
      'opens the chosen app with no payment link and copies the amount',
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

        // The guide explains the scan before anything leaves PandaPay.
        expect(find.text('Scan the QR in Google Pay'), findsOneWidget);
        expect(
          find.widgetWithText(FilledButton, 'Open Google Pay'),
          findsOneWidget,
        );
        expect(fake.opened, isEmpty);

        await tester.tap(find.widgetWithText(FilledButton, 'Open Google Pay'));
        await tester.pumpAndSettle();

        expect(fake.opened, ['com.google.android.apps.nbu.paisa.user']);
        expect(_clipboard, '250');
        expect(find.text('REWARD IF THIS COMPLETES'), findsOneWidget);
        expect(find.text('Continue in your UPI app'), findsOneWidget);
      },
    );

    testWidgets('a paise amount is copied with two decimals', (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '250.5');
      await tester.tap(find.text('Google Pay'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open Google Pay'));
      await tester.pumpAndSettle();

      expect(_clipboard, '250.50');
    });

    testWidgets('opens whichever app is picked when several are installed', (
      tester,
    ) async {
      final fake = _FakeUpiService(apps: const [_gpay, _slice]);
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '30');
      await tester.tap(find.text('Slice'));
      await tester.pumpAndSettle();
      expect(find.text('Scan the QR in Slice'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Open Slice'));
      await tester.pumpAndSettle();

      expect(fake.opened, ['in.slice.android']);
    });

    testWidgets('dismissing the app picker does nothing', (tester) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
      await _pumpScan(tester, fake);

      await _enterAmountAndPay(tester, '250');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Open which UPI app?'), findsNothing);
      expect(find.textContaining('Scan the QR in'), findsNothing);
      expect(fake.opened, isEmpty);
      expect(_clipboard, isNull);
      expect(find.text('REWARD IF THIS COMPLETES'), findsNothing);
    });

    testWidgets('cancelling the guide opens nothing and copies nothing', (
      tester,
    ) async {
      final fake = _FakeUpiService(apps: const [_gpay]);
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
      'an app that fails to open shows a message and stays on the screen',
      (tester) async {
        final fake = _FakeUpiService(apps: const [_gpay])..openResult = false;
        await _pumpScan(tester, fake);

        await _enterAmountAndPay(tester, '250');
        await tester.tap(find.text('Google Pay'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Open Google Pay'));
        await tester.pumpAndSettle();

        expect(fake.opened, ['com.google.android.apps.nbu.paisa.user']);
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

        expect(fake.opened, isEmpty);
        expect(_clipboard, '250');
        expect(find.text('REWARD IF THIS COMPLETES'), findsOneWidget);
      },
    );

    testWidgets(
      'a signed merchant QR is never rebuilt into a payment link either',
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
        await tester.tap(find.widgetWithText(FilledButton, 'Open Slice'));
        await tester.pumpAndSettle();

        expect(fake.opened, ['in.slice.android']);
      },
    );
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
      expect(find.byType(CardVisual), findsOneWidget);

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
