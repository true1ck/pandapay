
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/onboarding/permission_art.dart';
import 'package:pandapay/features/sms_import/sms_inbox_scanner.dart';

void main() {
  testWidgets('AutoSmsSyncScreen displays progress bar and live counters during inbox scan', (
    tester,
  ) async {
    final progressNotifier = ValueNotifier<SmsInboxScanProgress>(
      const SmsInboxScanProgress(checked: 0, matched: 0, complete: false),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          needsReviewCountProvider.overrideWith((ref) async => 0),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<SmsInboxScanProgress>(
              valueListenable: progressNotifier,
              builder: (context, progress, _) => Column(
                children: [
                  ImportPermissionArtwork(complete: progress.complete),
                  Text(
                    progress.complete
                        ? 'Preparing your spending view…'
                        : 'Checking your SMS inbox…',
                  ),
                  const LinearProgressIndicator(),
                  Text(
                    '${progress.checked} messages checked · ${progress.matched} financial alerts found',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Initial state: scanning in progress
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Checking your SMS inbox…'), findsOneWidget);
    expect(find.text('0 messages checked · 0 financial alerts found'), findsOneWidget);

    // Mid-scan update: 500 messages checked, 120 alerts matched
    progressNotifier.value = const SmsInboxScanProgress(
      checked: 500,
      matched: 120,
      complete: false,
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('500 messages checked · 120 financial alerts found'), findsOneWidget);

    // Scan complete: preparing spending view
    progressNotifier.value = const SmsInboxScanProgress(
      checked: 1420,
      matched: 648,
      complete: true,
    );
    await tester.pump();

    expect(find.text('Preparing your spending view…'), findsOneWidget);
    expect(find.text('1420 messages checked · 648 financial alerts found'), findsOneWidget);
    // When complete is true, circular progress indicator disappears and checkmark is shown
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
