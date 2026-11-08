import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import 'synthetic_corpus.dart';

const harnessNamespace = 'user:shared';

/// One phone: its own SQLite database, as an Android or an iPhone would hold.
class Device {
  Device(this.name)
    : database = AppDatabase.forTesting(sqlite3.openInMemory()) {
    financial = FinancialStore(database);
  }
  final String name;
  final AppDatabase database;
  late final FinancialStore financial;
  Database get db => database.db;
  void dispose() {
    financial.dispose();
    database.db.dispose();
  }

  EventStore get events => EventStore(db, namespace: harnessNamespace);
  LedgerStore get ledger => LedgerStore(db, namespace: harnessNamespace);
  FactStore get facts => FactStore(db, namespace: harnessNamespace);
  InstrumentStore get instruments =>
      InstrumentStore(db, namespace: harnessNamespace);
  OutboxStore get outbox => OutboxStore(db, namespace: harnessNamespace);

  /// Phone-side capture of [messages] through the real pipeline.
  void capture(
    RuleBundle bundle,
    Iterable<({String sender, String body, DateTime at})> messages, {
    String? sourcePrefix,
  }) {
    final pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: harnessNamespace,
      bundle: bundle,
      appVersion: '2',
    );
    var index = 0;
    final list = [
      for (final m in messages)
        SmsMessage(
          sender: m.sender,
          body: m.body,
          iosFilter: normalizeSenderBrand(m.sender).iosFilter,
          observedAt: m.at,
          sourceKey: smsSourceKey(
            harnessNamespace,
            m.sender,
            '${sourcePrefix ?? ''}${index++}|${m.body}',
          ),
        ),
    ];
    for (var start = 0; start < list.length; start += 200) {
      pipeline.processBatch(list.sublist(start, (start + 200).clamp(0, list.length)));
    }
  }

  /// Receives [pages] from the server in the given order, honouring cursors.
  Future<void> receive(RuleBundle bundle, List<Map<String, Object?>> pages) async {
    var served = 0;
    final client = MockClient((request) async {
      final body = {...pages[served], 'cursor': '$name-${served + 1}'};
      final more = served + 1 < pages.length;
      served++;
      return http.Response(
        jsonEncode(body),
        200,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          if (more) 'x-sms-sync-has-more': '1',
        },
      );
    });
    await SyncPull(
      financial: financial,
      namespace: harnessNamespace,
      client: client,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      bundle: bundle,
    ).pull();
    if (served != pages.length) {
      throw StateError('$name received $served of ${pages.length} pages');
    }
  }
}

/// A synthetic server log of a device's uploads, cut into sync pages.
class ServerLog {
  ServerLog({DateTime? start}) : _clock = start ?? DateTime.utc(2026, 11, 1);
  DateTime _clock;
  final _records = <({String kind, String id, Map<String, Object?> json, String at})>[];

  /// Every queued upload of [device] becomes one log record with a new clock.
  void ingest(Device device) {
    for (final row in device.outbox.due(DateTime.utc(2100), limit: 1 << 20)) {
      if (!{'source', 'instrument', 'event', 'ledger'}.contains(row.kind)) {
        continue;
      }
      _clock = _clock.add(const Duration(seconds: 1));
      _records.add((
        kind: row.kind,
        id: row.id,
        json: row.json,
        at: _clock.toIso8601String(),
      ));
    }
  }

  /// Pages of [size] records starting at record [from].
  List<Map<String, Object?>> pages({int size = 25, int from = 0}) {
    final out = <Map<String, Object?>>[];
    for (var start = from; start < _records.length; start += size) {
      final chunk = _records.sublist(start, min(start + size, _records.length));
      List<Map<String, Object?>> of(String kind) => [
        for (final r in chunk)
          if (r.kind == kind) r.json,
      ];
      Map<String, String> clocks(String kind, String key) => {
        for (final r in chunk)
          if (r.kind == kind) r.json[key] as String: r.at,
      };
      out.add({
        'cursor': 'server-$start',
        'facts': [for (final s in of('source')) ...s['facts'] as List],
        'instruments': of('instrument'),
        'events': of('event'),
        'ledger': of('ledger'),
        'aiResults': <Object?>[],
        'corrections': <Object?>[],
        'latestBundleVersion': 1,
        'updatedAt': {
          'events': clocks('event', 'eventId'),
          'instruments': clocks('instrument', 'instrumentId'),
          'ledger': clocks('ledger', 'entryId'),
        },
      });
    }
    return out;
  }

