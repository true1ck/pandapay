import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay_domain/pandapay_domain.dart'
    show CardNetwork, CardProduct;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// A wallet card must show ALL the spending the messages attribute to it, in
// whatever order the card and the messages arrive. The card page and the
// Activity card filter read the wallet card id stored on each saved row.
const _ns = 'user:spend-link';
const _cardA = '11111111-1111-4111-8111-111111111111';
const _cardB = '22222222-2222-4222-8222-222222222222';

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

UserCard _card(String id, String? last4) => UserCard(
  id: id,
  cardProductId: 'hdfc_millennia',
  cardName: 'HDFC Millennia',
  cardType: 'credit',
  isDefault: false,
  last4: last4,
);

class _Rig {
  _Rig({List<CardProduct>? catalogue}) {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    encoded = File(
      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
    ).readAsStringSync();
    bundle = RuleBundle.fromJson(
      (jsonDecode(encoded) as Map).cast<String, Object?>(),
    );
    body = bundle.rules.first.examples.first.body;
    runtime = _build(catalogue ?? _catalogue);
  }

  /// A runtime as the app rebuilds it when the card catalogue finishes loading.
  void useCatalogue(List<CardProduct> catalogue) =>
      runtime = _build(catalogue);

  SmsV2Runtime _build(List<CardProduct> catalogue) {
    return SmsV2Runtime(
      financial: financial,
      namespace: _ns,
      catalogue: catalogue,
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/sms/v2/rules':
            return http.Response('', 304);
          case '/sms/v2/facts:batch':
            final b =
                jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))) as Map;
            return http.Response(
              jsonEncode({
                'results': [
                  for (final item in b['items'])
                    for (final fact in item['facts'])
                      {
                        'kind': 'fact',
                        'id': fact['factId'],
                        'status': 'accepted',
                      },
                  for (final (key, kind, id) in [
                    ('instruments', 'instrument', 'instrumentId'),
                    ('events', 'event', 'eventId'),
                    ('ledger', 'ledger', 'entryId'),
                  ])
                    for (final row in b[key])
                      {'kind': kind, 'id': row[id], 'status': 'accepted'},
                ],
              }),
              200,
            );
          case '/sms/v2/rule-stats:batch':
            return http.Response('{}', 202);
          case '/sms/v2/sync':
            return http.Response(
              jsonEncode({
                'cursor': 'one',
                'instruments': [],
                'events': [],
                'ledger': [],
                'facts': [],
                'aiResults': [],
                'corrections': [],
                'latestBundleVersion': 1,
              }),
              200,
            );
          default:
            fail('unexpected call ${request.url.path}');
        }
      }),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'test-device',
      appVersion: '2',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async => raw == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      clock: () => DateTime.utc(2026, 11, 20),
    );
  }

  late final AppDatabase db;
  late final FinancialStore financial;
  late final String encoded;
  late final RuleBundle bundle;
  late final String body;
  late SmsV2Runtime runtime;
  var _day = 1;

  void dispose() {
    financial.dispose();
    db.db.dispose();
  }

  /// Receives [n] more spends (one per day) of the same card.
  void receive(int n, {String last4 = '5678'}) {
    for (var i = 0; i < n; i++) {
      SmsImportStore(financial).capture(
        _ns,
        QueuedSms(
          sender: 'VM-HDFCBK-S',
          // A different amount and day each time: identical messages are one
          // transaction, which is not what these tests are about.
          body: body
              .replaceFirst('x5678', 'x$last4')
              .replaceFirst('Rs.499.00', 'Rs.${100 + _day}.00')
              .replaceFirst(
                '2026-11-01',
                '2026-11-${_day.toString().padLeft(2, '0')}',
              ),
          receivedAt: DateTime.utc(2026, 11, _day++, 7),
        ),
      );
    }
  }

  List<Map<String, dynamic>> rows() => financial.entities(_ns, 'transactions');
  Set<Object?> cardIds() => {for (final r in rows()) r['user_card_id']};
  String? mask() =>
      InstrumentStore(db.db, namespace: _ns).list().firstOrNull?.maskDigits;
}

