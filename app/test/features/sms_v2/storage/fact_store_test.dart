import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

Map<String, Object?> fixture([String name = 'movement.card_spend']) =>
    (jsonDecode(
              File(
                '../contracts/sms/v2/fixtures/valid/fact/$name.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

void main() {
  late Database db;
  late FactStore store;
  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    store = FactStore(db, namespace: 'user:a');
  });
  tearDown(() => db.dispose());

  test('capture retries preserve the first fact and its upload receipt', () {
    final fact = Fact.fromJson(fixture());
    expect(store.insert(fact), isTrue);
    store.markUploaded(fact.factId, DateTime.utc(2026, 11, 10));
    final replay = Fact.fromJson({
      ...fact.toJson(),
      'observedAt': '2026-11-11T00:00:00Z',
    });
    expect(store.insert(replay), isFalse);
    expect(store.forSource(fact.sourceKey).single.toJson(), fact.toJson());
    expect(store.pendingUpload(limit: 10), isEmpty);

    final other = FactStore(db, namespace: 'user:b');
    expect(other.forSource(fact.sourceKey), isEmpty);
    expect(other.insert(replay), isTrue);
    expect(other.pendingUpload(limit: 10).single.toJson(), replay.toJson());
  });

  test('recent facts sort correctly across sub-millisecond boundaries', () {
    final earlier = Fact.fromJson({
      ...fixture(),
      'observedAt': '2026-11-10T00:00:00Z',
    });
    final later = Fact.fromJson({
      ...earlier.toJson(),
      'factId': 'b' * 64,
      'observedAt': '2026-11-10T00:00:00.000001Z',
    });
    expect(store.insert(later), isTrue);
    expect(store.insert(earlier), isTrue);
    expect(store.since(later.observedAt).map((fact) => fact.factId), [
      later.factId,
    ]);
    expect(store.pendingUpload(limit: 1).single.factId, earlier.factId);
  });

  test('info facts stay local and do not consume the upload limit', () {
    final info = Fact.fromJson(fixture('info.service'));
    final movement = Fact.fromJson(fixture());
    expect(store.insert(info), isTrue);
    expect(store.insert(movement), isTrue);
    expect(
      store.forSource(info.sourceKey).any((fact) => fact is InfoFact),
      isTrue,
    );
    expect(store.pendingUpload(limit: 1).single.factId, movement.factId);
  });

  test('rejects invalid facts before persistence', () {
    final valid = Fact.fromJson(fixture()) as MovementFact;
    final fact = MovementFact(
      FactEnvelope(
        factId: 'invalid',
        sourceKey: valid.sourceKey,
        observedAt: valid.observedAt,
        provenance: valid.provenance,
        confidence: valid.confidence,
        amounts: valid.amounts,
      ),
      direction: valid.direction,
      purpose: valid.purpose,
      rail: valid.rail,
    );
    expect(() => store.insert(fact), throwsA(isA<ContractException>()));
    expect(store.pendingUpload(limit: 10), isEmpty);
  });
}
