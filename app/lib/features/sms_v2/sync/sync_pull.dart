import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

import '../../../data/local/financial_store.dart';
import '../ledger/projection_writer.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import 'corrections_sync.dart';

/// Pull changes and the next cursor commit in the same local transaction.
class SyncPull {
  SyncPull({
    required this.financial,
    required this.namespace,
    required this.client,
    required this.baseUri,
    required this.headers,
    required this.bundle,
    this.categoryIdBySlug = const {},
    this.accountIsCurrent = _alwaysCurrent,
  }) {
    SmsV2Schema.ensure(financial.database.db);
  }

  static bool _alwaysCurrent() => true;
  final bool Function() accountIsCurrent;
  final RuleBundle bundle;
  final FinancialStore financial;
  final String namespace;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final Map<String, String> categoryIdBySlug;
  late final _db = financial.database.db;
  late final _state = SyncStateStore(_db, namespace: namespace);
  late final _facts = FactStore(_db, namespace: namespace);
  late final _instruments = InstrumentStore(_db, namespace: namespace);
  late final _events = EventStore(_db, namespace: namespace);
  late final _ledger = LedgerStore(_db, namespace: namespace);
  Future<int>? _running;

  Future<int> pull() {
    final running = _running;
    if (running != null) return running;
    late final Future<int> operation;
    operation = _pull().whenComplete(() {
      if (identical(_running, operation)) _running = null;
    });
    return _running = operation;
  }

