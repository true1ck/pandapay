import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// `fixtures/real_gemini_rule.json` is a rule a real Gemini call returned for
/// a synthetic layout (server validated, first attempt). This proves the phone
/// accepts such a rule and reads a real-looking message with it.
void main() {
  for (final (file, reads) in [
    ('real_gemini_rule.json', true),
    // The first real draft used references.ref, which the fact contract does
    // not allow. The server now refuses such a draft; the phone always did.
    ('real_gemini_rule_bad_reference.json', false),
  ]) {
    test(
      'real Gemini draft $file ${reads ? 'reads' : 'is refused for'} the message',
      () {
        _check(file, reads);
      },
    );
  }
}

void _check(String file, bool reads) {
  {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    SmsV2Schema.ensure(db);
    final fixture =
        (jsonDecode(
                  File(
                    'test/features/sms_v2/fixtures/$file',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();
    final remoteHash = fixture['hash'] as String;
    final shared = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>()
        ..['rules'] = <Object?>[],
    );
    final message = SmsMessage(
      sender: 'AX-HDFCBK-S',
      iosFilter: normalizeSenderBrand('AX-HDFCBK-S').iosFilter,
      body:
          'Sent Rs.450.00 from HDFC Bank A/c XX1234 to RAHUL KUMAR on 20-11-26. Ref 123456789.',
      observedAt: DateTime.utc(2026, 11, 20, 8),
      sourceKey: 'real-gemini-1',
    );
    final engine = RuleEngine();
    final before = engine.interpretDetailed(message, shared, appVersion: '1');
    expect(before.result.outcome, InterpretOutcome.unknown);
    final localHash = before.result.templateHash;

    final state = SyncStateStore(db, namespace: 'user:1');
    TemplateOriginStore(state).remember(
      remoteHash: remoteHash,
      localHash: localHash,
      senderBrand: 'HDFCBK',
    );
    state.put(
      'ai:$remoteHash',
      jsonEncode({
        'templateHash': remoteHash,
        'status': 'ready',
        'rule': fixture['rule'],
      }),
    );
    final overlay = ProvisionalStore(state).overlay(shared);
    expect(
      overlay.bundle.rules,
      hasLength(1),
      reason: 'the phone kept the rule',
    );

    final after = engine.interpretDetailed(
      message,
      overlay.bundle,
      appVersion: '1',
    );
    if (!reads) {
      expect(after.result.outcome, InterpretOutcome.unknown);
      expect(after.reason, 'rule_emitted_invalid');
      return;
    }
    expect(after.result.outcome, isNot(InterpretOutcome.unknown));
    final fact = after.result.facts.whereType<MovementFact>().single;
    expect(fact.direction.wire, 'debit');
    expect(fact.amounts.single.minor, 45000);
    expect(fact.counterparty?.name, 'RAHUL KUMAR');
    expect(after.result.ruleId, contains(':local:'));
  }
}
