import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';

ConsentRecord _granted() => ConsentRecord(
  purpose: smsSharedLearningPurpose,
  granted: true,
  grantedAt: DateTime.utc(2026, 11, 6),
  policyVersion: smsSharedLearningPolicyVersion,
);

/// A [WidgetRef] from a Consumer that does not watch the consent provider,
/// the way Review's tap handlers see it.
Future<WidgetRef> _unwatchedRef(
  WidgetTester tester,
  Future<ConsentRecord?> Function() load,
) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        app.smsSharedLearningConsentProvider.overrideWith((ref) => load()),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('a granted opt-in is read even though no screen watches it', (
    tester,
  ) async {
    final ref = await _unwatchedRef(tester, () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return _granted();
    });
    final result = await tester.runAsync(() => readSharingConsent(ref));
    expect(result, isTrue);
  });

  testWidgets('no granted record means nothing is shared', (tester) async {
    final ref = await _unwatchedRef(tester, () async => null);
    final result = await tester.runAsync(() => readSharingConsent(ref));
    expect(result, isFalse);
  });

  testWidgets('a failed load shares nothing', (tester) async {
    final ref = await _unwatchedRef(tester, () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      throw StateError('offline');
    });
    final result = await tester.runAsync(() => readSharingConsent(ref));
    expect(result, isFalse);
  });
}