  Future<int> _pull() async {
    var pages = 0;
    while (pages < 100 && accountIsCurrent()) {
      final cursor = _state.get('pull:cursor');
      final response = await client
          .get(
            baseUri
                .resolve('/sms/v2/sync')
                .replace(
                  queryParameters: cursor == null ? null : {'cursor': cursor},
                ),
            headers: {
              ...await headers(),
              // CCR-003: this build reads a category on refund ledger entries.
              'X-Sms-Contract-Features': 'refund-category',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (!accountIsCurrent() || response.statusCode != 200) return pages;
      final decoded = jsonDecode(response.body);
      final check = validateSyncResponseJson(decoded);
      if (!check.ok) throw ContractException(check.errors);
      final body = (decoded as Map).cast<String, Object?>();
      final next = body['cursor'] as String;
      final more = response.headers['x-sms-sync-has-more'] == '1';
      if (more && next == cursor) {
        throw const FormatException('Sync cursor did not advance');
      }
      _apply(body);
      pages++;
      if (!more) return pages;
    }
    return pages;
  }

  bool _dirty(String table, String column, String id) => _db.select(
    'SELECT 1 FROM $table WHERE namespace=? AND $column=? AND dirty=1',
    [namespace, id],
  ).isNotEmpty;

  void _apply(Map<String, Object?> body) {
    final clocks = (body['updatedAt'] as Map?) ?? const {};
    DateTime? remoteClock(String kind, String id) {
      final value = (clocks[kind] as Map?)?[id];
      return value is String ? DateTime.parse(value) : null;
    }

    bool newer(String kind, String id) {
      final previous = _state.clock(kind, id);
      final incoming = remoteClock(kind, id);
      return previous == null || incoming != null && incoming.isAfter(previous);
    }

    void record(String kind, String id) {
      final clock = remoteClock(kind, id);
      if (clock != null) _state.recordClock(kind, id, clock);
    }

    financial.batch(() {
      _db.execute('SAVEPOINT sms_v2_pull');
      try {
        for (final json in body['facts'] as List? ?? []) {
          final fact = Fact.fromJson((json as Map).cast<String, Object?>());
          _facts.insert(fact);
          _facts.markUploaded(fact.factId, DateTime.now());
        }
        for (final json in body['instruments'] as List) {
          final incoming = Instrument.fromJson(
            (json as Map).cast<String, Object?>(),
          );
          final conflict = _instruments.findByKey(
            incoming.kind,
            incoming.issuerSlug,
            incoming.maskDigits,
          );
          if (conflict != null &&
              conflict.instrumentId != incoming.instrumentId) {
            _adopt(conflict, incoming.instrumentId);
          }
          if ((incoming.status == InstrumentStatus.rejected ||
                  !_dirty(
                    'v2_instruments',
                    'instrument_id',
                    incoming.instrumentId,
                  )) &&
              newer('instruments', incoming.instrumentId)) {
            _instruments.upsert(incoming, dirty: false);
            if (incoming.status == InstrumentStatus.rejected) {
              _db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
                namespace,
                'instrument:${incoming.instrumentId}',
              ]);
            }
            record('instruments', incoming.instrumentId);
          }
        }
        final protectedEvents = <String>{};
        for (final json in body['events'] as List) {
          final incoming = Event.fromJson(
            (json as Map).cast<String, Object?>(),
          );
          if (incoming.status == EventStatus.userConfirmed &&
                  newer('events', incoming.eventId) ||
              !_dirty('v2_events', 'event_id', incoming.eventId) &&
                  newer('events', incoming.eventId)) {
            _events.upsert(
              incoming,
              dirty: false,
              fromUser: incoming.status == EventStatus.userConfirmed,
            );
            record('events', incoming.eventId);
            if (incoming.status == EventStatus.userConfirmed) {
              _db.execute("DELETE FROM v2_outbox WHERE namespace=? AND id=?", [
                namespace,
                'event:${incoming.eventId}',
              ]);
              _db.execute(
                "UPDATE v2_ledger SET dirty=0 WHERE namespace=? AND event_id=?",
                [namespace, incoming.eventId],
              );
              for (final entry in _ledger.forEvent(incoming.eventId)) {
                _db.execute(
                  'DELETE FROM v2_outbox WHERE namespace=? AND id=?',
                  [namespace, 'ledger:${entry.entryId}'],
                );
              }
            }
          } else {
            protectedEvents.add(incoming.eventId);
          }
        }
        for (final json in body['ledger'] as List) {
          final incoming = LedgerEntry.fromJson(
            (json as Map).cast<String, Object?>(),
          );
          if (protectedEvents.contains(incoming.eventId) ||
              _dirty('v2_events', 'event_id', incoming.eventId) ||
              _dirty('v2_ledger', 'entry_id', incoming.entryId) ||
              !newer('ledger', incoming.entryId)) {
            continue;
          }
          final retained = _ledger
              .forEvent(incoming.eventId)
              .where((entry) => entry.entryId != incoming.entryId);
          _ledger.replaceForEvent(
            incoming.eventId,
            [...retained, incoming],
            dirty: false,
            // A refund entry carries its own category on the wire (CCR-003);
            // a retained local decision must not overwrite it.
            category: incoming.isRefundShaped
                ? null
                // Only this event's rows: decoding the whole ledger for every
                // incoming entry was quadratic on the UI thread.
                : _ledger.categoryDecisions(eventIds: {
                    incoming.eventId,
                  })[incoming.eventId],
          );
          record('ledger', incoming.entryId);
        }
        for (final result in body['aiResults'] as List) {
          _state.put('ai:${result['templateHash']}', jsonEncode(result));
        }
        for (final result in body['corrections'] as List) {
          _state.put('correction:${result['caseId']}', jsonEncode(result));
        }
        CorrectionsSync(
          queue: OutboxStore(_db, namespace: namespace),
          client: client,
          baseUri: baseUri,
          headers: headers,
          accountIsCurrent: accountIsCurrent,
        ).applyStatuses([
          for (final status in body['corrections'] as List)
            (status as Map).cast<String, Object?>(),
        ]);
        _state.put('rules:latest', '${body['latestBundleVersion']}');
        _rebuildDisplay();
        _state.put('pull:cursor', body['cursor'] as String);
        _db.execute('RELEASE SAVEPOINT sms_v2_pull');
        financial.notifyExternalChanges(namespace, const [
          'transactions',
          'observations',
        ]);
      } catch (_) {
        _db.execute('ROLLBACK TO SAVEPOINT sms_v2_pull');
        _db.execute('RELEASE SAVEPOINT sms_v2_pull');
        rethrow;
      }
    });
  }

