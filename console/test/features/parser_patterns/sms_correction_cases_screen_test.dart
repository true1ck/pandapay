import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/features/parser_patterns/sms_correction_cases_screen.dart';

void main() {
  Future<void> pumpCases(
    WidgetTester tester,
    List<Map<String, dynamic>> rows,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          smsCorrectionCasesProvider.overrideWith((ref) async => rows),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SmsCorrectionCasesTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester, String title) async {
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
  }

  testWidgets('renders pattern, kind, origin, previous vs corrected fields, '
      'support, disagreement and category change', (tester) async {
    await pumpCases(tester, [
      {
        'eventId': 'e1',
        'factKey': '${'a' * 64}:0',
        'resolvedKind': 'transaction',
        'correctionKind': 'misclassified_category',
        'decisionOrigin': 'ai',
        'redactedPattern': 'Spent {AMOUNT} at {MERCHANT} on card {REF}',
        'originalDecision': {
          'kind': 'transaction',
          'origin': 'ai',
          'ruleId': null,
          'fields': {
            'merchant': 'Example Cafe',
            'categorySlug': 'travel',
            'amountInr': 450.0,
          },
        },
        'correctedFields': {
          'merchant': 'Example Cafe',
          'categorySlug': 'dining',
          'amountInr': 450.0,
        },
        'categorySlug': 'dining',
        'originalCategorySlug': 'travel',
        'commitmentCategory': null,
        'support': {'users': 7, 'messages': 23},
        'disagreement': {'users': 1},
        'supersededAt': null,
        'supersededByEventId': null,
      },
    ]);

    expect(find.text('Misclassified category'), findsOneWidget);
    await tester.tap(find.text('Misclassified category').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('Spent {AMOUNT} at {MERCHANT}'), findsOneWidget);
    expect(find.textContaining('Category: travel → dining'), findsOneWidget);
    expect(find.textContaining('Support: 7 users · 23 matching SMS'),
        findsOneWidget);
    expect(find.textContaining('Disagreement: 1 users countered'),
        findsOneWidget);
    expect(find.textContaining('State: current'), findsOneWidget);
    // Only changed fields appear in the diff; the unchanged amount/merchant
    // are not repeated, the category flip is.
    expect(find.textContaining('categorySlug: travel → dining'),
        findsOneWidget);
    expect(find.textContaining('amountInr:'), findsNothing);
    expect(find.text('Approve evidence'), findsOneWidget);
    expect(find.text('Reject evidence'), findsOneWidget);
  });

  testWidgets('labels non-training kinds and shows no trainable actions',
      (tester) async {
    await pumpCases(tester, [
      {
        'eventId': 'e2',
        'correctionKind': 'preference_only',
        'decisionOrigin': 'parser',
        'redactedPattern': null,
        'originalDecision': {'kind': 'transaction', 'fields': {}},
        'correctedFields': {},
        'categorySlug': null,
        'support': {'users': 1, 'messages': 1},
        'disagreement': {'users': 0},
        'supersededAt': null,
      },
    ]);

    expect(find.text('Preference — does not train rules'), findsOneWidget);
    await expand(tester, 'Preference — does not train rules');
    expect(
      find.textContaining('never contributes to rule proposals'),
      findsOneWidget,
    );
    expect(find.textContaining('No safe message pattern'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('shows the superseded state of a replaced correction',
      (tester) async {
    await pumpCases(tester, [
      {
        'eventId': 'e3',
        'correctionKind': 'wrong_amount',
        'decisionOrigin': 'downloaded_rule',
        'decisionRuleId': 'rule-42',
        'redactedPattern': 'Debited {AMOUNT} at {MERCHANT}',
        'originalDecision': {
          'kind': 'transaction',
          'origin': 'downloaded_rule',
          'ruleId': 'rule-42',
          'fields': {'amountInr': 100.0},
        },
        'correctedFields': {'amountInr': 150.0},
        'support': {'users': 3, 'messages': 5},
        'disagreement': {'users': 0},
        'supersededAt': '2026-10-27T12:00:00Z',
        'supersededByEventId': 'e4',
      },
    ]);

    expect(find.text('Wrong amount'), findsOneWidget);
    await expand(tester, 'Wrong amount');
    expect(find.textContaining('Superseded by a later correction'),
        findsOneWidget);
    expect(find.textContaining('superseded at 2026-10-27T12:00:00Z by event e4'),
        findsOneWidget);
    expect(find.textContaining('amountInr: 100.0 → 150.0'), findsOneWidget);
    expect(find.textContaining('rule: rule-42'), findsOneWidget);
  });

  testWidgets('approved correction can be revoked and rejected case is terminal',
      (tester) async {
    await pumpCases(tester, [
      {
        'eventId': 'approved-case',
        'correctionKind': 'misclassified_category',
        'reviewStatus': 'approved',
        'decisionOrigin': 'shared_rule',
        'redactedPattern': 'Paid at {MERCHANT}',
        'originalDecision': {'kind': 'transaction', 'fields': {'categorySlug': 'travel'}},
        'correctedFields': {'categorySlug': 'dining'},
        'categorySlug': 'dining',
        'originalCategorySlug': 'travel',
        'support': {'users': 1, 'messages': 1},
        'disagreement': {'users': 0},
        'supersededAt': null,
      },
      {
        'eventId': 'rejected-case',
        'correctionKind': 'misclassified_category',
        'reviewStatus': 'rejected',
        'decisionOrigin': 'ai',
        'redactedPattern': 'Paid at {MERCHANT}',
        'originalDecision': {'kind': 'transaction', 'fields': {'categorySlug': 'travel'}},
        'correctedFields': {'categorySlug': 'dining'},
        'categorySlug': 'dining',
        'originalCategorySlug': 'travel',
        'support': {'users': 1, 'messages': 1},
        'disagreement': {'users': 0},
        'supersededAt': null,
      },
    ]);

    await expand(tester, 'Misclassified category');
    expect(find.text('Revoke approval'), findsOneWidget);
    expect(find.text('Approve evidence'), findsNothing);
    expect(find.text('Reject evidence'), findsNothing);
  });

  testWidgets('renders commitment categories on their own line and never '
      'renders subscription as a spend category slug', (tester) async {
    await pumpCases(tester, [
      {
        'eventId': 'e5',
        'correctionKind': 'misclassified_kind',
        'decisionOrigin': 'shared_rule',
        'decisionRuleId': 'cat-rule-9',
        'redactedPattern': 'Recurring {AMOUNT} payment to {MERCHANT}',
        'originalDecision': {
          'kind': 'bill',
          'origin': 'shared_rule',
          'ruleId': 'cat-rule-9',
          'fields': {'categorySlug': 'bills'},
        },
        'correctedFields': {
          'commitmentCategory': 'subscription',
          'billerName': 'ExampleOTT',
        },
        'categorySlug': null,
        'originalCategorySlug': null,
        'commitmentCategory': 'subscription',
        'support': {'users': 4, 'messages': 9},
        'disagreement': {'users': 0},
        'supersededAt': null,
      },
    ]);

    await expand(tester, 'Misclassified kind');
    expect(find.textContaining('Commitment category: subscription'),
        findsOneWidget);
    // The spend "Category:" line is absent — a commitment label must never
    // masquerade as a spend category slug.
    expect(find.textContaining('Category: subscription'), findsNothing);
    expect(find.textContaining('Category: bills'), findsNothing);
    expect(find.textContaining('commitmentCategory: — → subscription'),
        findsOneWidget);
  });

  testWidgets('drops non-allow-listed decision fields from the render',
      (tester) async {
    await pumpCases(tester, [
      {
        'eventId': 'e6',
        'correctionKind': 'wrong_merchant',
        'decisionOrigin': 'parser',
        'redactedPattern': 'Payment to {MERCHANT}',
        'originalDecision': {
          'kind': 'transaction',
          'fields': {
            'merchant': 'Example Store',
            'smsBody': 'raw OTP 482913 a/c XX1234',
            'referenceNumber': 'REF998877',
          },
        },
        'correctedFields': {
          'merchant': 'Example Store 2',
          'accountNumber': '1234567890',
          'otp': '482913',
        },
        'support': {'users': 1, 'messages': 1},
        'disagreement': {'users': 0},
        'supersededAt': null,
      },
    ]);

    await expand(tester, 'Wrong merchant');
    // Only the allow-listed merchant field diff is rendered; anything that
    // looks like a raw body, account, reference or OTP never appears.
    expect(find.textContaining('merchant: Example Store → Example Store 2'),
        findsOneWidget);
    expect(find.textContaining('482913'), findsNothing);
    expect(find.textContaining('REF998877'), findsNothing);
    expect(find.textContaining('1234567890'), findsNothing);
    expect(find.textContaining('raw OTP'), findsNothing);
    expect(find.textContaining('a/c XX1234'), findsNothing);
  });

  testWidgets('renders the advisory AI diagnosis with sanitized proposal '
      'fields and omits it entirely when absent', (tester) async {
    await pumpCases(tester, [
      {
        'eventId': 'e7',
        'correctionKind': 'wrong_merchant',
        'decisionOrigin': 'ai',
        'redactedPattern': 'Paid {AMOUNT} to {MERCHANT}',
        'originalDecision': {
          'kind': 'transaction',
          'origin': 'ai',
          'fields': {'merchant': 'Example Pay'},
        },
        'correctedFields': {'merchant': 'Example Payments'},
        'support': {'users': 2, 'messages': 4},
        'disagreement': {'users': 0},
        'supersededAt': null,
        'aiDiagnosis': {
          'redactedPattern': 'Paid {AMOUNT} to {MERCHANT}',
          'score': 0.87,
          'proposalStatus': 'pending',
          'proposedFields': {
            'merchant': 'Example Payments',
            'smsBody': 'raw body with OTP 991122',
            'accountNumber': '9988776655',
          },
          'advisory': true,
        },
      },
      {
        'eventId': 'e8',
        'correctionKind': 'cosmetic',
        'decisionOrigin': 'manual',
        'originalDecision': {'kind': 'transaction', 'fields': {}},
        'correctedFields': {},
        'support': {'users': 1, 'messages': 1},
        'disagreement': {'users': 0},
        'supersededAt': null,
      },
    ]);

    await expand(tester, 'Wrong merchant');
    await tester.pumpAndSettle();
    expect(find.textContaining('AI diagnosis (advisory): Paid {AMOUNT}'),
        findsOneWidget);
    expect(find.textContaining('score 0.87'), findsOneWidget);
    expect(find.textContaining('proposal pending'), findsOneWidget);
    // Allow-listed proposal fields render; raw-body/account-shaped ones never do.
    expect(find.textContaining('merchant=Example Payments'), findsOneWidget);
    expect(find.textContaining('991122'), findsNothing);
    expect(find.textContaining('9988776655'), findsNothing);
    expect(find.textContaining('smsBody='), findsNothing);
    expect(find.textContaining('accountNumber='), findsNothing);

    final cosmeticTitle = find.textContaining('Cosmetic');
    expect(cosmeticTitle, findsOneWidget);
    // Collapse the first tile so its advisory line leaves the tree before
    // asserting the second case renders none.
    await tester.tap(find.text('Wrong merchant'));
    await tester.pumpAndSettle();
    await tester.tap(cosmeticTitle.first);
    await tester.pumpAndSettle();
    // A case without a diagnosis block renders no advisory line at all.
    expect(find.textContaining('AI diagnosis (advisory)'), findsNothing);
  });

  test('decisionFieldDiff whitelists keys and skips commitment-only slugs',
      () {
    final diff = decisionFieldDiff(
      {
        'merchant': 'Old',
        'smsBody': 'raw',
        'categorySlug': 'travel',
        'commitmentCategory': 'utility',
      },
      {
        'merchant': 'Old',
        'categorySlug': 'subscription',
        'commitmentCategory': 'subscription',
        'accountNumber': '1234',
      },
    );
    expect(diff.containsKey('merchant'), isFalse, reason: 'unchanged');
    expect(diff.containsKey('smsBody'), isFalse);
    expect(diff.containsKey('accountNumber'), isFalse);
    expect(diff.containsKey('categorySlug'), isFalse,
        reason: 'subscription is not a canonical spend slug');
    expect(diff['commitmentCategory'], ['utility', 'subscription']);
  });

  test('correctionKindLabel marks every non-training kind explicitly', () {
    for (final kind in kNonTrainingCorrectionKinds) {
      expect(correctionKindLabel(kind), contains('does not train rules'));
    }
    expect(correctionKindLabel('misclassified_category'),
        'Misclassified category');
    expect(isCanonicalSpendSlug('subscription'), isFalse);
    expect(isCanonicalSpendSlug('dining'), isTrue);
  });
}
