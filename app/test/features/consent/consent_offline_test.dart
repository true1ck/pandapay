import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';
import 'package:pandapay/data/consent_policy.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/account/account_commands.dart';
import 'package:pandapay/features/account/account_local_first.dart';
import 'package:pandapay/features/consent/consent_commands.dart';
import 'package:pandapay/features/consent/sms_reading_consent.dart';
import 'package:pandapay/features/sms_v2/sync/sharing_consent_mirror.dart';

// WP-C11: consents work without the network. Synthetic data only.

const _ns = 'user:test-account';

void main() {
  late ProviderContainer container;
  late Ref ref;
  late bool reachable;
  late List<Map<String, dynamic>> posted;
  late List<ConsentRecord> serverLatest;

  ConsentsApi api() => ConsentsApi(
    apiBaseUrl: 'http://test.local',
    accessToken: 'tok',
    client: MockClient((request) async {
      if (!reachable) throw const SocketException('offline');
      if (request.method == 'POST') {
        posted.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{}', 201);
      }
      return http.Response(
        jsonEncode({
          'consents': [for (final r in serverLatest) r.toJson()],
        }),
        200,
      );
    }),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    reachable = true;
    posted = [];
    serverLatest = [];
    KnownConnectivity.reset();
    final capture = Provider<void>((r) => ref = r);
    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        consentsApiProvider.overrideWithValue(api()),
      ],
    );
    container.read(capture);
  });

  tearDown(() {
    KnownConnectivity.reset();
    container.dispose();
  });

  Future<int> flush() async {
    final commands = await container.read(commandOutboxProvider.future);
    return commands.flush(accountCommandHandlers(ref));
  }

  Future<int> pending() async =>
      (await container.read(commandOutboxProvider.future)).pendingCount;

  test('revoke offline clears the mirrors first, queues, and sends once', () async {
    await SmsReadingConsentMirror.set(_ns, true);
    await SmsSharedLearningConsentMirror.set(_ns, true);
    KnownConnectivity.online = false;
    reachable = false;

    final r1 = await submitConsentLocalFirst(
      ref,
      purpose: smsReadingConsentPurpose,
      granted: false,
      sourceScreen: 'privacy_permissions',
    );
    final r2 = await submitConsentLocalFirst(
      ref,
      purpose: smsSharedLearningPurpose,
      granted: false,
    );
    expect(r1, AccountWrite.queued);
    expect(r2, AccountWrite.queued);
    expect(await SmsReadingConsentMirror.isGranted(_ns), isFalse);
    expect(await SmsReadingConsentMirror.isGrantedOrCarriedOver(_ns), isFalse);
    expect(await SmsSharedLearningConsentMirror.isGranted(_ns), isFalse);
    expect(await pending(), 2);
    expect(posted, isEmpty);

    // Still offline: nothing is lost.
    expect(await flush(), 0);
    expect(await pending(), 2);

    // Reconnect.
    KnownConnectivity.online = true;
    reachable = true;
    expect(await flush(), 2);
    expect(posted, hasLength(2));
    final reading = posted.firstWhere((p) => p['purpose'] == 'sms_reading');
    expect(reading['granted'], false);
    expect(reading['clientMutationId'], isNotEmpty);
    expect(reading['clientRecordedAt'], isNotEmpty);
    expect(await flush(), 0);
    expect(posted, hasLength(2), reason: 'audit POST is sent once');
    expect(await pending(), 0);
  });

  test('revoke while online sends at once and still clears the mirror', () async {
    await SmsReadingConsentMirror.set(_ns, true);
    final r = await submitConsentLocalFirst(
      ref,
      purpose: smsReadingConsentPurpose,
      granted: false,
    );
    expect(r, AccountWrite.sent);
    expect(posted.single['granted'], false);
    expect(await SmsReadingConsentMirror.isGranted(_ns), isFalse);
    expect(await pending(), 0);
  });

  test('a dead network at the live attempt queues and replays with an id', () async {
    reachable = false; // radio looks up, server does not answer
    await submitConsentLocalFirst(
      ref,
      purpose: smsReadingConsentPurpose,
      granted: false,
    );
    expect(await pending(), 1);
    reachable = true;
    await flush();
    expect(posted.single['clientMutationId'], isNotEmpty);
  });

  test('grant offline (policy text was shown) queues and sets the mirror', () async {
    KnownConnectivity.online = false;
    final r = await submitConsentLocalFirst(
      ref,
      purpose: smsReadingConsentPurpose,
      granted: true,
      sourceScreen: 'disclosure',
    );
    expect(r, AccountWrite.queued);
    expect(await SmsReadingConsentMirror.isGranted(_ns), isTrue);
    expect(await pending(), 1);
  });

  test('offline grant then revoke keeps only the revoke', () async {
    KnownConnectivity.online = false;
    await submitConsentLocalFirst(ref, purpose: 'sms_reading', granted: true);
    await submitConsentLocalFirst(ref, purpose: 'sms_reading', granted: false);
    expect(await pending(), 1);
    KnownConnectivity.online = true;
    await flush();
    expect(posted.single['granted'], false);
    expect(await SmsReadingConsentMirror.isGrantedOrCarriedOver(_ns), isFalse);
  });

  test('a refusal (4xx) is rethrown, not queued', () async {
    final refused = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        consentsApiProvider.overrideWithValue(
          ConsentsApi(
            apiBaseUrl: 'http://test.local',
            accessToken: 'tok',
            client: MockClient((_) async => http.Response('bad', 400)),
          ),
        ),
      ],
    );
    addTearDown(refused.dispose);
    late Ref r;
    refused.read(Provider<void>((x) => r = x));
    await expectLater(
      submitConsentLocalFirst(r, purpose: 'aggregate_insights', granted: true),
      throwsA(anything),
    );
    expect((await refused.read(commandOutboxProvider.future)).pendingCount, 0);
  });

  group('previous policy version carries over (D8)', () {
    void storeOld() {
      SharedPreferences.setMockInitialValues({
        SmsReadingConsentMirror.keyFor(_ns): '2026-08-07',
      });
    }

    test('strict check says no, carry-over says yes', () async {
      storeOld();
      expect(await SmsReadingConsentMirror.isGranted(_ns), isFalse);
      expect(await SmsReadingConsentMirror.isGrantedOrCarriedOver(_ns), isTrue);
    });

    test('server unreachable: still granted', () async {
      storeOld();
      reachable = false;
      expect(await hasSmsReadingConsent(namespace: _ns, api: api()), isTrue);
    });

    test('server reachable, no current grant: re-prompt, stop carrying', () async {
      storeOld();
      expect(await hasSmsReadingConsent(namespace: _ns, api: api()), isFalse);
      expect(await SmsReadingConsentMirror.isGrantedOrCarriedOver(_ns), isFalse);
    });

    test('server reachable with a current grant: refreshed', () async {
      storeOld();
      serverLatest = [
        ConsentRecord(
          purpose: 'sms_reading',
          granted: true,
          grantedAt: DateTime.utc(2026, 11, 20),
          policyVersion: consentPolicyVersion,
        ),
      ];
      expect(await hasSmsReadingConsent(namespace: _ns, api: api()), isTrue);
      expect(await SmsReadingConsentMirror.isGranted(_ns), isTrue);
    });

    test('no mirror and unreachable is never granted', () async {
      reachable = false;
      await expectLater(
        hasSmsReadingConsent(namespace: _ns, api: api()),
        throwsA(anything),
      );
    });
  });
}
