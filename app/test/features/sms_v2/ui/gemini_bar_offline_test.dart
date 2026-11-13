import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/consents_api.dart' show ConsentRecord;
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/sync/ai_server_status.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';

/// S-04: offline the Gemini bar says so and stops polling, instead of
/// "Could not reach the server" every 10 seconds.
void main() {
  group('geminiBarState', () {
    test("says \"You're offline\" and not that the server was unreachable", () {
      final s = geminiBarState(
        server: null,
        local: const AiReviewStatus(checkingTemplates: {'a'}),
        unreadOnPhone: 2,
        openItems: 4,
        offline: true,
      );
      expect(s.title, "You're offline");
      expect(s.tone, GeminiTone.unknown);
      expect(s.progress, isFalse);
      expect(s.detail, isNot(contains('Could not reach')));
      expect(s.detail, contains('4 still need you'));
      expect(s.detail, contains('1 waiting'));
    });

    test('online and silent keeps the old wording', () {
      final s = geminiBarState(
        server: null,
        local: const AiReviewStatus(),
        unreadOnPhone: 0,
        openItems: 4,
      );
      expect(s.title, 'Gemini status unavailable');
      expect(s.detail, contains('Could not reach the server'));
    });

    test('a recent server answer is still shown offline', () {
      final s = geminiBarState(
        server: const AiServerStatus(countedNow: true, eligible: true),
        local: null,
        unreadOnPhone: 0,
        openItems: 0,
        offline: true,
      );
      expect(s.title, isNot("You're offline"));
    });

    test('sharing off still wins over offline', () {
      final s = geminiBarState(
        server: null,
        local: null,
        unreadOnPhone: 0,
        openItems: 0,
        offline: true,
        sharingOff: true,
      );
      expect(s.title, 'Gemini is off: sharing is off on this phone');
    });
  });

  test('the server status is not asked for while offline', () async {
    final container = ProviderContainer(
      overrides: [
        app.isOnlineProvider.overrideWith((ref) => Stream.value(false)),
        smsV2RuntimeProvider.overrideWith(
          (ref) async =>
              throw StateError('the runtime must not be read offline'),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(app.isOnlineProvider, (_, _) {});
    await container.read(app.isOnlineProvider.future);
    expect(await container.read(geminiServerStatusProvider.future), isNull);
  });

  group('the bar', () {
    Future<int Function()> pumpBar(
      WidgetTester tester, {
      required bool online,
    }) async {
      var asked = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            app.isOnlineProvider.overrideWith((ref) => Stream.value(online)),
            geminiServerStatusProvider.overrideWith((ref) async {
              asked++;
              return null;
            }),
            aiReviewStatusProvider.overrideWith(
              (ref) async => const AiReviewStatus(),
            ),
            aiUnreadCountProvider.overrideWith((ref) async => 0),
            app.smsSharedLearningConsentProvider.overrideWith(
              (ref) async => ConsentRecord(
                purpose: 'sms_shared_learning',
                granted: true,
                grantedAt: DateTime(2026, 11, 1),
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: GeminiStatusBar(openItems: 2)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return () => asked;
    }

    testWidgets("offline it says \"You're offline\" and never polls", (
      tester,
    ) async {
      final asked = await pumpBar(tester, online: false);
      expect(find.text("You're offline"), findsOneWidget);
      expect(find.textContaining('Could not reach'), findsNothing);
      final first = asked();
      await tester.pump(const Duration(seconds: 65));
      expect(asked(), first, reason: 'no polling while offline');
    });

    testWidgets('online and unanswered it keeps asking every 10 seconds', (
      tester,
    ) async {
      final asked = await pumpBar(tester, online: true);
      expect(find.text('Gemini status unavailable'), findsOneWidget);
      final first = asked();
      await tester.pump(const Duration(seconds: 35));
      expect(asked(), greaterThan(first));
    });
  });
}
