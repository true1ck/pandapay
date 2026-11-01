import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/needs_review_repository.dart';

void main() {
  late AppDatabase db;
  const ns = 'user:telecom-reminders';
  setUp(() => db = openInMemoryForTesting());
  tearDown(() => db.close());

  // Synthetic fixtures only: no real contact details, due amounts, or links.
  NeedsReviewItem jio(String id, DateTime at, String due, String code) =>
      NeedsReviewItem(
        id: id,
        sender: 'JIOFIB-S',
        receivedAt: at,
        body:
            'Your bill dated 15-06-2026 for JioHome connection with JioFixedVoice '
            'Number [redacted] is due for payment on $due.\n'
            'Total amount payable : Rs.100.00.\n'
            'To pay your bill, click www.jio.com/r/$code\n'
            'Overdue charges will be applicable, in case of delay in payment. '
            'Kindly ignore, if already paid.',
      );

  int count(String table) {
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS $table(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    return db.db
            .select('SELECT COUNT(*) AS c FROM $table WHERE namespace=?', [ns])
            .first['c']
        as int;
  }

  test('repeated Jio reminders never reach review or transactions', () {
    final future = DateTime.now().add(const Duration(days: 20));
    String d(DateTime t) =>
        '${t.day.toString().padLeft(2, '0')}-${t.month.toString().padLeft(2, '0')}-${t.year}';
    addNeedsReviewSync(db, ns, jio('a', DateTime.now(), d(future), 'TESTCODE1'));
    addNeedsReviewSync(
      db,
      ns,
      jio('b', DateTime.now(), d(future.add(const Duration(days: 30))), 'TESTCODE2'),
    );
    // Past-due reminders (history import) are archived, not queued.
    addNeedsReviewSync(
      db,
      ns,
      jio('c', DateTime(2026, 7, 3), '02-07-2026', 'TESTCODE3'),
    );
    expect(count('local_needs_review'), 0);
    expect(count('local_commitments'), 1, reason: 'one series per biller');
  });
}
