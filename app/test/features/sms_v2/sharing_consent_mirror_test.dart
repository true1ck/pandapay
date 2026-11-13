import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/sms_v2/sync/sharing_consent_mirror.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

ConsentRecord _granted() => ConsentRecord(
  purpose: smsSharedLearningPurpose,
  granted: true,
  grantedAt: DateTime.utc(2026, 11, 6),
  policyVersion: smsSharedLearningPolicyVersion,
);

/// S-02: offline, the shared-learning consent comes from a local mirror of
/// the server's last answer. The mirror never grants anything the server did
/// not.
void main() {
  const ns = 'user:one';
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<bool> ask(
    Future<ConsentRecord?> Function() read, {
    String namespace = ns,
  }) => sharingConsentWithMirror(namespace: namespace, read: read);

  test(
    'a grant the server confirmed is honoured when it cannot be reached',
    () async {
      expect(await ask(() async => _granted()), isTrue);
      for (final offline in <Object>[
        http.ClientException('connection closed'),
        TimeoutException('slow'),
        const SocketException('no route'),
        ApiException('GET /consents failed: 503 {}'),
      ]) {
        expect(
          await ask(() async => throw offline),
          isTrue,
          reason: '$offline',
        );
      }
    },
  );

  test('never agreed, never reached: nothing is shared', () async {
    expect(
      await ask(() async => throw http.ClientException('offline')),
      isFalse,
    );
  });

  test('a server answer without a grant clears the mirror at once', () async {
    expect(await ask(() async => _granted()), isTrue);
    expect(await ask(() async => null), isFalse);
    expect(await SmsSharedLearningConsentMirror.isGranted(ns), isFalse);
    expect(
      await ask(() async => throw http.ClientException('offline')),
      isFalse,
      reason: 'a withdrawal stays withdrawn offline',
    );
  });

  test('a withdrawal clears the mirror before any server answer', () async {
    await ask(() async => _granted());
    await SmsSharedLearningConsentMirror.set(ns, false);
    expect(
      await ask(() async => throw http.ClientException('offline')),
      isFalse,
    );
  });

  test(
    'a failure that is not "offline" shares nothing, mirror or not',
    () async {
      await ask(() async => _granted());
      expect(await ask(() async => throw StateError('bad')), isFalse);
      expect(
        await ask(
          () async => throw ApiException('GET /consents failed: 401 {}'),
        ),
        isFalse,
      );
      expect(
        await SmsSharedLearningConsentMirror.isGranted(ns),
        isTrue,
        reason: 'a failed lookup neither grants nor withdraws',
      );
    },
  );

  test(
    'another account, an older policy version and signed-out never match',
    () async {
      await ask(() async => _granted());
      expect(
        await SmsSharedLearningConsentMirror.isGranted('user:two'),
        isFalse,
      );
      expect(
        await SmsSharedLearningConsentMirror.isGranted('signed-out'),
        isFalse,
      );
      SharedPreferences.setMockInitialValues({
        SmsSharedLearningConsentMirror.keyFor(ns): 'sms-shared-learning-v2',
      });
      expect(await SmsSharedLearningConsentMirror.isGranted(ns), isFalse);
    },
  );

  Future<WidgetRef> unwatchedRef(
    WidgetTester tester,
    Future<ConsentRecord?> Function() load,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          app.cacheNamespaceProvider.overrideWithValue(ns),
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

  testWidgets(
    'an offline correction keeps the sharing part for someone who agreed',
    (tester) async {
      var online = true;
      final ref = await unwatchedRef(tester, () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (!online) throw http.ClientException('offline');
        return _granted();
      });
      expect(await tester.runAsync(() => readSharingConsent(ref)), isTrue);
      online = false;
      expect(await tester.runAsync(() => readSharingConsent(ref)), isTrue);
    },
  );

  testWidgets(
    'offline with nothing mirrored an offline correction shares nothing',
    (tester) async {
      final ref = await unwatchedRef(tester, () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw http.ClientException('offline');
      });
      expect(await tester.runAsync(() => readSharingConsent(ref)), isFalse);
    },
  );
}
