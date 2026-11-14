import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart' show openInMemoryForTesting;
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/card_state_adapter.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';

class Repository implements UserCardsRepository {
  final patches = <Map<Symbol, dynamic>>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateCard) {
      patches.add(invocation.namedArguments);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

UserCard card({int? limit, double? points}) => UserCard(
  id: 'card',
  cardProductId: 'product',
  cardName: 'Card',
  isDefault: false,
  creditLimit: limit == null ? null : Money.fromPaise(limit),
  pointsBalance: points,
);
Instrument instrument(
  int limit,
  int points, {
  CreditLimitSource source = CreditLimitSource.sms,
}) => Instrument(
  instrumentId: '00000000-0000-4000-8000-000000000001',
  kind: InstrumentKind.creditCard,
  issuerSlug: 'hdfc',
  maskDigits: '1234',
  displayName: 'Card',
  status: InstrumentStatus.confirmed,
  userCardId: 'card',
  creditLimitMinor: limit,
  creditLimitSource: source,
  creditLimitAt: DateTime.utc(2026, 11),
  pointsBalance: points,
  pointsAt: DateTime.utc(2026, 11),
  firstSeenAt: DateTime.utc(2026, 1),
  lastSeenAt: DateTime.utc(2026, 11),
  evidenceCount: 1,
);
void main() {
  test(
    'learned state updates empty values and later SMS state, preserving manual edits',
    () async {
      final repo = Repository();
      final state = CardStateAdapter(repo);
      final previous = instrument(10000, 100);
      expect(await state.apply(previous, card()), isTrue);
      expect(repo.patches.single[#creditLimitInr], 100);
      expect(repo.patches.single[#pointsBalance], 100);
      expect(
        await state.apply(
          instrument(20000, 200),
          card(limit: 10000, points: 100),
          lastApplied: previous,
        ),
        isTrue,
      );
      expect(
        await state.apply(
          instrument(30000, 300),
          card(limit: 99999, points: 999),
          lastApplied: previous,
        ),
        isFalse,
      );
      expect(
        await state.apply(
          instrument(30000, 300, source: CreditLimitSource.user),
          card(limit: 99999, points: 999),
        ),
        isFalse,
      );
      expect(repo.patches.length, 2);
    },
  );

  test('with an outbox the learned value is stored locally and queued, never sent live',
      () async {
    final db = openInMemoryForTesting();
    final store = FinancialStore(db);
    final commands = CommandOutbox(db, namespace: 'ns');
    final repo = Repository();
    final state = CardStateAdapter(
      repo,
      commands: commands,
      store: store,
      namespace: 'ns',
    );
    expect(await state.apply(instrument(10000, 100), card()), isTrue);
    expect(repo.patches, isEmpty);
    expect(commands.pendingCount, 2);
    final limit = commands.pendingOf({'card_fields_patch'}).single;
    expect(limit.payload['creditLimitInr'], 100);
    expect(commands.pendingOf({'points_adjust'}).single.payload['newBalance'], 100);
  });

  test('a learned limit keeps the field edit already queued for the card', () async {
    final db = openInMemoryForTesting();
    final commands = CommandOutbox(db, namespace: 'ns');
    // The person renamed the card offline; the SMS then teaches a limit.
    commands.enqueue(
      kind: 'card_fields_patch',
      target: 'card',
      payload: {'cardId': 'card', 'nickname': 'Travel'},
    );
    final state = CardStateAdapter(
      Repository(),
      commands: commands,
      store: FinancialStore(db),
      namespace: 'ns',
    );
    expect(await state.apply(instrument(10000, 100), card()), isTrue);
    final patch = commands.pendingOf({'card_fields_patch'}).single;
    expect(patch.payload['nickname'], 'Travel');
    expect(patch.payload['creditLimitInr'], 100);
  });
}
