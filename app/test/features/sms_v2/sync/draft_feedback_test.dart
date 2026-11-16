import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/storage/draft_verdict_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay/features/sms_v2/sync/draft_check.dart';
import 'package:pandapay/features/sms_v2/sync/draft_feedback.dart';
import 'package:pandapay/features/sms_v2/sync/template_upload.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:sqlite3/sqlite3.dart';

const _ns = 'user:draft';
const _sender = 'VM-HDFCCC-S (smsft_fi)';
const _body = 'Rs.125.40 paid from card XX1234 to ACME STORE.';
const _draftA = '11111111-1111-4111-8111-111111111111';
const _draftB = '22222222-2222-4222-8222-222222222222';
final _remote = 'c' * 64;
final _now = DateTime.utc(2026, 11, 4);

late RuleBundle _full;
late RuleBundle _shared;

Map<String, Object?> _rule({
  String pattern =
      r'^Rs\.(?<amt>\d+(?:\.\d{1,2})?) paid from card XX(?<mask>\d{4}) to (?<merchant>[A-Z ]+)\.$',
  String amountFrom = 'amt',
}) => {
  ..._full.rules.first.toJson(),
  'id': 'AI-$_remote',
  'version': 1,
  'status': 'provisional',
  'createdBy': 'ai:synthetic',
  'senders': [smsTemplateBrand(_sender)],
  'match': {'pattern': pattern, 'flags': 'i', 'templateHash': _remote},
  'emit': [
    {
      'factType': 'movement',
      'attrs': {'direction': 'debit', 'purpose': 'purchase', 'rail': 'card'},
      'amounts': [
        {'role': 'posted', 'from': amountFrom, 'unit': 'INR'},
      ],
      'instrument': {'kind': 'credit_card', 'maskFrom': 'mask'},
      'counterparty': {'nameFrom': 'merchant', 'kind': 'merchant'},
    },
  ],
};

Map<String, Object?> _result(Map<String, Object?> rule, {String? draftId = _draftA}) => {
  'templateHash': _remote,
  'status': 'ready',
  'ruleId': rule['id'],
  'ruleVersion': 1,
  'draftId': ?draftId,
  'rule': rule,
};

class _Phone {
  _Phone({bool withMessage = true, String body = _body}) {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    SmsV2Schema.ensure(db.db);
    intake = SmsIntakeRepository(db);
    queue = OutboxStore(db.db, namespace: _ns);
    state = SyncStateStore(db.db, namespace: _ns);
    if (withMessage) {
      intake.remember(_ns, QueuedSms(sender: _sender, body: body, receivedAt: _now));
      final key = smsSourceKey(_ns, _sender, body);
      db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        _ns,
        key,
        'template',
        jsonEncode({'sourceKey': key}),
        'open',
      ]);
      TemplateOriginStore(state).remember(
        remoteHash: _remote,
        localHash: smsTemplateHash(smsTemplateBrand(_sender), smsSkeleton(body)),
        senderBrand: smsTemplateBrand(_sender),
      );
    }
  }
  late final AppDatabase db;
  late final SmsIntakeRepository intake;
  late final OutboxStore queue;
  late final SyncStateStore state;
  void dispose() => db.db.dispose();

  void store(Map<String, Object?> result) =>
      state.put('ai:$_remote', jsonEncode(result));

  DraftVerifier verifier() =>
      DraftVerifier(intake: intake, queue: queue, accountIsCurrent: () => true);

  Map<String, Object?>? verdictRow() {
    final v = DraftVerdictStore(state).get(_remote);
    return v == null ? null : {'id': v.draftId, 'rejected': v.rejected};
  }

  List<Map<String, Object?>> reports() => [
    for (final r in queue.due(DateTime.utc(2100)).where((r) => r.kind == 'draft_rejection')) r.json,
  ];
}

