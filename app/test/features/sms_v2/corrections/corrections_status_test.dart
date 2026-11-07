import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/corrections/corrections_status.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
  });
  tearDown(() => db.dispose());

  void review(String id, String status, Map<String, Object?> payload) =>
      db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'user:a', 'correction:$id', 'correction', jsonEncode(payload), status,
      ]);

  CorrectionStatusRow only(String id) => correctionStatuses(db, 'user:a')
      .firstWhere((row) => row.id == 'correction:$id');

  test('every place a correction can be is said in plain words', () {
    final queue = OutboxStore(db, namespace: 'user:a');
    review('queued', 'pending', {'kind': 'wrong_category'});
    queue.enqueue('correction', 'queued', {'sourceKey': 'S'});
    review('sent', 'open', {'kind': 'wrong_merchant', 'caseId': 'c1'});
    review('fixed', 'decided', {
      'kind': 'wrong_category',
      'caseId': 'c2',
      'serverStatus': {'decision': 'data_fix', 'reason': 'Added a rule for the shop'},
    });
    review('code', 'decided', {
      'kind': 'wrong_amount',
      'serverStatus': {'decision': 'code_fix'},
    });
    review('nochange', 'decided', {
      'kind': 'not_financial',
      'serverStatus': {'decision': 'not_a_bug', 'reason': 'Working as designed'},
    });
    review('kept', 'resolved', {'kind': 'wrong_kind', 'notSent': 'correction_facts_not_found'});
    review('local', 'resolved', {'kind': 'wrong_instrument'});

    expect(only('queued').state, CorrectionState.queued);
    expect(correctionStateWords(only('queued')), 'Waiting to send');
    expect(only('sent').state, CorrectionState.sent);
    expect(only('fixed').state, CorrectionState.fixedByRules);
    expect(only('fixed').detail, 'Added a rule for the shop');
    expect(correctionStateWords(only('fixed')), 'Reviewed. The shared rules were fixed');
    expect(only('code').state, CorrectionState.codeFixPlanned);
    expect(only('nochange').state, CorrectionState.noChangeNeeded);
    expect(only('kept').state, CorrectionState.keptOnPhone);
    expect(
      correctionStateWords(only('kept')),
      'Kept on this phone: the server could not match it to your messages',
    );
    expect(only('local').state, CorrectionState.localOnly);
    expect(correctionKindWords('wrong_merchant'), 'Shop name');
    expect(correctionKindWords('something_new'), 'Correction');
  });

  test('another account\'s corrections never show', () {
    review('mine', 'open', {'kind': 'wrong_category'});
    db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
      'user:b', 'correction:theirs', 'correction', jsonEncode({'kind': 'wrong_category'}), 'open',
    ]);
    expect(correctionStatuses(db, 'user:a').map((row) => row.id), ['correction:mine']);
  });

  test('a correction the sync parked is reported as kept on the phone with its reason', () async {
    // The real parking path, not a hand-made row.
    final queue = OutboxStore(db, namespace: 'user:a');
    queue.enqueue('correction', 'c9', {'sourceKey': 'S', 'factIds': <String>[]});
    review('c9', 'pending', {'kind': 'wrong_kind'});
    final record = queue.due(DateTime.now()).single;
    queue.acknowledge(record);
    db.execute(
      "UPDATE v2_review_items SET status='resolved',payload=json_set(payload,'\$.notSent',?) WHERE review_id=?",
      ['correction_stage_mismatch', record.id],
    );
    expect(only('c9').state, CorrectionState.keptOnPhone);
    expect(correctionStateWords(only('c9')), contains('cannot be shared'));
  });
}
