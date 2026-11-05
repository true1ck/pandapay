import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/consent/email_import_disclosure.dart';

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

void main() {
  testWidgets('shows the exact disclosure copy', (tester) async {
    _bigScreen(tester);
    final h = _Harness();
    await tester.pumpWidget(
      h.app(
        open: (context, ref) => EmailImportDisclosure.show(
          context,
          sourceScreen: 'imap_connection',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('PandaPay reads your bank emails'), findsOneWidget);
    expect(
      find.textContaining(
        'Connecting your mailbox lets PandaPay check it regularly',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Only emails from bank and card senders are read'),
      findsOneWidget,
    );
    expect(
      find.textContaining('kept for up to 30 days so you can review them'),
      findsOneWidget,
    );
    expect(find.textContaining('Disconnecting deletes it.'), findsOneWidget);
    expect(
      find.text('I agree to PandaPay reading my bank emails as described.'),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('Continue is disabled until the checkbox is ticked', (
    tester,
  ) async {
    _bigScreen(tester);
    final h = _Harness();
    await tester.pumpWidget(
      h.app(
        open: (context, ref) => EmailImportDisclosure.show(
          context,
          sourceScreen: 'imap_connection',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    FilledButton continueButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Continue'),
    );

    expect(continueButton().onPressed, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(continueButton().onPressed, isNotNull);
    expect(h.posted, isEmpty);
  });

  testWidgets('dismissing returns false and posts nothing', (tester) async {
    _bigScreen(tester);
    final h = _Harness();
    await tester.pumpWidget(
      h.app(
        open: (context, ref) => EmailImportDisclosure.show(
          context,
          sourceScreen: 'imap_connection',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(h.result, isFalse);
    expect(h.posted, isEmpty);
  });

  testWidgets('swiping the sheet away also returns false', (tester) async {
    _bigScreen(tester);
    final h = _Harness();
    await tester.pumpWidget(
      h.app(
        open: (context, ref) => EmailImportDisclosure.show(
          context,
          sourceScreen: 'imap_connection',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // scrim
    await tester.pumpAndSettle();

    expect(h.result, isFalse);
  });

  testWidgets('tick plus Continue posts the consent and returns true', (
    tester,
  ) async {
    _bigScreen(tester);
    final h = _Harness();
    await tester.pumpWidget(
      h.app(
        open: (context, ref) => EmailImportDisclosure.show(
          context,
          sourceScreen: 'email_forwarding',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(h.result, isTrue);
    expect(h.posted, [
      {
        'purpose': 'email_import',
        'granted': true,
        'policyVersion': '2026-11-15',
        'sourceScreen': 'email_forwarding',
      },
    ]);
  });

  testWidgets('a failed post keeps the sheet open and returns nothing', (
    tester,
  ) async {
    _bigScreen(tester);
    final h = _Harness(postStatus: 500);
    await tester.pumpWidget(
      h.app(
        open: (context, ref) => EmailImportDisclosure.show(
          context,
          sourceScreen: 'imap_connection',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(h.result, isNull);
    expect(find.text('PandaPay reads your bank emails'), findsOneWidget);
  });

  testWidgets('ensureEmailImportConsent skips the sheet when already granted', (
    tester,
  ) async {
    _bigScreen(tester);
    final h = _Harness(
      latestConsents: [
        {
          'purpose': 'email_import',
          'granted': true,
          'granted_at': '2026-11-15T10:00:00Z',
          'revoked_at': null,
          'policy_version': '2026-11-15',
          'source_screen': 'imap_connection',
        },
      ],
    );
    await tester.pumpWidget(
      h.app(
        open: (context, ref) => ensureEmailImportConsent(
          context,
          ref,
          sourceScreen: 'imap_connection',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(h.result, isTrue);
    expect(find.text('PandaPay reads your bank emails'), findsNothing);
    expect(h.posted, isEmpty);
  });

  testWidgets('ensureEmailImportConsent shows the sheet when not yet granted', (
    tester,
  ) async {
    _bigScreen(tester);
    final h = _Harness();
    await tester.pumpWidget(
      h.app(
        open: (context, ref) => ensureEmailImportConsent(
          context,
          ref,
          sourceScreen: 'imap_connection',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('PandaPay reads your bank emails'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(h.result, isFalse);
  });

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
                builder: (_) => const Scaffold(
                  body: EmailImportConsentGate(
                    sourceScreen: 'imap_connection',
                    child: Text('connect form'),
                  ),
                ),
              ),
            );
            return popped ?? false;
          },
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);

      expect(find.text('PandaPay reads your bank emails'), findsOneWidget);
      expect(find.text('connect form'), findsNothing);

      await tester.tap(find.text('Not now'));
      await _settle(tester);
      expect(find.text('connect form'), findsNothing);
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
              builder: (_) => const Scaffold(
                body: EmailImportConsentGate(
                  sourceScreen: 'imap_connection',
                  child: Text('connect form'),
                ),
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

    expect(find.text('connect form'), findsOneWidget);
    expect(h.posted.single['sourceScreen'], 'imap_connection');
  });
}
