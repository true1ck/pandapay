import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/duplicate_review_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  final List<DuplicateCandidate> candidates;
  Map<String, dynamic>? lastResolveArgs;
  _FakeUserCardsRepository(this.candidates);

  @override
  Future<List<DuplicateCandidate>> fetchDuplicateCandidates() async => candidates;

  @override
  Future<void> resolveDuplicateCandidate(String id, {required String resolution, String? keepTransactionId}) async {
    lastResolveArgs = {'id': id, 'resolution': resolution, 'keepTransactionId': keepTransactionId};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DuplicateCandidate _pair() => DuplicateCandidate(
      id: 'pair1',
      matchScore: 0.9,
      matchReason: 'Same amount, same day, merchant name matches, different source',
      txnA: DuplicateTransactionSummary(
        id: 'txnA',
        amount: Money.fromRupees(500),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Amazon',
        source: 'sms',
        status: 'active',
        cardDisplayName: 'My Card',
      ),
      txnB: DuplicateTransactionSummary(
        id: 'txnB',
        amount: Money.fromRupees(500),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Amazon',
        source: 'statement',
        status: 'active',
        cardDisplayName: 'My Card',
      ),
    );

Future<void> _pump(WidgetTester tester, {required _FakeUserCardsRepository repo}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [userCardsRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: DuplicateReviewScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when there are no pending duplicates', (tester) async {
    await _pump(tester, repo: _FakeUserCardsRepository(const []));
    expect(find.text('No duplicates to review'), findsOneWidget);
  });

  testWidgets('shows both transactions side by side with the match reason', (tester) async {
    await _pump(tester, repo: _FakeUserCardsRepository([_pair()]));
    expect(find.text('Same amount, same day, merchant name matches, different source'), findsOneWidget);
    expect(find.text('SMS'), findsOneWidget);
    expect(find.text('Statement import'), findsOneWidget);
    expect(find.text('Amazon'), findsNWidgets(2));
  });

  testWidgets('Keep this one resolves as deleted_one with the tapped transaction kept', (tester) async {
    final repo = _FakeUserCardsRepository([_pair()]);
    await _pump(tester, repo: repo);

    await tester.tap(find.text('Keep this one').first);
    await tester.pumpAndSettle();

    expect(repo.lastResolveArgs?['id'], 'pair1');
    expect(repo.lastResolveArgs?['resolution'], 'deleted_one');
    expect(repo.lastResolveArgs?['keepTransactionId'], 'txnA');
  });

  testWidgets('Keep both resolves as kept_both with no keepTransactionId', (tester) async {
    final repo = _FakeUserCardsRepository([_pair()]);
    await _pump(tester, repo: repo);

    await tester.tap(find.text('Keep both — not actually duplicates'));
    await tester.pumpAndSettle();

    expect(repo.lastResolveArgs?['resolution'], 'kept_both');
    expect(repo.lastResolveArgs?['keepTransactionId'], isNull);
  });
}
