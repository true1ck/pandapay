import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/sync/ai_status.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';

void main() {
  final hash = 'b' * 64;
  LocalReviewItem item({bool reading = false}) => LocalReviewItem(
    id: 's1',
    kind: 'template',
    payload: {
      'sourceKey': 's1',
      'templateHash': hash,
      'hasReading': reading,
      if (reading) 'reading': 'debit ₹120.0 Shop',
    },
  );

  Widget host(AiReviewStatus status, LocalReviewItem item) => MaterialApp(
    home: Scaffold(
      body: ReviewInboxList(
        items: [item],
        onAction: (_, _) {},
        aiStatus: status,
      ),
    ),
  );

  testWidgets('an uploaded, unanswered format says it is being checked', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(AiReviewStatus(checkingTemplates: {hash}), item()),
    );
    expect(find.textContaining('Checking with AI'), findsOneWidget);
    expect(find.textContaining('can’t read this message format'), findsNothing);
  });

  testWidgets('without an AI check the plain message stays', (tester) async {
    await tester.pumpWidget(host(const AiReviewStatus(), item()));
    expect(find.textContaining('Checking with AI'), findsNothing);
    expect(find.textContaining('can’t read this message format'), findsOneWidget);
  });

  testWidgets('an AI reading is labelled unverified, then verified', (
    tester,
  ) async {
    final it = item(reading: true);
    await tester.pumpWidget(
      host(
        AiReviewStatus(
          resolved: {
            's1': const AiResolution(ruleId: 'AI-x', verified: false),
          },
        ),
        it,
      ),
    );
    expect(find.text('AI suggested, not yet verified'), findsOneWidget);
    await tester.pumpWidget(
      host(
        AiReviewStatus(
          resolved: {'s1': const AiResolution(ruleId: 'AI-x', verified: true)},
        ),
        it,
      ),
    );
    expect(find.text('Verified by PandaPay'), findsOneWidget);
    expect(find.text('AI suggested, not yet verified'), findsNothing);
  });

  group('Try again', () {
    testWidgets('is offered on a format the AI could not read, and asks for a retry of that group', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReviewInboxList(
              items: [item()],
              onAction: (group, action) => asked.add('$action:${group.length}'),
              aiStatus: AiReviewStatus(retryable: {hash}),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('try-again')), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.byKey(const Key('try-again')));
      expect(asked, ['try-again:1']);
    });

    testWidgets('after pressing, the card says Trying again and offers no second press', (tester) async {
      await tester.pumpWidget(host(AiReviewStatus(retrying: {hash}), item()));
      expect(find.byKey(const Key('ai-retrying')), findsOneWidget);
      expect(find.textContaining('Trying again'), findsOneWidget);
      expect(find.byKey(const Key('try-again')), findsNothing);
      expect(find.textContaining('can’t read this message format'), findsNothing);
    });

    testWidgets('is not offered while checking, with no AI check, or on a message that has a reading', (tester) async {
      await tester.pumpWidget(host(AiReviewStatus(checkingTemplates: {hash}), item()));
      expect(find.byKey(const Key('try-again')), findsNothing);
      await tester.pumpWidget(host(const AiReviewStatus(), item()));
      expect(find.byKey(const Key('try-again')), findsNothing);
      await tester.pumpWidget(
        host(
          AiReviewStatus(
            retryable: {hash},
            resolved: {'s1': const AiResolution(ruleId: 'AI-x', verified: false)},
          ),
          item(reading: true),
        ),
      );
      expect(find.byKey(const Key('try-again')), findsNothing);
    });
  });
}
