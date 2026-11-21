import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/pipeline/stale_questions.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _ns = 'user:a';

Map<String, Object?> _fixture() =>
    (jsonDecode(
              File(
                '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

void main() {
  late Database db;
  late FactStore facts;

  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    db.execute('''
      CREATE TABLE sms_source_decisions (
        namespace TEXT NOT NULL, source_key TEXT NOT NULL, decision TEXT NOT NULL, state TEXT NOT NULL,
        reason_code TEXT NOT NULL, policy_version TEXT NOT NULL, parser_version TEXT, bundle_version INTEGER,
        received_at INTEGER NOT NULL, decided_at INTEGER NOT NULL, PRIMARY KEY(namespace, source_key));
      CREATE TABLE sms_captured_messages (
        namespace TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL, body TEXT NOT NULL,
        received_at INTEGER NOT NULL, repeated_occurrence INTEGER NOT NULL DEFAULT 0, processed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(namespace, id));
    ''');
    facts = FactStore(db, namespace: _ns);
  });
  tearDown(() => db.dispose());

  // A message read by a rule (confidence [confidence]) with an open "can't read it" question, as an older build left it.
  void message(
    String source, {
    required String decision,
    double confidence = .9,
    Map<String, Object?> payload = const {},
    bool withFact = true,
  }) {
    db.execute(
      "INSERT INTO sms_source_decisions VALUES (?,?,?,'final','x','v2','r1',1,0,0)",
      [_ns, source, decision],
    );
    db.execute(
      "INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES (?,?,?,?,0)",
      [_ns, source, 'AX-SYNTH', 'Synthetic notice, nothing to see'],
    );
    if (withFact) {
      final json = _fixture()
        ..['factId'] = sha256.convert(utf8.encode(source)).toString()
        ..['sourceKey'] = source
        ..['confidence'] = confidence;
      facts.insert(Fact.fromJson(json));
    }
    db.execute(
      "INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES (?,?,'template',?, 'open')",
      [_ns, 'review-$source', jsonEncode({'sourceKey': source, ...payload})],
    );
  }

  String statusOf(String source) =>
      db.select(
            'SELECT status FROM v2_review_items WHERE namespace=? AND review_id=?',
            [_ns, 'review-$source'],
          ).single['status']
          as String;

  test('a question left open for a message that is read with confidence is closed', () {
    message('s-confident', decision: 'matched');
    expect(closeStaleTemplateQuestions(db, _ns), 1);
    expect(statusOf('s-confident'), 'resolved');
  });

  test('a reading in doubt, a reopened question and a message nothing read stay open', () {
    message('s-low', decision: 'matched', confidence: .5);
    message('s-reopened', decision: 'matched', payload: {'reason': 'reopened'});
    message('s-unknown', decision: 'unknown', withFact: false);
    message('s-nofact', decision: 'matched', withFact: false);
    expect(closeStaleTemplateQuestions(db, _ns), 0);
    for (final source in ['s-low', 's-reopened', 's-unknown', 's-nofact']) {
      expect(statusOf(source), 'open', reason: source);
    }
  });

  test('a second pass closes nothing more, and another account is never touched', () {
    message('s-confident', decision: 'matched');
    expect(closeStaleTemplateQuestions(db, 'user:other'), 0);
    expect(statusOf('s-confident'), 'open');
    expect(closeStaleTemplateQuestions(db, _ns), 1);
    expect(closeStaleTemplateQuestions(db, _ns), 0);
  });
}
