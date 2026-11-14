import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/insights/bill_proof_section.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

SmsIntakeEntry _sms() => SmsIntakeEntry(
  'k1',
  QueuedSms(
    sender: 'VM-EXAMPL',
    body:
        'Your Example Power bill of Rs 1,240 for consumer 123456789012 is due '
        'on 20-Nov. Pay via the official app.',
    receivedAt: DateTime(2026, 11, 10, 9, 30),
  ),
);

Widget _host(Widget child, {SmsIntakeEntry? sms, List<String>? pushed}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          backgroundColor: BambooInk.paper,
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
      GoRoute(
        path: '/activity/:id',
        builder: (_, state) {
          pushed?.add(state.pathParameters['id']!);
          return const Scaffold(body: Text('txn detail'));
        },
      ),
    ],
  );
  return ProviderScope(
    overrides: [billProofSmsProvider.overrideWith((ref, key) async => sms)],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('shows masked SMS and opens the payment', (tester) async {
    final pushed = <String>[];
    await tester.binding.setSurfaceSize(const Size(400, 520));
    await tester.pumpWidget(
      _host(
        BillProofSection(
          sourceKey: 'k1',
          paymentTransactionId: 'txn-9',
          paidOn: DateTime(2026, 11, 12),
        ),
        sms: _sms(),
        pushed: pushed,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Bill SMS from VM-EXAMPL'), findsOneWidget);
    expect(find.textContaining('•••• 9012'), findsNothing); // collapsed
    await tester.tap(find.text('Show original SMS'));
    await tester.pumpAndSettle();
    expect(find.textContaining('•••• 9012'), findsOneWidget);
    expect(find.textContaining('123456789012'), findsNothing);
    expect(
      tester.getSize(find.byType(TextButton)).height,
      greaterThanOrEqualTo(44),
    );
    // This golden was rendered with the real fonts on a Windows dev machine, so
    // it only matches there (3% pixel drift on the Linux CI runner). The layout
    // assertions above run everywhere; compare pixels only where it was made.
    if (Platform.isWindows) {
      await expectLater(
        find.byType(BillProofSection),
        matchesGoldenFile('goldens/bill_proof_paid.png'),
      );
    }

    await tester.tap(find.textContaining('View payment'));
    await tester.pumpAndSettle();
    expect(pushed, ['txn-9']);
  });

  testWidgets('fits a narrow screen at large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpWidget(
      _host(
        BillProofSection(sourceKey: 'k1', paymentTransactionId: 't'),
        sms: _sms(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual bill and missing SMS explain themselves', (tester) async {
    await tester.pumpWidget(_host(const BillProofSection()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Added by you'), findsOneWidget);
    await tester.pumpWidget(
      _host(const BillProofSection(sourceKey: 'manual-bill-c1-2026-11')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Added by you'), findsOneWidget);
    expect(find.textContaining('View payment'), findsNothing);

    await tester.pumpWidget(_host(const BillProofSection(sourceKey: 'gone')));
    await tester.pumpAndSettle();
    expect(find.textContaining('not on this phone'), findsOneWidget);
  });
}
