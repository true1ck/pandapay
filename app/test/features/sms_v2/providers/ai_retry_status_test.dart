// Which Needs review formats get "Try again", and which say "Trying again", from the phone's own state.
// Invented data only.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/consents_api.dart' show ConsentRecord;
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/template_retry.dart';

import '../support/ledger_dataset.dart';

void main() {
  late Dataset d;
  late ProviderContainer container;
  var consent = true;
  final local = 'a' * 64;
  final remote = 'b' * 64;

  setUp(() {
    consent = true;
    d = Dataset(3)..open();
    d.seed();
    SmsIntakeRepository(d.database);
    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(ns),
        responseCacheProvider.overrideWith((ref) async => d.cache),
        smsV2RuntimeProvider.overrideWith((ref) async => null),
        smsSharedLearningConsentProvider.overrideWith(
          (ref) async => consent
              ? ConsentRecord(
                  purpose: 'sms_shared_learning',
                  granted: true,
                  grantedAt: DateTime(2026, 11, 1),
                )
              : null,
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    d.close();
  });

  SyncStateStore state() => SyncStateStore(d.database.db, namespace: ns);

  void unreadQuestion({String source = 'm1', Map<String, Object?> extra = const {}}) =>
      d.database.db.execute(
        'INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,?)',
        [ns, '$source:0', 'template', jsonEncode({'sourceKey': source, 'templateHash': local, ...extra}), 'open'],
      );

  void sentAs(String status) {
    state().put(
      'template:origins:$remote',
      jsonEncode({'senderBrand': 'SYNTHBK', 'localHashes': [local]}),
    );
    state().put('template:sent:$remote', DateTime.now().toUtc().toIso8601String());
    if (status != 'none') {
      state().put('ai:$remote', jsonEncode({'status': status, 'templateHash': remote}));
    }
  }

  Future<AiReviewStatus> status() async {
    container.invalidate(aiReviewStatusProvider);
    return container.read(aiReviewStatusProvider.future);
  }

  test('a format the AI failed on or was turned down for can be retried', () async {
    unreadQuestion();
    sentAs('failed');
    final s = await status();
    expect(s.retryable, {local});
    expect(s.canRetry((await container.read(reviewItemsProvider.future)).first), isTrue);
    sentAs('rejected');
    expect((await status()).retryable, {local});
  });

  test('not while the AI is still working on it, not when it was never sent, not without sharing', () async {
    unreadQuestion();
    sentAs('pending');
    expect((await status()).retryable, isEmpty, reason: 'a layout in progress');
    expect((await status()).checkingTemplates, {local});
    d.database.db.execute("DELETE FROM v2_sync_state WHERE key LIKE 'template:%' OR key LIKE 'ai:%'");
    expect((await status()).retryable, isEmpty, reason: 'never sent: nothing to retry');
    sentAs('failed');
    consent = false;
    container.invalidate(smsSharedLearningConsentProvider);
    expect((await status()).retryable, isEmpty, reason: 'nothing is sent without sharing');
  });

  test('a working (ready) answer, or one still pending, is never reset: no Try again', () async {
    unreadQuestion();
    sentAs('ready');
    expect((await status()).retryable, isEmpty, reason: 'a ready answer is a working private rule');
    sentAs('pending');
    expect((await status()).retryable, isEmpty, reason: 'pending: the AI is still working');
    expect((await status()).checkingTemplates, {local});
  });

  test('a ready answer this phone itself turned down is as good as none: Try again is offered', () async {
    unreadQuestion();
    sentAs('none');
    const draft = '11111111-1111-4111-8111-111111111111';
    state().put(
      'ai:$remote',
      jsonEncode({'status': 'ready', 'templateHash': remote, 'draftId': draft, 'rule': {'id': 'AI-x'}}),
    );
    expect((await status()).retryable, isEmpty, reason: 'draft not judged: a working rule');
    state().put('draft:verdict:$remote', jsonEncode({'draftId': draft, 'verdict': 'rejected'}));
    expect((await status()).retryable, {local});
  });

  test('not for a question that waits for history or is a receipt question', () async {
    unreadQuestion(extra: {'aiHold': 'history'});
    sentAs('failed');
    expect((await status()).retryable, isEmpty);
  });

  test('after the press the format says Trying again, until a new answer arrives', () async {
    unreadQuestion();
    sentAs('failed');
    expect((await status()).retryable, {local});
    TemplateRetry(d.database.db, namespace: ns).reset(local);
    var s = await status();
    expect(s.retrying, {local});
    expect(s.retryable, isEmpty, reason: 'no second press while it is trying, nor for five minutes');
    expect(s.checkingTemplates, isEmpty, reason: 'one state, not two');
    // The server answers (failed again): the card is back to its state, and the five-minute gap still holds.
    state().put('ai:$remote', jsonEncode({'status': 'failed', 'templateHash': remote}));
    s = await status();
    expect(s.retrying, isEmpty);
    expect(s.retryable, isEmpty, reason: 'within five minutes of the last press');
  });
}
