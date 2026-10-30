import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/features/parser_patterns/sms_category_proposals_screen.dart';

void main() {
  testWidgets('shows context scoped category evidence without raw SMS fields',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          smsCategoryProposalsProvider.overrideWith((ref) async => [
                {
                  'merchant_key': 'ACME SHOP',
                  'sender_key': 'AD-HDFCBK',
                  'context_key': 'GROCERY',
                  'fact_family': 'posted_movement',
                  'category_slug': 'groceries',
                  'support_count': 12,
                  'agreement_rate': 0.95,
                  'redacted_pattern': 'GROCERY purchase at {MERCHANT} for {AMOUNT}',
                  'redacted_samples': [
                    'GROCERY purchase at {MERCHANT} for {AMOUNT}',
                  ],
                  'status': 'pending',
                  'sms_body': 'sensitive raw message must not appear',
                },
              ]),
        ],
        child: const MaterialApp(home: SmsCategoryProposalsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Sender: AD-HDFCBK'), findsOneWidget);
    expect(find.textContaining('Context: GROCERY'), findsOneWidget);
    expect(find.textContaining('Family: posted_movement'), findsOneWidget);
    expect(find.textContaining('Redacted SMS pattern: GROCERY purchase at'),
        findsOneWidget);
    expect(find.textContaining('Redacted examples: GROCERY purchase at'),
        findsOneWidget);
    expect(find.textContaining('sensitive raw message must not appear'),
        findsNothing);
  });
}
