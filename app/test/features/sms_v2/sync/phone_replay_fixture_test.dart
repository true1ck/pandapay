// What the phone really sends after an edit, recorded from the app's own code
// (pipeline, corrections service, upload queue) and kept in
// contracts/sms/v2/fixtures/phone_replay/requests.json.
//
// The API test api/test/sms_v2/phone_replay_pg.test.js sends exactly these
// requests to the real server routes and expects every one to be accepted. If
// the app changes what it sends, this test fails until the recording is
// refreshed: UPDATE_PHONE_REPLAY=1 flutter test <this file>.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/category/category_snapshot.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/sync/corrections_sync.dart';
import 'package:pandapay/features/sms_v2/sync/facts_upload.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _dir = '../contracts/sms/v2/fixtures/phone_replay';

/// (name, rule id, example number, body override, edits)
final _scenarios =
    <(String, String, int, String?, List<(CorrectionKind, Map<String, Object?>)>)>[
      (
        'wallet_promo_not_financial',
        'WAL-PAYTM-LOAD-01',
        1,
        null,
        [(CorrectionKind.notFinancial, {})],
      ),
      (
        'demat_credit_not_financial',
        'BRK-DEMAT-CREDIT-01',
        0,
        null,
        [(CorrectionKind.notFinancial, {})],
      ),
      (
        'fund_trade_value_missing',
        'INV-FUNDBAL-GROWW-01',
        1,
        null,
        [(CorrectionKind.missing, {})],
      ),
      (
        'statement_sent_to_hidden_email_not_financial',
        'SUB-CC-STMT-SENT-01',
        0,
        'Example Bank Credit Card XX1234 Statement is sent to ab***@gmail.com. Total of Rs 5,000.00 or minimum of Rs 250.00 is due by 30-JUN-26.',
        [(CorrectionKind.notFinancial, {})],
      ),
      (
        'card_spend_shop_and_category_changed',
        'HDFC-CARD-SPEND-SPENTFIRST-CC',
        0,
        null,
        [
          (CorrectionKind.wrongMerchant, {'merchantName': 'Corner Shop'}),
          (CorrectionKind.wrongCategory, {'category': 'groceries'}),
        ],
      ),
    ];

