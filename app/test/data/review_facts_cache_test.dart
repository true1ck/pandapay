import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/needs_review_repository.dart';

const ns = 'user:review-facts';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  NeedsReviewItem item(String id, String body) => NeedsReviewItem(
    id: id,
    sender: 'VM-HDFCBK',
    body: body,
    receivedAt: DateTime.now(),
  );

  test('review checks are saved once with the parser version and reused', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    addNeedsReviewSync(db, ns, item('a', 'Rs 499.00 debited from A/c XX1234 to UNKNOWN SHOP'));
    addNeedsReviewSync(db, ns, item('b', 'Thank you for choosing Wellness Forever. View e-bill of Rs 177.98'));
    final repo = NeedsReviewRepository(namespace: ns, loadDatabase: () async => db);

    final first = await repo.fetchAll();
    final saved = db.db.select('SELECT parser_version FROM review_item_facts WHERE namespace=?', [ns]);
    expect(saved, isNotEmpty);
    expect(saved.every((r) => r['parser_version'] == LocalSmsParser.version), isTrue);

    final second = await repo.fetchAll();
    expect(second.map((e) => '${e.id}:${e.kind}'), first.map((e) => '${e.id}:${e.kind}'));
  });

  test('facts from an older parser version are discarded', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    db.db.execute(
      'CREATE TABLE review_item_facts(namespace TEXT NOT NULL, payload_hash TEXT NOT NULL, '
      'parser_version INTEGER NOT NULL, kind TEXT NOT NULL, noise INTEGER NOT NULL, '
      'folio INTEGER NOT NULL, receipt INTEGER NOT NULL, refund INTEGER NOT NULL, '
      'mandate INTEGER NOT NULL, non_txn INTEGER NOT NULL, security INTEGER NOT NULL, '
      'PRIMARY KEY(namespace, payload_hash))',
    );
    db.db.execute(
      "INSERT INTO review_item_facts VALUES (?, 'old', ?, 'transaction', 1,0,0,0,0,0,0)",
      [ns, LocalSmsParser.version - 1],
    );
    addNeedsReviewSync(db, ns, item('a', 'Rs 499.00 debited from A/c XX1234 to UNKNOWN SHOP'));
    await NeedsReviewRepository(namespace: ns, loadDatabase: () async => db).fetchAll();
    final versions = db.db
        .select('SELECT DISTINCT parser_version FROM review_item_facts')
        .map((r) => r['parser_version'])
        .toSet();
    expect(versions, {LocalSmsParser.version});
  });
}
