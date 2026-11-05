import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/consent/template_sharing_disclosure.dart';
import 'package:pandapay/features/sms_v2/ui/correction_form.dart';
import 'package:pandapay/features/sms_v2/ui/sharing_offer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _title = 'Help PandaPay read messages like these';
const _body =
    'Share anonymised message layouts and the categories you pick for shops, '
    'so a rule can be added for everyone. Amounts, names and numbers are '
    'removed.';

ConsentRecord _granted() => ConsentRecord(
  purpose: smsSharedLearningPurpose,
  granted: true,
  grantedAt: DateTime.utc(2026, 11, 6),
  policyVersion: smsSharedLearningPolicyVersion,
);

class _Clock {
  _Clock(this.now);
  DateTime now;
}

Future<void> _pump(
  WidgetTester tester, {
  required Widget child,
  ConsentRecord? consent,
  _Clock? clock,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        app.cacheNamespaceProvider.overrideWithValue('ns1'),
        app.smsSharedLearningConsentProvider.overrideWith((ref) async => consent),
        if (clock != null)
          sharingOfferClockProvider.overrideWithValue(() => clock.now),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pumpAndSettle();
}

Future<void> _notNow(WidgetTester tester) async {
  await tester.tap(find.text('Not now'));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows to someone who has not opted in and has open items', (
    tester,
  ) async {
    await _pump(tester, child: const SharingOfferCard(openItems: 2));
    expect(find.text(_title), findsOneWidget);
    expect(find.text(_body), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('is hidden with no open review items', (tester) async {
    await _pump(tester, child: const SharingOfferCard(openItems: 0));
    expect(find.text(_title), findsNothing);
  });

  testWidgets('is hidden once the person has opted in', (tester) async {
    await _pump(
      tester,
      child: const SharingOfferCard(openItems: 3),
      consent: _granted(),
    );
    expect(find.text(_title), findsNothing);
  });

  testWidgets('"Not now" hides it for 30 days and then it returns', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 6, 9));
    await _pump(
      tester,
      child: const SharingOfferCard(openItems: 1),
      clock: clock,
    );
    await _notNow(tester);
    expect(find.text(_title), findsNothing);

    // 29 days later it is still snoozed (a fresh screen reads the saved state).
    clock.now = DateTime.utc(2026, 12, 5, 9);
    await _pump(
      tester,
      child: const SharingOfferCard(openItems: 1),
      clock: clock,
      prefs: await _savedPrefs(),
    );
    expect(find.text(_title), findsNothing);

    clock.now = DateTime.utc(2026, 12, 6, 9, 1);
    await _pump(
      tester,
      child: const SharingOfferCard(openItems: 1),
      clock: clock,
      prefs: await _savedPrefs(),
    );
    expect(find.text(_title), findsOneWidget);
  });

  testWidgets('never shows again after the third "Not now"', (tester) async {
    final clock = _Clock(DateTime.utc(2026, 11, 6, 9));
    for (var tap = 1; tap <= 3; tap++) {
      await _pump(
        tester,
        child: const SharingOfferCard(openItems: 1),
        clock: clock,
        prefs: tap == 1 ? const {} : await _savedPrefs(),
      );
      expect(find.text(_title), findsOneWidget, reason: 'offer $tap shows');
      await _notNow(tester);
      clock.now = clock.now.add(const Duration(days: 31));
    }
    await _pump(
      tester,
      child: const SharingOfferCard(openItems: 1),
      clock: clock,
      prefs: await _savedPrefs(),
    );
    expect(find.text(_title), findsNothing);
    clock.now = clock.now.add(const Duration(days: 3650));
    await _pump(
      tester,
      child: const SharingOfferCard(openItems: 1),
      clock: clock,
      prefs: await _savedPrefs(),
    );
    expect(find.text(_title), findsNothing);
  });

  testWidgets('"Turn on" opens the disclosure and records nothing itself', (
    tester,
  ) async {
    await _pump(tester, child: const SharingOfferCard(openItems: 1));
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(find.byType(TemplateSharingDisclosure), findsOneWidget);
    expect(find.text(TemplateSharingCopy.title), findsOneWidget);
    // The card keeps its own two buttons and the sheet adds the consent ones.
    expect(
      find.descendant(
        of: find.byType(TemplateSharingDisclosure),
        matching: find.text('Turn on'),
      ),
      findsOneWidget,
    );
  });

  group('correction form status line', () {
    Future<void> form(
      WidgetTester tester, {
      ConsentRecord? consent,
      bool loading = false,
    }) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            app.cacheNamespaceProvider.overrideWithValue('ns1'),
            app.smsSharedLearningConsentProvider.overrideWith(
              (ref) => loading
                  ? Completer<ConsentRecord?>().future
                  : Future.value(consent),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: CorrectionForm())),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('opted in: says the fix helps everyone', (tester) async {
      await form(tester, consent: _granted());
      expect(
        find.text(
          'This fix helps everyone. It\'s shared without amounts, names or numbers.',
        ),
        findsOneWidget,
      );
      expect(find.text('Share fixes'), findsNothing);
    });

    testWidgets('not opted in: stays on the phone, with a way to share', (
      tester,
    ) async {
      await form(tester);
      expect(find.text('This fix stays on your phone.'), findsOneWidget);
      expect(find.text('Share fixes'), findsOneWidget);
      await tester.tap(find.text('Share fixes'));
      await tester.pumpAndSettle();
      expect(find.byType(TemplateSharingDisclosure), findsOneWidget);
    });

    testWidgets('while the answer is loading it says nothing', (tester) async {
      await form(tester, loading: true);
      expect(find.text('This fix stays on your phone.'), findsNothing);
      expect(find.textContaining('helps everyone'), findsNothing);
    });
  });
}

/// Reads back what the previous pump saved, as the next screen would.
Future<Map<String, Object>> _savedPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)!};
}