  void _adopt(Instrument local, String serverId) {
    final wasDirty = _dirty(
      'v2_instruments',
      'instrument_id',
      local.instrumentId,
    );
    _db.execute(
      'DELETE FROM v2_instruments WHERE namespace=? AND instrument_id=?',
      [namespace, local.instrumentId],
    );
    _instruments.upsert(
      Instrument.fromJson({...local.toJson(), 'instrumentId': serverId}),
      dirty: wasDirty,
    );
    _db.execute(
      'UPDATE v2_facts SET instrument_id=? WHERE namespace=? AND instrument_id=?',
      [serverId, namespace, local.instrumentId],
    );
    for (final child in _instruments.list().where(
      (item) => item.parentInstrumentId == local.instrumentId,
    )) {
      final dirty = _dirty(
        'v2_instruments',
        'instrument_id',
        child.instrumentId,
      );
      _instruments.upsert(
        child.copyWith(parentInstrumentId: serverId),
        dirty: dirty,
      );
    }
    final personal = _state.get('personal:rules');
    if (personal != null) {
      final rules = jsonDecode(personal) as List;
      for (final rule in rules.whereType<Map>()) {
        if (rule['instrumentId'] == local.instrumentId) {
          rule['instrumentId'] = serverId;
        }
      }
      _state.put('personal:rules', jsonEncode(rules));
    }
    void rewrite(Map<String, Object?> json) {
      for (final side in ['from', 'to']) {
        final endpoint = json[side];
        if (endpoint is Map && endpoint['instrumentId'] == local.instrumentId) {
          json[side] = <String, Object?>{'instrumentId': serverId};
        }
      }
    }

    for (final row in _db.select(
      'SELECT entry_id,payload FROM v2_ledger WHERE namespace=?',
      [namespace],
    )) {
      final json = (jsonDecode(row['payload'] as String) as Map)
          .cast<String, Object?>();
      rewrite(json);
      _db.execute(
        'UPDATE v2_ledger SET payload=? WHERE namespace=? AND entry_id=?',
        [jsonEncode(json), namespace, row['entry_id']],
      );
    }
    final pending = _db.select(
      'SELECT id,kind,payload FROM v2_outbox WHERE namespace=?',
      [namespace],
    );
    final queue = OutboxStore(_db, namespace: namespace);
    for (final row in pending) {
      final json = (jsonDecode(row['payload'] as String) as Map)
          .cast<String, Object?>();
      if (row['id'] == 'instrument:${local.instrumentId}') {
        _db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
          namespace,
          row['id'],
        ]);
        json['instrumentId'] = serverId;
        queue.enqueue('instrument', serverId, json);
      } else if (row['kind'] == 'instrument' &&
          json['parentInstrumentId'] == local.instrumentId) {
        json['parentInstrumentId'] = serverId;
        _db.execute(
          'UPDATE v2_outbox SET payload=? WHERE namespace=? AND id=?',
          [jsonEncode(json), namespace, row['id']],
        );
      } else if (row['kind'] == 'ledger') {
        rewrite(json);
        _db.execute(
          'UPDATE v2_outbox SET payload=? WHERE namespace=? AND id=?',
          [jsonEncode(json), namespace, row['id']],
        );
      }
    }
  }

  void _rebuildDisplay() {
    final events = _events.listSince(DateTime.utc(1900));
    final facts = <String, Fact>{};
    final ready = <Event>[];
    for (final event in events) {
      var complete = true;
      for (final leg in event.legs) {
        final fact = facts[leg.factId] ?? _facts.get(leg.factId);
        if (fact == null) {
          complete = false;
        } else {
          facts[leg.factId] = fact;
        }
      }
      if (complete || transactionKindForEvent(event) == null) ready.add(event);
    }
    final readyIds = ready.map((event) => event.eventId).toSet();
    final instruments = {
      for (final instrument in _instruments.list())
        instrument.instrumentId: instrument,
    };
    final instrumentIds = _facts.instrumentIdsSince(DateTime.utc(1900));
    final invalidEvents = {
      for (final event in ready)
        if (event.type == EventType.unknown ||
            event.legs.any((leg) {
              final fact = facts[leg.factId];
              return fact != null &&
                  instrumentForFact(
                        fact,
                        instruments,
                        instrumentIdByFactId: instrumentIds,
                      )?.status ==
                      InstrumentStatus.rejected;
            }))
          event.eventId,
      for (final entry in _ledger.list())
        if ([entry.from, entry.to].whereType<InstrumentEndpoint>().any(
          (endpoint) =>
              instruments[endpoint.instrumentId]?.status ==
              InstrumentStatus.rejected,
        ))
          entry.eventId,
    };
    for (final id in invalidEvents) {
      for (final entry in _ledger.forEvent(id)) {
        _db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
          namespace,
          'ledger:${entry.entryId}',
        ]);
      }
    }
    final entries = _ledger
        .list()
        .where(
          (entry) =>
              readyIds.contains(entry.eventId) &&
              !invalidEvents.contains(entry.eventId),
        )
        .toList();
    final dirtyBefore = _ledger.dirty().map((entry) => entry.entryId).toSet();
    final locked = Map<String, CategoryDecision>.of(
      _ledger.categoryDecisions(), // perf-ok: once per pull, not per entry
    );
    final purchaseFacts = {
      for (final event in ready)
        if (spendEventTypes.contains(event.type)) ...{
          event.eventId,
          ...event.legs.map((leg) => leg.factId),
        },
    };
    // A refund linked to a purchase inherits its category. Its row carries the
    // inherited value (CCR-003), but retaining it as a lock would hide a
    // category refresh of the purchase received from another device. A
    // standalone refund keeps the category its row carries.
    final inheritingRefunds = <String>{};
    for (final event in ready) {
      final inheritsPurchase = event.legs.any(
        (leg) =>
            leg.role == LegRole.original && purchaseFacts.contains(leg.factId),
      );
      if (event.type == EventType.refund &&
          (inheritsPurchase ||
              locked[event.eventId]?.source != CategorySource.user)) {
        locked.remove(event.eventId);
      }
      if (event.type == EventType.refund && inheritsPurchase) {
        inheritingRefunds.add(event.eventId);
      }
    }
    final projectedCategories = LedgerSnapshot.project(
      events: ready,
      factsById: facts,
      instrumentsById: instruments,
      instrumentIdByFactId: instrumentIds,
      bundle: bundle,
      lockedCategories: {
        ...locked,
        for (final entry in entries)
          if (entry.category != null &&
              !inheritingRefunds.contains(entry.eventId))
            entry.eventId: CategoryDecision(
              slug: entry.category!,
              source: entry.categorySource ?? CategorySource.shared,
              confidence: 1,
            ),
      },
    ).categoryByEvent;
    ProjectionWriter(financial, _ledger).write(
      LedgerSnapshot(
        events: ready,
        entries: entries,
        categoryByEvent: projectedCategories,
      ),
      factsById: facts,
      instrumentsById: instruments,
      instrumentIdByFactId: instrumentIds,
      categoryIdBySlug: categoryIdBySlug,
    );
    // These are server projections, so writing the display does not queue a push.
    // One ledger read for all events instead of one query per event.
    final entriesByEvent = <String, List<LedgerEntry>>{};
    for (final entry in _ledger.list()) {
      (entriesByEvent[entry.eventId] ??= []).add(entry);
    }
    for (final event in ready) {
      if (!_dirty('v2_events', 'event_id', event.eventId)) {
        for (final entry in entriesByEvent[event.eventId] ?? const []) {
          if (!dirtyBefore.contains(entry.entryId)) {
            _ledger.markClean([entry.entryId]);
          }
        }
      }
    }
  }
}
