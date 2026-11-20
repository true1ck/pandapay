import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/draft_verdict_store.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// F-9: `overlay` rebuilt and compiled the whole rule bundle (about 1,150 rules) on every call, from the sync pass,
/// from every re-read marker and from the review screens, all on the UI isolate. The same answer must be handed
/// back until something it is made from changes.
void main() {
  late Database db;
  late SyncStateStore state;
  late Map<String, Object?> json;
  late RuleBundle shared;
  late Rule draft;
  const goodUuid = '11111111-1111-4111-8111-111111111111';

  Map<String, Object?> ready(Map<String, Object?> ruleJson, {String id = goodUuid}) => {
    'templateHash': draft.match.templateHash,
    'status': 'ready',
    'draftId': id,
    'rule': ruleJson,
  };

  void deliver(Map<String, Object?> result) => state.put('ai:${draft.match.templateHash}', jsonEncode(result));

  setUp(() {
    ProvisionalStore.resetBuildCountForTesting();
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    json = (jsonDecode(File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync()) as Map).cast<String, Object?>();
    final all = RuleBundle.fromJson(json);
    draft = all.rules.firstWhere((r) => r.status == RuleStatus.provisional);
    shared = RuleBundle.fromJson({
      ...json,
      'rules': [
        for (final item in all.rules)
          if (item.status != RuleStatus.provisional) item.toJson(),
      ],
    });
    state = SyncStateStore(db, namespace: 'a');
    TemplateOriginStore(state).remember(
      remoteHash: draft.match.templateHash!,
      localHash: 'a' * 64,
      senderBrand: draft.senders.single,
    );
    deliver(ready(draft.toJson()));
  });
  tearDown(() => db.dispose());

  test('the same drafts over the same bundle give the very same overlay, not a second compile', () {
    final first = ProvisionalStore(state).overlay(shared);
    expect(first.bundle.rules, hasLength(shared.rules.length + 1));
    final builds = ProvisionalStore.overlayBuilds;
    for (var i = 0; i < 20; i++) {
      final again = ProvisionalStore(state).overlay(shared);
      expect(identical(again.bundle, first.bundle), isTrue, reason: 'call $i built a new bundle');
      expect(again.revision, first.revision);
    }
    expect(ProvisionalStore.overlayBuilds, builds, reason: 'no further compile');
  });

  test('a changed draft, a rejected one and a recovered one each give the right overlay', () {
    final store = ProvisionalStore(state);
    final first = store.overlay(shared);
    // A revised draft (new id and pattern) replaces the old rule.
    final revised = {
      ...draft.toJson(),
      'match': {...draft.match.toJson(), 'pattern': r'^(?:rs\.?|inr)\s*(?<amt>[\d,]+)\s+paid'},
    };
    deliver(ready(revised, id: '22222222-2222-4222-8222-222222222222'));
    final second = store.overlay(shared);
    expect(identical(second.bundle, first.bundle), isFalse);
    expect(second.revision, isNot(first.revision));
    expect(second.bundle.rules.last.match.pattern, contains('paid'));
    // The server turns the draft down: it goes back to the shared bundle.
    deliver({'templateHash': draft.match.templateHash, 'status': 'rejected', 'rule': revised});
    expect(store.overlay(shared).bundle, same(shared));
    // And a draft that is ready again is rebuilt, not served from before the rejection.
    deliver(ready(draft.toJson()));
    final third = store.overlay(shared);
    expect(third.bundle.rules, hasLength(shared.rules.length + 1));
    expect(third.bundle.rules.last.match.pattern, draft.match.pattern);
  });

  test('this phone refusing a draft, and a new original wording, change the overlay', () {
    final store = ProvisionalStore(state);
    final first = store.overlay(shared);
    TemplateOriginStore(state).remember(
      remoteHash: draft.match.templateHash!,
      localHash: 'b' * 64,
      senderBrand: draft.senders.single,
    );
    final two = store.overlay(shared);
    expect(two.bundle.rules, hasLength(shared.rules.length + 2));
    expect(two.revision, isNot(first.revision));
    DraftVerdictStore(state).put(draft.match.templateHash!, goodUuid, rejected: true);
    expect(store.overlay(shared).bundle, same(shared));
    DraftVerdictStore(state).put(draft.match.templateHash!, goodUuid, rejected: false);
    expect(store.overlay(shared).bundle.rules, hasLength(shared.rules.length + 2));
  });

  test('a new shared bundle is never answered from the old one', () {
    final store = ProvisionalStore(state);
    final first = store.overlay(shared);
    final newer = RuleBundle.fromJson({
      ...shared.toJson(),
      'bundleVersion': shared.bundleVersion + 1,
    });
    final second = store.overlay(newer);
    expect(identical(second.bundle, first.bundle), isFalse);
    expect(second.bundle.bundleVersion, newer.bundleVersion);
    expect(second.revision, startsWith('${newer.bundleVersion}:'));
    // The shared bundle gaining the draft's own id (a promotion) drops the private copy.
    final promoted = RuleBundle.fromJson({
      ...shared.toJson(),
      'rules': [...shared.rules.map((r) => r.toJson()), draft.toJson()],
    });
    expect(store.overlay(promoted).bundle, same(promoted));
  });

  test('accounts do not share an overlay', () {
    final first = ProvisionalStore(state).overlay(shared);
    final other = SyncStateStore(db, namespace: 'b');
    expect(ProvisionalStore(other).overlay(shared).bundle, same(shared));
    expect(identical(ProvisionalStore(state).overlay(shared).bundle, first.bundle), isTrue);
  });

  test('a rule the engine refuses is kept out once, and the answer is then remembered', () {
    final good = ProvisionalStore(state).overlay(shared);
    expect(good.bundle.rules, hasLength(shared.rules.length + 1));
    // A second layout whose private copy has the first one's id (same rule id, same original wording): the bundle
    // refuses the pair, so the phone falls back to trying each rule alone, which used to compile the bundle again
    // for every rule, at every call.
    final clash = draft.toJson();
    final hash = 'c' * 64;
    TemplateOriginStore(state).remember(remoteHash: hash, localHash: 'a' * 64, senderBrand: draft.senders.single);
    state.put(
      'ai:$hash',
      jsonEncode({
        'templateHash': hash,
        'status': 'ready',
        'rule': {
          ...clash,
          'match': {...draft.match.toJson(), 'templateHash': hash},
        },
      }),
    );
    final before = ProvisionalStore.overlayBuilds;
    final first = ProvisionalStore(state).overlay(shared);
    final cost = ProvisionalStore.overlayBuilds - before;
    expect(cost, greaterThan(1), reason: 'the pair was refused and each rule was tried alone');
    final again = ProvisionalStore(state).overlay(shared);
    expect(identical(again.bundle, first.bundle), isTrue);
    expect(again.revision, first.revision);
    expect(ProvisionalStore.overlayBuilds - before, cost, reason: 'the second call compiled nothing');
  });
}