/// The shape of a recording: values that differ on every run are replaced by placeholders.
Object? _stable(Object? value) {
  if (value is Map) {
    final template = value.containsKey('senderBrand') && value.containsKey('hash');
    return {
      for (final entry in value.entries)
        entry.key: template && entry.key == 'observedAt'
            ? '<shifted>'
            : _stable(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _stable(item)];
  // Ids that are drawn fresh on every run (cards, corrections) or derived from them.
  if (value is String) {
    return value
        .replaceAll(
          RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'),
          '<uuid>',
        )
        .replaceAll(RegExp(r'\b[0-9a-f]{64}\b'), '<hash>');
  }
  return value;
}

Map<String, Object?> _acceptAll(Map body) => {
  'results': [
    for (final item in (body['instruments'] as List? ?? const []))
      {'id': item['instrumentId'], 'kind': 'instrument', 'status': 'accepted'},
    for (final item in (body['items'] as List? ?? const []))
      for (final fact in item['facts'] as List)
        {'id': fact['factId'], 'kind': 'fact', 'status': 'accepted'},
    for (final item in (body['events'] as List? ?? const []))
      {'id': item['eventId'], 'kind': 'event', 'status': 'accepted'},
    for (final item in (body['ledger'] as List? ?? const []))
      {'id': item['entryId'], 'kind': 'ledger', 'status': 'accepted'},
  ],
  'serverTime': '2026-11-10T00:00:00.000Z',
};

void main() {
  final bundle = RuleBundle.fromJson(
    (jsonDecode(File('$_dir/bundle.json').readAsStringSync()) as Map)
        .cast<String, Object?>(),
  );

  Future<Map<String, Object?>> record(
    (String, String, int, String?, List<(CorrectionKind, Map<String, Object?>)>)
    scenario,
  ) async {
    final rule = bundle.rules.firstWhere((r) => r.id == scenario.$2);
    final example = rule.examples[scenario.$3];
    final body = scenario.$4 ?? example.body;
    final database = AppDatabase.forTesting(sqlite3.openInMemory());
    final financial = FinancialStore(database);
    const namespace = 'user:replay';
    final intake = SmsIntakeRepository(database);
    SmsV2Schema.ensure(database.db);
    final outbox = OutboxStore(database.db, namespace: namespace);
    final requests = <Map<String, Object?>>[];
    final client = MockClient((request) async {
      final raw = request.url.path.endsWith('facts:batch')
          ? gzip.decode(request.bodyBytes)
          : request.bodyBytes;
      final parsed = jsonDecode(utf8.decode(raw)) as Map;
      requests.add({
        'method': request.method,
        'path': request.url.path,
        'body': parsed,
      });
      return http.Response(
        jsonEncode(
          request.url.path.endsWith('facts:batch')
              ? _acceptAll(parsed)
              : {'caseId': '00000000-0000-4000-8000-000000000000'},
        ),
        200,
      );
    });
    final upload = FactsUpload(
      queue: outbox,
      client: client,
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'replay-device',
      appVersion: '2',
      headers: () async => {},
    );
    final corrections = CorrectionsSync(
      queue: outbox,
      client: client,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      accountIsCurrent: () => true,
    );
    final categories = CategorySnapshot.load(
      financial.database,
      namespace: namespace,
      aliases: bundle.merchantAliases,
    );
    final source = sha256.convert(utf8.encode(scenario.$1)).toString();
    final message = SmsMessage(
      sender: example.sender,
      body: body,
      sourceKey: source,
      observedAt: DateTime.utc(2026, 11, 10, 7),
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
      userRules: categories.userRules,
      confirmedHistory: categories.confirmedHistory,
    ).process(message);
    // The phone has uploaded the SMS by the time the person edits it.
    await upload.drain();
    final controller = ReviewController(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      hasConsent: true,
    );
    final item = LocalReviewItem(
      id: source,
      kind: 'template',
      payload: {'sourceKey': source},
      message: intake.capturedById(namespace, source),
    );
    for (final edit in scenario.$5) {
      controller.apply(items: [item], kind: edit.$1, corrected: {...edit.$2});
    }
    await upload.drain();
    await corrections.drain();
    // Shop signals and template uploads have their own routes; only the facts and corrections are recorded here.
    final left = [
      for (final r in outbox.due(DateTime.now().add(const Duration(days: 1))))
        if (!const {'signal', 'template'}.contains(r.kind)) '${r.kind}',
    ];
    expect(left, isEmpty, reason: '${scenario.$1}: everything else queued was sent');
    financial.dispose();
    database.db.dispose();
    return {'name': scenario.$1, 'requests': requests};
  }

  test('the phone sends what the recording says it sends', () async {
    final recorded = [for (final s in _scenarios) await record(s)];
    for (final scenario in recorded) {
      final paths = [
        for (final r in scenario['requests'] as List) (r as Map)['path'],
      ];
      expect(paths, contains('/sms/v2/corrections'), reason: '${scenario['name']}');
    }
    final file = File('$_dir/requests.json');
    final fresh = const JsonEncoder.withIndent(' ').convert({
      'about':
          'Recorded by app/test/features/sms_v2/sync/phone_replay_fixture_test.dart. Refresh with UPDATE_PHONE_REPLAY=1.',
      'scenarios': recorded,
    });
    if (Platform.environment['UPDATE_PHONE_REPLAY'] == '1') {
      file.writeAsStringSync('$fresh\n');
      return;
    }
    final committed = jsonDecode(file.readAsStringSync()) as Map;
    expect(
      _stable(jsonDecode(fresh)),
      _stable(committed),
      reason:
          'The phone now sends something different. Run UPDATE_PHONE_REPLAY=1 flutter test test/features/sms_v2/sync/phone_replay_fixture_test.dart and run the API replay test.',
    );
  });
}
