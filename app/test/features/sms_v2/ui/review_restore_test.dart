import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// "Not financial" saves an ignore rule for the message format. The Dismissed
/// tab lists those messages and "Move back" takes the rule away and reopens
/// the items, without touching the pipeline.
void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late SmsIntakeRepository intake;
  late SmsLearningFeedback feedback;
  const namespace = 'user:restore';

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    SmsV2Schema.ensure(database.db);
    intake = SmsIntakeRepository(database);
    feedback = SmsLearningFeedback(database, namespace: namespace);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  ReviewController controller() => ReviewController(
    financial: financial,
    namespace: namespace,
    bundle: bundle,
  );

  LocalReviewItem unknownFormat(String source, String sender, String body) {
    database.db.execute(
      'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
      [
        namespace,
        source,
        sender,
        body,
        DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
      ],
    );
    final payload = {'sourceKey': source, 'templateHash': 'h-$source'};
    database.db.execute(
      "INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,'open')",
      [namespace, source, 'template', jsonEncode(payload)],
    );
    return LocalReviewItem(
      id: source,
      kind: 'template',
      payload: payload,
      message: intake.capturedById(namespace, source),
    );
  }

  String status(String id) =>
      database.db.select(
            'SELECT status FROM v2_review_items WHERE namespace=? AND review_id=?',
            [namespace, id],
          ).first['status']
          as String;

  List<LocalReviewItem> dismissed() => readDismissedReviewItems(
    db: database.db,
    intake: intake,
    feedback: feedback,
    namespace: namespace,
  );

  test('dismiss, list in Dismissed, move back, and it reads again', () {
    final a = unknownFormat('a' * 64, 'AX-ZETABK-S', 'ZetaBank: Rs.5 debited');
    expect(dismissed(), isEmpty);

    controller().apply(items: [a], kind: CorrectionKind.notFinancial);

    expect(status(a.id), 'resolved');
    expect(
      feedback.matchesFalseTransactionRuleSync(
        sender: a.message!.message.sender,
        body: a.message!.message.body,
      ),
      isTrue,
    );
    expect(dismissed().map((i) => i.id), [a.id]);

    final reopened = controller().restoreDismissed(dismissed());

    expect(reopened, 1);
    expect(status(a.id), 'open');
    expect(
      feedback.matchesFalseTransactionRuleSync(
        sender: a.message!.message.sender,
        body: a.message!.message.body,
      ),
      isFalse,
    );
    expect(dismissed(), isEmpty);
  });

  test('moving one format back leaves another format dismissed', () {
    final a = unknownFormat('a' * 64, 'AX-ZETABK-S', 'ZetaBank: Rs.5 debited');
    final b = unknownFormat('b' * 64, 'AX-OTHER-S', 'Other: card was blocked');
    controller().apply(items: [a, b], kind: CorrectionKind.notFinancial);
    expect(dismissed(), hasLength(2));

    controller().restoreDismissed([a]);

    expect(status(a.id), 'open');
    expect(status(b.id), 'resolved');
    expect(dismissed().map((i) => i.id), [b.id]);
  });

  test('undo right after a bulk dismiss restores every message', () {
    final items = [
      unknownFormat('a' * 64, 'AX-A-S', 'A: Rs.1 failed'),
      unknownFormat('b' * 64, 'AX-B-S', 'B: Rs.2 failed'),
      unknownFormat('c' * 64, 'AX-C-S', 'C: Rs.3 failed'),
    ];
    controller().apply(items: items, kind: CorrectionKind.notFinancial);
    expect(items.every((i) => status(i.id) == 'resolved'), isTrue);

    expect(controller().restoreDismissed(items), 3);

    expect(items.every((i) => status(i.id) == 'open'), isTrue);
    expect(dismissed(), isEmpty);
  });

  test('other dismissed messages sharing the freed rule are reopened too', () {
    // Same format (digits are masked in the ignore rule) but different
    // pipeline template hashes, so they are separate bundles on screen.
    final a = unknownFormat('a' * 64, 'AX-ZETABK-S', 'ZetaBank: Rs.5 failed');
    final b = unknownFormat('b' * 64, 'AX-ZETABK-S', 'ZetaBank: Rs.9 failed');
    controller().apply(items: [a, b], kind: CorrectionKind.notFinancial);
    expect(dismissed(), hasLength(2));

    // The user moves back only the first bundle.
    controller().restoreDismissed([a]);

    expect(status(a.id), 'open');
    expect(status(b.id), 'open', reason: 'must not be left resolved, ruleless');
    expect(dismissed(), isEmpty);
  });

  test('restoring twice is harmless', () {
    final a = unknownFormat('a' * 64, 'AX-A-S', 'A: Rs.1 failed');
    controller().apply(items: [a], kind: CorrectionKind.notFinancial);
    expect(controller().restoreDismissed([a]), 1);
    expect(controller().restoreDismissed([a]), 0);
    expect(status(a.id), 'open');
  });

  test('a message that was read into facts is not restored here', () {
    final source = '1' * 64;
    final message = SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: bundle.rules.first.examples.first.body,
      sourceKey: source,
      observedAt: DateTime.utc(2026, 11, 1, 7),
    );
    database.db.execute(
      'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
      [
        namespace,
        source,
        message.sender,
        message.body,
        message.observedAt.millisecondsSinceEpoch,
      ],
    );
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
    ).process(message);
    final payload = {'sourceKey': source, 'templateHash': 'same'};
    database.db.execute(
      "INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,'open')",
      [namespace, source, 'template', jsonEncode(payload)],
    );
    final item = LocalReviewItem(
      id: source,
      kind: 'template',
      payload: payload,
      message: intake.capturedById(namespace, source),
    );
    controller().apply(items: [item], kind: CorrectionKind.notFinancial);

    expect(controller().restoreDismissed([item]), 0);
    expect(status(source), 'resolved');
  });

  test('items other than unknown formats are never reopened', () {
    final a = unknownFormat('a' * 64, 'AX-A-S', 'A: Rs.1 failed');
    controller().apply(items: [a], kind: CorrectionKind.notFinancial);
    final asLink = LocalReviewItem(
      id: a.id,
      kind: 'link',
      payload: a.payload,
      message: a.message,
    );
    expect(controller().restoreDismissed([asLink]), 0);
    expect(status(a.id), 'resolved');
  });

  test('a resolved item with no ignore rule is not listed as dismissed', () {
    final a = unknownFormat('a' * 64, 'AX-A-S', 'A: Rs.1 failed');
    database.db.execute(
      "UPDATE v2_review_items SET status='resolved' WHERE namespace=? AND review_id=?",
      [namespace, a.id],
    );
    expect(dismissed(), isEmpty);
  });
}