void main() {
  late _Rig rig;
  setUp(() => rig = _Rig());
  tearDown(() => rig.dispose());

  test('spending first, wallet card added after: every row shows the card', () async {
    rig.receive(4);
    await rig.runtime.sync();
    expect(rig.rows(), hasLength(4));
    expect(rig.cardIds(), {null}, reason: 'no wallet card yet');
    rig.financial.replaceCards(_ns, [_card(_cardA, rig.mask())]);
    await rig.runtime.sync();
    expect(rig.cardIds(), {_cardA});
    // Listed under the wallet card's name, not as a bare "Credit card".
    expect(rig.rows().every((r) => r['card_name'] != null), isTrue);
  });

  test('wallet card first, spending after: every row shows the card', () async {
    rig.receive(1);
    await rig.runtime.sync();
    final last4 = rig.mask();
    rig.financial.replaceCards(_ns, [_card(_cardA, last4)]);
    await rig.runtime.sync();
    rig.receive(3);
    await rig.runtime.sync();
    expect(rig.rows(), hasLength(4));
    expect(rig.cardIds(), {_cardA});
  });

  test('more spending after the link keeps joining the card', () async {
    rig.receive(2);
    await rig.runtime.sync();
    rig.financial.replaceCards(_ns, [_card(_cardA, rig.mask())]);
    await rig.runtime.sync();
    rig.receive(2);
    await rig.runtime.sync();
    rig.receive(2);
    await rig.runtime.sync();
    expect(rig.rows(), hasLength(6));
    expect(rig.cardIds(), {_cardA});
  });

  test('a card added without its last 4 still gets its spending', () async {
    rig.receive(3);
    await rig.runtime.sync();
    rig.financial.replaceCards(_ns, [_card(_cardA, null)]);
    await rig.runtime.sync();
    expect(rig.cardIds(), {_cardA});
  });

  test('a card removed and added again gets all the spending, not the old card', () async {
    rig.receive(3);
    await rig.runtime.sync();
    final last4 = rig.mask();
    rig.financial.replaceCards(_ns, [_card(_cardA, last4)]);
    await rig.runtime.sync();
    expect(rig.cardIds(), {_cardA});
    // The person removes the card and adds it again: a new id, the same number.
    rig.financial.replaceCards(_ns, [_card(_cardB, last4)]);
    await rig.runtime.sync();
    expect(
      rig.cardIds(),
      {_cardB},
      reason: 'spending must follow the card that exists now',
    );
    rig.receive(2);
    await rig.runtime.sync();
    expect(rig.rows(), hasLength(5));
    expect(rig.cardIds(), {_cardB});
  });

  test('two live cards with the same number are never merged', () async {
    rig.receive(2);
    await rig.runtime.sync();
    final last4 = rig.mask();
    rig.financial.replaceCards(_ns, [
      _card(_cardA, last4),
      _card(_cardB, last4),
    ]);
    await rig.runtime.sync();
    // Never a guess between two live cards: the spending goes to at most one.
    expect(rig.cardIds().whereType<String>().toSet().length, lessThanOrEqualTo(1));
  });

  test('two different cards each keep only their own spending', () async {
    rig.receive(2);
    rig.receive(3, last4: '1111');
    await rig.runtime.sync();
    expect(rig.rows(), hasLength(5));
    rig.financial.replaceCards(_ns, [
      _card(_cardA, '5678'),
      _card(_cardB, '1111'),
    ]);
    await rig.runtime.sync();
    final byCard = <Object?, int>{};
    for (final r in rig.rows()) {
      byCard[r['user_card_id']] = (byCard[r['user_card_id']] ?? 0) + 1;
    }
    expect(byCard, {_cardA: 2, _cardB: 3});
  });

  test('a wallet card with another number gets none of the spending', () async {
    rig.receive(3);
    await rig.runtime.sync();
    rig.financial.replaceCards(_ns, [_card(_cardA, '9999')]);
    await rig.runtime.sync();
    expect(rig.cardIds(), {null});
  });

  test('an archived card replaced by a new one: the spending follows the new one', () async {
    rig.receive(3);
    await rig.runtime.sync();
    final last4 = rig.mask();
    rig.financial.replaceCards(_ns, [_card(_cardA, last4)]);
    await rig.runtime.sync();
    expect(rig.cardIds(), {_cardA});
    rig.financial.replaceCards(_ns, [_card(_cardB, last4)]);
    rig.financial.replaceCards(_ns, [
      UserCard(
        id: _cardA,
        cardProductId: 'hdfc_millennia',
        cardName: 'HDFC Millennia',
        cardType: 'credit',
        isDefault: false,
        last4: last4,
        isArchived: true,
      ),
    ], archived: true);
    await rig.runtime.sync();
    expect(rig.cardIds(), {_cardB});
  });

  test('syncing again changes nothing', () async {
    rig.receive(3);
    await rig.runtime.sync();
    rig.financial.replaceCards(_ns, [_card(_cardA, rig.mask())]);
    await rig.runtime.sync();
    final before = jsonEncode(rig.rows());
    await rig.runtime.sync();
    await rig.runtime.sync();
    expect(jsonEncode(rig.rows()), before);
  });

  test('a card is not given up on while the catalogue is still loading', () async {
    final early = _Rig(catalogue: const []);
    addTearDown(early.dispose);
    early.receive(3);
    await early.runtime.sync();
    final last4 = early.mask();
    early.financial.replaceCards(_ns, [_card(_cardA, last4)]);
    // The app is up, the card is in the wallet, but the catalogue (which names
    // the card's bank) has not arrived: nothing can be linked, and the run must
    // not be recorded as done.
    await early.runtime.sync();
    expect(early.cardIds(), {null});
    // The catalogue arrives (the runtime is rebuilt): the very next sync links.
    early.useCatalogue(_catalogue);
    await early.runtime.sync();
    expect(early.cardIds(), {_cardA});
  });

  test('a number-less card, two cards of its bank in the inbox: typing the number links the right one', () async {
    rig.receive(3); // card ending 5678
    rig.receive(2, last4: '1234'); // another card of the same bank
    await rig.runtime.sync();
    rig.financial.replaceCards(_ns, [_card(_cardA, null)]);
    await rig.runtime.sync();
    // Two candidates and no number: nothing is guessed.
    expect(rig.cardIds(), {null});
    // The person types the number the card really has.
    rig.financial.replaceCards(_ns, [_card(_cardA, '5678')]);
    await rig.runtime.sync();
    final byCard = <Object?, int>{};
    for (final r in rig.rows()) {
      byCard[r['user_card_id']] = (byCard[r['user_card_id']] ?? 0) + 1;
    }
    expect(byCard, {_cardA: 3, null: 2});
    // And the card keeps one instrument: new messages join it too.
    rig.receive(2);
    await rig.runtime.sync();
    final after = <Object?, int>{};
    for (final r in rig.rows()) {
      after[r['user_card_id']] = (after[r['user_card_id']] ?? 0) + 1;
    }
    expect(after, {_cardA: 5, null: 2});
  });
}