void main() {
  setUpAll(() {
    _full = RuleBundle.fromJson(
      (jsonDecode(File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync()) as Map)
          .cast<String, Object?>(),
    );
    _shared = RuleBundle.fromJson({
      ..._full.toJson(),
      'rules': [
        for (final r in _full.rules)
          if (r.status != RuleStatus.provisional) r.toJson(),
      ],
    });
  });

  DraftCheck check(Map<String, Object?> result, List<String> bodies) => checkDraft(
    sharedJson: _shared.toJson(),
    result: result,
    senderBrand: smsTemplateBrand(_sender),
    messages: [for (final b in bodies) (sender: _sender, body: b, receivedAt: _now)],
  );

  group('checkDraft', () {
    test('a sound rule passes', () {
      expect(check(_result(_rule()), [_body]), DraftCheck.pass);
    });
    test('a rule that does not match the message is no_match', () {
      final r = _rule(pattern: r'^Rs\.(?<amt>\d+) refunded to (?<mask>\d{4}) (?<merchant>[A-Z ]+)$');
      expect(check(_result(r), [_body]), DraftCheck.noMatch);
    });
    test('a rule the engine refuses to emit is invalid_facts', () {
      expect(check(_result(_rule(amountFrom: 'nope')), [_body]), DraftCheck.invalidFacts);
    });
    test('a backtracking pattern is unsafe_rule', () {
      final r = _rule(pattern: r'^(a+)+$');
      expect(lintRegexDialect(r'^(a+)+$', 'i'), isNotEmpty);
      expect(check(_result(r), [_body]), DraftCheck.unsafeRule);
    });
    test('a rule for another layout or sender is unsafe_rule', () {
      final r = _rule()..['senders'] = ['OTHER'];
      expect(check(_result(r), [_body]), DraftCheck.unsafeRule);
    });
    test('passes when at least one of the messages reads; fails only when all fail', () {
      const other = 'Refund of Rs.10.00 received on XX1234.';
      expect(check(_result(_rule()), [other, _body]), DraftCheck.pass);
      expect(check(_result(_rule()), [other]), DraftCheck.noMatch);
    });
  });

  group('verifier', () {
    test('no original message on the phone: nothing is decided or reported', () async {
      final p = _Phone(withMessage: false);
      addTearDown(p.dispose);
      TemplateOriginStore(p.state).remember(
        remoteHash: _remote,
        localHash: 'd' * 64,
        senderBrand: smsTemplateBrand(_sender),
      );
      p.store(_result(_rule(pattern: r'^nothing$')));
      expect(await p.verifier().verifyPending(_shared), 0);
      expect(p.verdictRow(), isNull);
      expect(p.reports(), isEmpty);
      expect(ProvisionalStore(p.state).overlay(_shared).bundle.rules, hasLength(_shared.rules.length + 1));
    });

    test('a result without a draftId is never checked or reported', () async {
      final p = _Phone();
      addTearDown(p.dispose);
      p.store(_result(_rule(pattern: r'^nothing$'), draftId: null));
      expect(await p.verifier().verifyPending(_shared), 0);
      expect(p.reports(), isEmpty);
    });

    test('a passing draft is marked verified and stays adopted', () async {
      final p = _Phone();
      addTearDown(p.dispose);
      p.store(_result(_rule()));
      expect(await p.verifier().verifyPending(_shared), 1);
      expect(p.verdictRow(), {'id': _draftA, 'rejected': false});
      expect(p.reports(), isEmpty);
      expect(ProvisionalStore(p.state).overlay(_shared).bundle.rules, hasLength(_shared.rules.length + 1));
      // Restart: already verified, not checked again.
      expect(await p.verifier().verifyPending(_shared), 0);
    });

    test('a failing draft is rejected locally, skipped by the overlay and reported once', () async {
      final p = _Phone();
      addTearDown(p.dispose);
      p.store(_result(_rule(pattern: r'^nothing$')));
      expect(await p.verifier().verifyPending(_shared), 1);
      expect(p.verdictRow(), {'id': _draftA, 'rejected': true});
      expect(p.reports(), [
        {'draftId': _draftA, 'reason': 'no_match'},
      ]);
      expect(ProvisionalStore(p.state).overlay(_shared).bundle, _shared);
      // The review item is still open (manual review).
      expect(
        p.db.db.select("SELECT 1 FROM v2_review_items WHERE status='open'"),
        hasLength(1),
      );
      // Re-running (restart) does not duplicate the report.
      await p.verifier().verifyPending(_shared);
      expect(p.reports(), hasLength(1));
    });

    test('a different draftId clears the verdict and is checked afresh', () async {
      final p = _Phone();
      addTearDown(p.dispose);
      p.store(_result(_rule(pattern: r'^nothing$')));
      await p.verifier().verifyPending(_shared);
      DraftVerdictStore(p.state).clearIfReplaced(_remote, _draftB);
      expect(p.verdictRow(), isNull);
      p.store(_result(_rule(), draftId: _draftB));
      expect(ProvisionalStore(p.state).overlay(_shared).bundle.rules, hasLength(_shared.rules.length + 1));
      expect(await p.verifier().verifyPending(_shared), 1);
      expect(p.verdictRow(), {'id': _draftB, 'rejected': false});
    });

    test('same draftId arriving again keeps the verdict', () async {
      final p = _Phone();
      addTearDown(p.dispose);
      p.store(_result(_rule(pattern: r'^nothing$')));
      await p.verifier().verifyPending(_shared);
      DraftVerdictStore(p.state).clearIfReplaced(_remote, _draftA);
      expect(p.verdictRow(), {'id': _draftA, 'rejected': true});
    });

    test('revoking consent removes verdicts and queued reports', () async {
      final p = _Phone();
      addTearDown(p.dispose);
      p.store(_result(_rule(pattern: r'^nothing$')));
      await p.verifier().verifyPending(_shared);
      expect(p.reports(), hasLength(1));
      await DraftRejectionUpload(
        queue: p.queue,
        client: MockClient((_) async => http.Response('{}', 500)),
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        hasConsent: () async => false,
        accountIsCurrent: () => true,
        clock: () => _now,
      ).drain();
      expect(p.reports(), isEmpty);
      expect(p.verdictRow(), isNull);
      expect(p.state.get('ai:$_remote'), isNull);
    });
  });

  group('DraftRejectionUpload', () {
    Future<({_Phone p, List<http.Request> calls})> run(
      http.Response Function() answer, {
      bool consent = true,
      DateTime? at,
    }) async {
      final p = _Phone();
      addTearDown(p.dispose);
      p.queue.enqueue('draft_rejection', _draftA, {'draftId': _draftA, 'reason': 'no_match'});
      final calls = <http.Request>[];
      await DraftRejectionUpload(
        queue: p.queue,
        client: MockClient((r) async {
          calls.add(r);
          return answer();
        }),
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {'Authorization': 'Bearer t', 'X-Attest': 'a'},
        hasConsent: () async => consent,
        accountIsCurrent: () => true,
        clock: () => at ?? _now,
      ).drain();
      return (p: p, calls: calls);
    }

    test('200 sends only draftId and reason with auth headers, then clears', () async {
      final r = await run(() => http.Response('{"status":"recorded"}', 200));
      expect(r.calls.single.url.path, '/sms/v2/draft-rejections');
      expect(jsonDecode(r.calls.single.body), {'draftId': _draftA, 'reason': 'no_match'});
      expect(r.calls.single.headers['Authorization'], 'Bearer t');
      expect(r.calls.single.headers['X-Attest'], 'a');
      expect(r.p.reports(), isEmpty);
    });
    test('already_recorded clears too', () async {
      final r = await run(() => http.Response('{"status":"already_recorded"}', 200));
      expect(r.p.reports(), isEmpty);
    });
    test('404 draft_not_delivered drops the report', () async {
      final r = await run(() => http.Response('{"error":"draft_not_delivered"}', 404));
      expect(r.p.reports(), isEmpty);
    });
    test('404 without that code is retried, not dropped', () async {
      final r = await run(() => http.Response('not found', 404));
      expect(r.p.queue.due(_now), isEmpty);
      expect(r.p.reports(), hasLength(1));
    });
    test('403 keeps the report, backed off', () async {
      final r = await run(() => http.Response('{"error":"attestation_required"}', 403));
      expect(r.calls, hasLength(1));
      expect(r.p.queue.due(_now), isEmpty);
      expect(r.p.reports(), hasLength(1));
    });
    test('429 holds until Retry-After (at least 5 minutes)', () async {
      final r = await run(() => http.Response('{}', 429, headers: {'retry-after': '10'}));
      expect(r.p.queue.due(_now.add(const Duration(minutes: 4))), isEmpty);
      expect(r.p.queue.due(_now.add(const Duration(minutes: 6))), hasLength(1));
      expect(r.p.state.get('draft:wait'), isNotNull);
    });
    test('503 backs off and keeps the report', () async {
      final r = await run(() => http.Response('{}', 503));
      expect(r.p.queue.due(_now), isEmpty);
      expect(r.p.reports(), hasLength(1));
    });
    test('a network failure backs off and keeps the report', () async {
      final p = _Phone();
      addTearDown(p.dispose);
      p.queue.enqueue('draft_rejection', _draftA, {'draftId': _draftA, 'reason': 'no_match'});
      await DraftRejectionUpload(
        queue: p.queue,
        client: MockClient((_) async => throw const SocketException('offline')),
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        hasConsent: () async => true,
        accountIsCurrent: () => true,
        clock: () => _now,
      ).drain();
      expect(p.reports(), hasLength(1));
      expect(p.queue.due(_now), isEmpty);
    });
    test('no consent: nothing is sent and the report is deleted', () async {
      final r = await run(() => http.Response('{}', 200), consent: false);
      expect(r.calls, isEmpty);
      expect(r.p.reports(), isEmpty);
    });
    test('duplicates of one draft collapse into one report', () {
      final p = _Phone();
      addTearDown(p.dispose);
      for (var i = 0; i < 3; i++) {
        p.queue.enqueue('draft_rejection', _draftA, {'draftId': _draftA, 'reason': 'no_match'});
      }
      expect(p.reports(), hasLength(1));
    });
  });

  test('forgetSharedState is account scoped', () {
    final p = _Phone();
    addTearDown(p.dispose);
    final other = SyncStateStore(p.db.db, namespace: 'user:other');
    other.put('draft:verdict:x', '{}');
    p.state.put('draft:verdict:$_remote', '{}');
    TemplateUpload.forgetSharedState(p.queue);
    expect(other.get('draft:verdict:x'), '{}');
    expect(p.state.get('draft:verdict:$_remote'), isNull);
  });
}
