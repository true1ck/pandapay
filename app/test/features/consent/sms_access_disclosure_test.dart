import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/features/consent/sms_access_disclosure.dart';
import 'package:pandapay/features/consent/sms_reading_consent.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Harness {
  _Harness({this.latestConsents = const [], this.postStatus = 201});

  final List<Map<String, dynamic>> latestConsents;
  final int postStatus;
  final List<Map<String, dynamic>> posted = [];
  bool? result;

  late final http.Client client = MockClient((request) async {
    if (request.method == 'POST' && request.url.path == '/consents') {
      posted.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('{}', postStatus);
    }
    if (request.method == 'GET' && request.url.path == '/consents') {
      return http.Response(jsonEncode({'consents': latestConsents}), 200);
    }
    return http.Response('not found', 404);
  });

  Widget app({required Future<bool> Function(BuildContext, WidgetRef) open}) {
    return ProviderScope(
      overrides: [
        consentsApiProvider.overrideWithValue(
          ConsentsApi(
            apiBaseUrl: 'https://api.test',
            accessToken: 'token',
            client: client,
          ),
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => result = await open(context, ref),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Map<String, dynamic> _consent({
  String policyVersion = '2026-11-15',
  bool granted = true,
  String? revokedAt,
  String purpose = 'sms_reading',
}) => {
  'purpose': purpose,
  'granted': granted,
  'granted_at': '2026-11-15T10:00:00Z',
  'revoked_at': revokedAt,
  'policy_version': policyVersion,
  'source_screen': 'onboarding_sms',
};

/// The gate shows a spinner while it waits, which never lets pumpAndSettle
/// finish; pump a fixed amount of time instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// What the app saved for the server. Consent is local first: the choice is
/// stored and queued at once, and the outbox posts it in the background.
Future<List<Map<String, Object?>>> _queuedConsents(WidgetTester tester) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  return (await tester.runAsync(() async {
    final commands = await container.read(commandOutboxProvider.future);
    return [for (final c in commands.pendingOf({'consent_submit'})) c.payload];
  }))!;
}

Future<void> _openSheet(
  WidgetTester tester,
  _Harness h, {
  String sourceScreen = 'onboarding_sms',
  String? accountLabel = 'a***@example.com',
  bool ios = false,
}) async {
  _bigScreen(tester);
  await tester.pumpWidget(
    h.app(
      open: (context, ref) => SmsAccessDisclosure.show(
        context,
        sourceScreen: sourceScreen,
        accountLabel: accountLabel,
        ios: ios,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the exact Android disclosure copy', (tester) async {
    await _openSheet(tester, _Harness());

    expect(
      find.text('PandaPay reads your bank SMS on this phone'),
      findsOneWidget,
    );
    expect(
      find.text(
        'PandaPay reads messages from banks, cards and wallets to record your '
        'transactions automatically, including in the background when a new '
        'message arrives.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Messages are read on this phone. Only the transaction details '
        '(amount, merchant, date, card or account ending, and type) are sent '
        'to PandaPay, so your spending shows on any phone you sign in to.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Personal messages and one-time passwords are skipped and never sent.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Messages already on this phone will be added to the account '
        'a***@example.com.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('You can turn this off in Settings at any time.'),
      findsOneWidget,
    );
    expect(
      find.text('I agree to PandaPay reading my bank SMS as described.'),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('the iPhone variant replaces only the first bullet', (
    tester,
  ) async {
    await _openSheet(tester, _Harness(), ios: true);

    expect(
      find.text(
        'PandaPay records your transactions from the bank messages you share '
        'with it through the Shortcut.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('reads messages from banks'), findsNothing);
    expect(
      find.textContaining('Messages are read on this phone'),
      findsOneWidget,
    );
    expect(find.textContaining('one-time passwords'), findsOneWidget);
  });

  testWidgets(
    'without an account label the bullet names the account generically',
    (tester) async {
      await _openSheet(tester, _Harness(), accountLabel: null);

      expect(
        find.text(
          'Messages already on this phone will be added to your PandaPay account.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Continue is disabled until the checkbox is ticked', (
    tester,
  ) async {
    final h = _Harness();
    await _openSheet(tester, h);

    FilledButton continueButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Continue'),
    );

    expect(continueButton().onPressed, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(continueButton().onPressed, isNotNull);
    expect(h.posted, isEmpty);
  });

  testWidgets('Not now returns false and posts nothing', (tester) async {
    final h = _Harness();
    await _openSheet(tester, h);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(h.result, isFalse);
    expect(h.posted, isEmpty);
  });

  testWidgets('dismissing the sheet also returns false', (tester) async {
    final h = _Harness();
    await _openSheet(tester, h);
    await tester.tapAt(const Offset(10, 10)); // scrim
    await tester.pumpAndSettle();

    expect(h.result, isFalse);
    expect(h.posted, isEmpty);
  });

  testWidgets(
    'tick plus Continue posts the sms_reading consent and returns true',
    (tester) async {
      final h = _Harness();
      await _openSheet(tester, h, sourceScreen: 'auto_sms_sync');
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(h.result, isTrue);
      expect(h.posted, isEmpty, reason: 'saved first, posted later');
      final queued = await _queuedConsents(tester);
      expect(queued, hasLength(1));
      expect(queued.single, containsPair('purpose', 'sms_reading'));
      expect(queued.single, containsPair('granted', true));
      expect(queued.single, containsPair('policyVersion', '2026-11-15'));
      expect(queued.single, containsPair('sourceScreen', 'auto_sms_sync'));
      expect(queued.single['clientMutationId'], isNotEmpty);
    },
  );

  testWidgets('the choice is saved and the sheet closes without waiting for the server', (
    tester,
  ) async {
    // Even a server that would refuse the post later does not hold the user
    // on the sheet: the choice is kept (and parked for review if refused).
    final h = _Harness(postStatus: 400);
    await _openSheet(tester, h);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(h.result, isTrue);
    expect(h.posted, isEmpty);
    expect(await _queuedConsents(tester), hasLength(1));
  });

  testWidgets('ensureSmsReadingConsent skips the sheet when already granted', (
    tester,
  ) async {
    _bigScreen(tester);
    final h = _Harness(latestConsents: [_consent()]);
    await tester.pumpWidget(
      h.app(
        open: (context, ref) =>
            ensureSmsReadingConsent(context, ref, sourceScreen: 'x'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(h.result, isTrue);
    expect(
      find.text('PandaPay reads your bank SMS on this phone'),
      findsNothing,
    );
    expect(h.posted, isEmpty);
  });

  for (final entry in {
    'no consent yet': <Map<String, dynamic>>[],
    'a withdrawn consent': [_consent(granted: false)],
    'a revoked consent': [_consent(revokedAt: '2026-11-16T10:00:00Z')],
    'a consent for an older policy': [_consent(policyVersion: '2026-08-07')],
    'another purpose only': [_consent(purpose: 'email_import')],
  }.entries) {
    testWidgets('ensureSmsReadingConsent shows the sheet for ${entry.key}', (
      tester,
    ) async {
      _bigScreen(tester);
      final h = _Harness(latestConsents: entry.value);
      await tester.pumpWidget(
        h.app(
          open: (context, ref) =>
              ensureSmsReadingConsent(context, ref, sourceScreen: 'x'),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.text('PandaPay reads your bank SMS on this phone'),
        findsOneWidget,
      );
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(h.result, isFalse);
    });
  }

  testWidgets(
    'the gate hides its child until consent, and pops when declined',
    (tester) async {
      _bigScreen(tester);
      final h = _Harness();
      await tester.pumpWidget(
        h.app(
          open: (context, ref) async {
            final popped = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) => const SmsReadingConsentGate(
                  sourceScreen: 'ios_sms_import',
                  child: Text('shortcut setup'),
                ),
              ),
            );
            return popped ?? false;
          },
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);

      expect(
        find.text('PandaPay reads your bank SMS on this phone'),
        findsOneWidget,
      );
      expect(find.text('shortcut setup'), findsNothing);

      await tester.tap(find.text('Not now'));
      await _settle(tester);
      expect(find.text('shortcut setup'), findsNothing);
      expect(find.text('open'), findsOneWidget); // the gated screen was popped
    },
  );

  testWidgets('the gate shows its child after the user agrees', (tester) async {
    _bigScreen(tester);
    final h = _Harness();
    await tester.pumpWidget(
      h.app(
        open: (context, ref) async {
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => const SmsReadingConsentGate(
                sourceScreen: 'ios_sms_import',
                child: Text('shortcut setup'),
              ),
            ),
          );
          return true;
        },
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    await tester.tap(find.byType(Checkbox));
    await _settle(tester);
    await tester.tap(find.text('Continue'));
    await _settle(tester);

    expect(find.text('shortcut setup'), findsOneWidget);
    expect((await _queuedConsents(tester)).single['sourceScreen'], 'ios_sms_import');
  });

  test('maskedAccountLabel hides most of an email or phone number', () {
    expect(
      maskedAccountLabel({'email': 'asha.rao@example.com'}),
      'a***@example.com',
    );
    expect(maskedAccountLabel({'phone_number': '+919876543210'}), '••••••210');
    expect(maskedAccountLabel(null), isNull);
    expect(maskedAccountLabel({'email': '', 'phone_number': ''}), isNull);
  });

  group('SmsReadingConsentMirror', () {
    test('is per account and ignores the signed-out namespace', () async {
      expect(await SmsReadingConsentMirror.isGranted('user:a'), isFalse);
      await SmsReadingConsentMirror.set('user:a', true);
      expect(await SmsReadingConsentMirror.isGranted('user:a'), isTrue);
      expect(await SmsReadingConsentMirror.isGranted('user:b'), isFalse);
      await SmsReadingConsentMirror.set('signed-out', true);
      expect(await SmsReadingConsentMirror.isGranted('signed-out'), isFalse);
      await SmsReadingConsentMirror.set('user:a', false);
      expect(await SmsReadingConsentMirror.isGranted('user:a'), isFalse);
    });

    test('a mirror from an older policy version does not count', () async {
      SharedPreferences.setMockInitialValues({
        SmsReadingConsentMirror.keyFor('user:a'): '2026-08-07',
      });
      expect(await SmsReadingConsentMirror.isGranted('user:a'), isFalse);
    });

    test(
      'hasSmsReadingConsent refreshes the mirror from a server grant',
      () async {
        final h = _Harness(latestConsents: [_consent()]);
        final api = ConsentsApi(
          apiBaseUrl: 'https://api.test',
          accessToken: 't',
          client: h.client,
        );
        expect(
          await hasSmsReadingConsent(namespace: 'user:a', api: api),
          isTrue,
        );
        expect(await SmsReadingConsentMirror.isGranted('user:a'), isTrue);
        // Mirror answers without any server.
        expect(
          await hasSmsReadingConsent(namespace: 'user:a', api: null),
          isTrue,
        );
        // Another account on the same phone has not agreed.
        expect(
          await hasSmsReadingConsent(namespace: 'user:b', api: null),
          isFalse,
        );
      },
    );
  });
}
