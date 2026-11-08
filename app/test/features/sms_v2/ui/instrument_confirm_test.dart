import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart' show UserCard;
import 'package:pandapay/features/sms_v2/instruments/card_linker.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/instrument_actions.dart';
import 'package:pandapay_domain/pandapay_domain.dart'
    show CardNetwork, CardProduct;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _namespace = 'user:confirm';
const _creditId = '11111111-1111-4111-8111-111111111111';
const _bankId = '22222222-2222-4222-8222-222222222222';
const _walletCardId = '33333333-3333-4333-8333-333333333333';

final _catalogue = [
  CardProduct(
    id: 'hdfc_millennia',
    name: 'HDFC Millennia',
    issuerName: 'HDFC Bank',
    cardType: 'credit',
    network: CardNetwork.visa,
    isUpiLinkable: false,
    pointValueInr: 1.0,
    rewardRules: const [],
    capRules: const [],
    milestoneRules: const [],
    feeWaiverRules: const [],
    benefits: const [],
  ),
];

UserCard _walletCard({String last4 = '5678'}) => UserCard(
  id: _walletCardId,
  cardProductId: 'hdfc_millennia',
  cardName: 'HDFC Millennia',
  cardType: 'credit',
  isDefault: false,
  last4: last4,
);

Instrument _instrument(
  String id, {
  InstrumentKind kind = InstrumentKind.creditCard,
  InstrumentStatus status = InstrumentStatus.detected,
  String mask = '5678',
}) => Instrument(
  instrumentId: id,
  kind: kind,
  issuerSlug: 'hdfc',
  maskDigits: mask,
  displayName: 'HDFC card',
  status: status,
  firstSeenAt: DateTime.utc(2026, 11, 1),
  lastSeenAt: DateTime.utc(2026, 11, 2),
  evidenceCount: 1,
);

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late InstrumentStore store;

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    SmsV2Schema.ensure(database.db);
    store = InstrumentStore(database.db, namespace: _namespace);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  InstrumentActions actions() => InstrumentActions(
    financial: financial,
    namespace: _namespace,
    bundle: bundle,
    catalogue: _catalogue,
  );

  int queuedInstruments() => OutboxStore(
    database.db,
    namespace: _namespace,
  ).due(DateTime.now()).where((i) => i.kind == 'instrument').length;

  test('a credit card with no wallet card is not confirmed yet', () {
    store.upsert(_instrument(_creditId));

    final result = actions().confirm(_creditId);

    expect(result, isA<CardNeedsProduct>());
    final saved = store.get(_creditId)!;
    expect(saved.status, InstrumentStatus.detected);
    expect(saved.userCardId, isNull);
    // Backing out of the card picker must not tell the server it is confirmed.
    expect(queuedInstruments(), 0);
  });

  test('choosing a card in the picker confirms and links the credit card', () {
    store.upsert(_instrument(_creditId));
    expect(actions().confirm(_creditId), isA<CardNeedsProduct>());

    actions().attachCard(_creditId, _walletCard());

    final saved = store.get(_creditId)!;
    expect(saved.status, InstrumentStatus.confirmed);
    expect(saved.userCardId, _walletCardId);
  });

  test('one matching wallet card confirms and links in a single step', () {
    store.upsert(_instrument(_creditId));
    financial.replaceCards(_namespace, [_walletCard()]);

    final result = actions().confirm(_creditId);

    expect(result, isA<CardLinked>());
    final saved = store.get(_creditId)!;
    expect(saved.status, InstrumentStatus.confirmed);
    expect(saved.userCardId, _walletCardId);
    expect(queuedInstruments(), 1);
  });

  test(
    'a card an older build confirmed without a wallet card can be added later',
    () {
      store.upsert(_instrument(_creditId, status: InstrumentStatus.confirmed));

      // Still no wallet card: it stays as it is and asks for a product.
      expect(actions().confirm(_creditId), isA<CardNeedsProduct>());
      expect(store.get(_creditId)!.userCardId, isNull);

      // Once a wallet card exists, the same action links it.
      financial.replaceCards(_namespace, [_walletCard()]);
      expect(actions().confirm(_creditId), isA<CardLinked>());
      final saved = store.get(_creditId)!;
      expect(saved.status, InstrumentStatus.confirmed);
      expect(saved.userCardId, _walletCardId);
    },
  );

  test('a bank account is confirmed straight away', () {
    store.upsert(_instrument(_bankId, kind: InstrumentKind.bankAccount));

    expect(actions().confirm(_bankId), isNull);

    expect(store.get(_bankId)!.status, InstrumentStatus.confirmed);
  });
}
