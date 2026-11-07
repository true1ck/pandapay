import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:sqlite3/sqlite3.dart';

Set<String> _tables(Database db) => db
    .select("SELECT name FROM sqlite_master WHERE type = 'table'")
    .map((r) => r['name'] as String)
    .toSet();

List<String> _columns(Database db, String table) =>
    db.select('PRAGMA table_info($table)').map((r) => r['name'] as String).toList();

void main() {
  late Database db;

  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.dispose());

  test('ensure creates every Contracts -> Storage table with its columns', () {
    SmsV2Schema.ensure(db);

    expect(_tables(db), containsAll(<String>{
      'sms_v2_schema_version',
      'v2_facts',
      'v2_instruments',
      'v2_events',
      'v2_ledger',
      'v2_outbox',
      'v2_rule_bundle',
      'v2_rule_stats',
      'v2_review_items',
      'v2_personal_merchant_alias',
      'v2_bulk_changes',
      'v2_bulk_change_items',
    }));
    expect(_columns(db, 'v2_facts'), [
      'namespace', 'fact_id', 'source_key', 'fact_type', 'observed_at', 'instrument_id', 'payload', 'uploaded_at',
      // Added in version 3 so "similar transactions" is an indexed lookup.
      'merchant_key', 'rule_id', 'keyed',
    ]);
    expect(_columns(db, 'v2_personal_merchant_alias'), [
      'namespace', 'printed_key', 'display_name', 'since', 'updated_at',
    ]);
    expect(_columns(db, 'v2_instruments'), [
      'namespace', 'instrument_id', 'kind', 'issuer_slug', 'mask_digits', 'status', 'payload', 'dirty',
    ]);
    expect(_columns(db, 'v2_events'), ['namespace', 'event_id', 'type', 'status', 'payload', 'dirty']);
    expect(_columns(db, 'v2_ledger'), ['namespace', 'entry_id', 'event_id', 'occurred_at', 'payload', 'dirty']);
    expect(_columns(db, 'v2_outbox'), ['namespace', 'id', 'kind', 'payload', 'attempts', 'next_attempt_at']);
    expect(_columns(db, 'v2_rule_bundle'), [
      'bundle_version', 'json', 'sha256', 'signature', 'expires_at', 'fetched_at',
    ]);
    expect(_columns(db, 'v2_rule_stats'), ['day', 'rule_id', 'rule_version', 'hits', 'to_review', 'corrected']);
    expect(_columns(db, 'v2_review_items'), ['namespace', 'review_id', 'kind', 'payload', 'status']);
    expect(_columns(db, 'sms_v2_schema_version'), ['module', 'version']);
  });

  test('ensure is idempotent: running it twice keeps the data and one version row', () {
    SmsV2Schema.ensure(db);
    db.execute(
      "INSERT INTO v2_events (namespace, event_id, type, status, payload, dirty) VALUES ('acct', 'e1', 'purchase', 'complete', '{}', 1)",
    );
    SmsV2Schema.ensure(db);

    expect(db.select('SELECT * FROM v2_events'), hasLength(1));
    final versions = db.select('SELECT module, version FROM sms_v2_schema_version');
    expect(versions, hasLength(1));
    expect(versions.single['module'], SmsV2Schema.module);
    expect(versions.single['version'], SmsV2Schema.version);
    expect(SmsV2Schema.installedVersion(db), SmsV2Schema.version);
  });

  test('installedVersion is null before ensure and the schema leaves PRAGMA user_version alone', () {
    db.execute('PRAGMA user_version = 41');
    expect(SmsV2Schema.installedVersion(db), isNull);
    SmsV2Schema.ensure(db);
    expect(db.select('PRAGMA user_version').single.values.single, 41);
  });

  test('namespaced primary keys isolate accounts and the instrument identity key is unique', () {
    SmsV2Schema.ensure(db);
    for (final ns in ['a', 'b']) {
      db.execute(
        'INSERT INTO v2_instruments (namespace, instrument_id, kind, issuer_slug, mask_digits, status, payload, dirty) '
        "VALUES ('$ns', 'i1', 'credit_card', 'hdfc', '5678', 'detected', '{}', 0)",
      );
    }
    expect(db.select('SELECT * FROM v2_instruments'), hasLength(2));
    expect(
      () => db.execute(
        'INSERT INTO v2_instruments (namespace, instrument_id, kind, issuer_slug, mask_digits, status, payload, dirty) '
        "VALUES ('a', 'i2', 'credit_card', 'hdfc', '5678', 'detected', '{}', 0)",
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('defaults: dirty, attempts and rule stats counters start at 0', () {
    SmsV2Schema.ensure(db);
    db.execute("INSERT INTO v2_outbox (namespace, id, kind, payload, next_attempt_at) VALUES ('a', 'o1', 'facts', '{}', 0)");
    db.execute("INSERT INTO v2_rule_stats (day, rule_id, rule_version) VALUES ('2026-11-01', 'R1', 1)");
    expect(db.select('SELECT attempts FROM v2_outbox').single['attempts'], 0);
    final s = db.select('SELECT hits, to_review, corrected FROM v2_rule_stats').single;
    expect([s['hits'], s['to_review'], s['corrected']], [0, 0, 0]);
  });
}
