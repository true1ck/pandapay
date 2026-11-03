import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
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
}
