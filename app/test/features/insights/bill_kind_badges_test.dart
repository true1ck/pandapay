import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/bills_projection_api.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/pending_bills.dart';
import 'package:pandapay/data/premium_reminders.dart';
import 'package:pandapay/features/insights/bills_horizon.dart';
import 'package:pandapay/features/insights/central_bills_section.dart';
import 'package:pandapay/features/sms_v2/ledger/premium_notices.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic names and numbers only: the repository is public.
Commitment _bill(
  String id,
  String title,
  CommitmentCategory category,
  DateTime due,
  int rupees, {
  CommitmentStatus status = CommitmentStatus.due,
  String? identifier,
  String? txn,
}) => Commitment(
  id: id,
  title: title,
  category: category,
  amount: Money.fromRupees(rupees),
  dueOn: due,
  identifier: identifier,
  cadence: CommitmentCadence.oneTime,
  status: status,
  linkedTransactionId: txn,
  confidence: 0.95,
  sourceKey: 'src-$id',
);

void main() {
  final now = DateTime(2026, 10, 25, 12);
  final upcoming = [
    _bill('v2:1', 'Sunrise Life Insurance', CommitmentCategory.insurance,
        DateTime(2026, 11, 12), 12450, identifier: '6789'),
    _bill('v2:2', 'City Power Board', CommitmentCategory.utility,
        DateTime(2026, 10, 30), 1840),
    _bill('v2:3', 'Home Loan EMI', CommitmentCategory.loanOrEmi,
        DateTime(2026, 11, 5), 18500, identifier: '2210'),
  ];
  final past = <Commitment>[
    _bill('v2:4', 'Test Bank Credit Card', CommitmentCategory.other,
        DateTime(2026, 10, 5), 8200,
        status: CommitmentStatus.paid, identifier: '4321', txn: 't1'),
    _bill('v2:5', 'Sunrise Life Insurance', CommitmentCategory.insurance,
        DateTime(2026, 9, 12), 12450,
        status: CommitmentStatus.paymentNotDetected, identifier: '6789'),
  ];
  final notice = PremiumNotice(
    sourceKey: 'n1',
    month: DateTime(2026, 9),
    sender: 'VM-INSCO-S',
    receivedAt: DateTime(2026, 8, 20),
    body: 'Next Premium falls due on 09/2026',
    policyLast4: '5522',
  );
  final pastReceipts = [
    ...pastBillReceiptsFromBills(past, now),
    ...pastPremiumReceiptsFromNotices([notice], now),
  ];

  test('every past bill carries what it is', () {
    final kinds = {for (final r in pastReceipts) r.merchant: r.categoryName};
    expect(kinds['Test Bank Credit Card'], 'creditCard');
    expect(kinds['Sunrise Life Insurance'], 'insurance');
    expect(kinds['INSCO'], 'insurance');
  });

  testWidgets('bills say what they are, and insurance says premium', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    BambooFonts.useSystemFontsForTests = true;
    addTearDown(() => BambooFonts.useSystemFontsForTests = false);
    tester.view.physicalSize = const Size(430, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final shot = Platform.environment['BILLS_SHOT'];
    if (shot != null) {
      for (final (family, path) in [
        ('SegoeUI', 'C:/Windows/Fonts/segoeui.ttf'),
        (
          'MaterialIcons',
          'C:/flutter/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ),
      ]) {
        final loader = FontLoader(family)
          ..addFont(
            Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
          );
        await loader.load();
      }
    }
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'test-token'),
          sessionInitProvider.overrideWith((ref) async {}),
          isOnlineProvider.overrideWith((ref) => Stream.value(true)),
          categoriesProvider.overrideWith((ref) async => const []),
          myCardsProvider.overrideWith((ref) async => const []),
          clockProvider.overrideWithValue(TestClock(now)),
          smsBillRowsProvider.overrideWith((ref) async => const <SmsBillRow>[]),
          centralBillsProjectionProvider.overrideWith(
            (ref) async => const BillProjectionSnapshot.unavailable(),
          ),
          paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
          commitmentsProvider.overrideWith((ref) async => upcoming),
          pastBillReceiptsProvider.overrideWith((ref) async => pastReceipts),
          premiumRemindersProvider.overrideWith(
            (ref) => [
              PremiumReminder(
                id: 'p',
                title: 'Evergreen Insurance',
                category: CommitmentCategory.insurance,
                accountLast4: '5522',
                premiumMonth: DateTime(2026, 12),
                receivedAt: DateTime(2026, 10, 2),
                sampleBody: 'Next Premium falls due on 12/2026',
              ),
            ],
          ),
          billsHorizonProvider.overrideWith((ref) => BillsHorizon.upcoming),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: shot != null ? 'SegoeUI' : null,
            scaffoldBackgroundColor: BambooInk.paper,
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: const BillsAndCommitmentsTab(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Upcoming: each bill carries its kind beside its name.
    expect(find.text('INSURANCE'), findsWidgets);
    expect(find.text('UTILITY'), findsWidgets);
    expect(find.text('LOAN / EMI'), findsWidgets);
    // Insurance is a premium, not a bill.
    expect(find.textContaining('Premium due 12 Nov'), findsOneWidget);
    expect(find.textContaining('Due 12 Nov'), findsNothing);
    expect(find.textContaining('Due 30 Oct'), findsOneWidget);
    // Past bills: kind and wording per row.
    expect(find.text('CREDIT CARD'), findsOneWidget);
    expect(find.text('Past premium · Payment not detected'), findsOneWidget);
    expect(find.text('Past premium · Needs confirmation'), findsOneWidget);
    expect(find.text('Paid · Linked'), findsOneWidget);

    if (shot != null) {
      await tester.runAsync(() async {
        final ro = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await ro.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(shot).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}
