import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'private template rules are account-scoped and leave signed shared rules intact',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      SmsV2Schema.ensure(db);
      final json =
          (jsonDecode(
                    File(
                      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                    ).readAsStringSync(),
                  )
                  as Map)
              .cast<String, Object?>();
      final bundle = RuleBundle.fromJson(json);
      final rule = bundle.rules.firstWhere(
        (rule) => rule.status == RuleStatus.provisional,
      );
      final shared = RuleBundle.fromJson({
        ...json,
        'rules': [
          for (final item in bundle.rules)
            if (item.status != RuleStatus.provisional) item.toJson(),
        ],
      });
      final state = SyncStateStore(db, namespace: 'a');
      final origins = TemplateOriginStore(state);
      origins.remember(
        remoteHash: rule.match.templateHash!,
        localHash: 'a' * 64,
        senderBrand: rule.senders.single,
      );
      state.put(
        'ai:${rule.match.templateHash}',
        jsonEncode({
          'templateHash': rule.match.templateHash,
          'status': 'ready',
          'rule': rule.toJson(),
        }),
      );
      final first = ProvisionalStore(state).overlay(shared);
      expect(first.bundle.rules, hasLength(shared.rules.length + 1));
      expect(shared.rules, hasLength(bundle.rules.length - 1));
      expect(first.revision, isNot('${shared.bundleVersion}'));
      expect(first.bundle.rules.last.match.templateHash, 'a' * 64);
      expect(first.bundle.rules.last.id, contains(':local:'));
      expect(
        ProvisionalStore(
          SyncStateStore(db, namespace: 'b'),
        ).overlay(shared).bundle,
        shared,
      );
      state.put(
        'ai:${rule.match.templateHash}',
        jsonEncode({
          'templateHash': 'b' * 64,
          'status': 'ready',
          'rule': rule.toJson(),
        }),
      );
      expect(ProvisionalStore(state).overlay(shared).bundle, shared);
    },
  );

  test('an unsigned private rule with a backtracking pattern never reaches the engine', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    SmsV2Schema.ensure(db);
    final json =
        (jsonDecode(
                  File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();
    final bundle = RuleBundle.fromJson(json);
    final rule = bundle.rules.firstWhere((r) => r.status == RuleStatus.provisional);
    final shared = RuleBundle.fromJson({
      ...json,
      'rules': [
        for (final item in bundle.rules)
          if (item.status != RuleStatus.provisional) item.toJson(),
      ],
    });
    final state = SyncStateStore(db, namespace: 'a');
    TemplateOriginStore(state).remember(
      remoteHash: rule.match.templateHash!,
      localHash: 'a' * 64,
      senderBrand: rule.senders.single,
    );
    Map<String, Object?> withPattern(String pattern) => {
      ...rule.toJson(),
      'match': {...rule.match.toJson(), 'pattern': pattern},
    };
    void deliver(Map<String, Object?> ruleJson) => state.put(
      'ai:${rule.match.templateHash}',
      jsonEncode({
        'templateHash': rule.match.templateHash,
        'status': 'ready',
        'rule': ruleJson,
      }),
    );
    deliver(withPattern(r'^(a|aa)+$'));
    expect(ProvisionalStore(state).overlay(shared).bundle, shared);
    deliver(withPattern('x' * 2001));
    expect(ProvisionalStore(state).overlay(shared).bundle, shared);
    deliver(withPattern(r'^(?:rs\.?|inr)\s*(?<amt>[\d,]+)'));
    expect(ProvisionalStore(state).overlay(shared).bundle.rules, hasLength(shared.rules.length + 1));
  });

  test(
    'origin mappings bound each remote format and reject malformed state',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      SmsV2Schema.ensure(db);
      final state = SyncStateStore(db, namespace: 'a');
      final origins = TemplateOriginStore(state);
      final remote = 'a' * 64;
      for (var i = 0; i < TemplateOriginStore.maxOrigins; i++) {
        expect(
          origins.remember(
            remoteHash: remote,
            localHash: i.toRadixString(16).padLeft(64, '0'),
            senderBrand: 'HDFCBK',
          ),
          isTrue,
        );
      }
      expect(
        origins.remember(
          remoteHash: remote,
          localHash: 'b' * 64,
          senderBrand: 'HDFCBK',
        ),
        isFalse,
      );
      expect(
        origins.get(remote)!.localHashes,
        hasLength(TemplateOriginStore.maxOrigins),
      );
      expect(
        origins.remember(
          remoteHash: remote,
          localHash: '0' * 64,
          senderBrand: 'OTHER',
        ),
        isFalse,
      );
      expect(
        TemplateOriginStore(SyncStateStore(db, namespace: 'b')).get(remote),
        isNull,
      );
      state.put(
        'template:origins:$remote',
        jsonEncode({
          'senderBrand': 'HDFCBK',
          'localHashes': ['bad'],
        }),
      );
      expect(origins.get(remote), isNull);
    },
  );
}