  int get length => _records.length;
}

/// Reorders [pages] and repeats some, as a flaky network would.
List<Map<String, Object?>> shuffledWithDuplicates(
  List<Map<String, Object?>> pages,
  int seed,
) {
  final random = Random(seed);
  final delivered = [
    ...pages,
    for (final page in pages)
      if (random.nextDouble() < .5) page,
  ]..shuffle(random);
  return delivered;
}

/// Everything a user can see or total, in a canonical order.
Map<String, Object?> digest(Device device) {
  final events = device.events.listSince(DateTime.utc(1900))
    ..sort((a, b) => a.eventId.compareTo(b.eventId));
  final entries = device.ledger.list()
    ..sort((a, b) => a.entryId.compareTo(b.entryId));
  final decisions = device.ledger.categoryDecisions();
  final snapshot = LedgerSnapshot(
    entries: entries,
    events: events,
    categoryByEvent: decisions,
  );
  final totals = snapshot.totals(DateTime.utc(2000), DateTime.utc(2100));
  final display = device.financial.entities(harnessNamespace, 'transactions')
    ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  final instruments = device.instruments.list()
    ..sort((a, b) => a.instrumentId.compareTo(b.instrumentId));
  final cards = instruments.where(
    (i) =>
        i.kind == InstrumentKind.creditCard &&
        i.status == InstrumentStatus.confirmed,
  );
  final unresolvedBills = {
    for (final entry in entries)
      if (entry.to is OwnUnresolvedEndpoint &&
          (entry.to as OwnUnresolvedEndpoint).kind == InstrumentKind.creditCard)
        entry.eventId,
  };
  return {
    'events': [for (final e in events) e.toJson()],
    'ledger': [for (final e in entries) e.toJson()],
    'categories': {
      for (final e in decisions.entries)
        e.key: '${e.value.slug}|${e.value.source.wire}',
    },
    'display': display,
    'facts': [
      for (final f in device.facts.since(DateTime.utc(1900))..sort((a, b) => a.factId.compareTo(b.factId)))
        f.factId,
    ],
    'instruments': [for (final i in instruments) i.toJson()],
    'totals': {
      'spend': totals.spendMinor,
      'refund': totals.refundMinor,
      'income': totals.incomeMinor,
      'investment': totals.investmentMinor,
      'count': totals.transactionCount,
      'byCategory': {...totals.byCategory},
    },
    // Review prompts derived from synced state. The persisted v2_review_items
    // rows are per-device by design (they hold local message keys).
    'review': {
      'lowConfidenceEvents': [
        for (final e in events)
          if (e.confidence < .7) e.eventId,
      ],
      'detectedInstruments': [
        for (final i in instruments)
          if (i.status == InstrumentStatus.detected) i.instrumentId,
      ],
      'unresolvedBillTargets': cards.length > 1
          ? [
              for (final e in events)
                if (e.type == EventType.cardBillPayment &&
                    unresolvedBills.contains(e.eventId))
                  e.eventId,
            ]
          : <String>[],
    },
  };
}

/// The 15 golden scenarios plus a varied synthetic history: purchases,
/// refunds, card bills, mandates, transfers, income and noise.
List<({String sender, String body, DateTime at})> sharedHistory(
  RuleBundle bundle, {
  int synthetic = 250,
  int seed = 21,
}) {
  final out = <({String sender, String body, DateTime at})>[];
  for (final file
      in Directory('../tools/sms_golden/scenarios').listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    for (final m
        in (jsonDecode(file.readAsStringSync()) as Map)['messages'] as List) {
      out.add((
        sender: m['sender'] as String,
        body: m['body'] as String,
        at: DateTime.parse(m['observedAt'] as String),
      ));
    }
  }
  for (final m in SyntheticCorpus.generate(bundle, count: synthetic, seed: seed, spanDays: 300).messages) {
    out.add((sender: m.sender, body: m.body, at: m.receivedAt.toUtc()));
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}
