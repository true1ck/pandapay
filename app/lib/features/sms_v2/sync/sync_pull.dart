import 'dart:convert';

import 'package:crypto/crypto.dart';
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

    // What this page can have changed. The projection is rebuilt for these
    // events (and the events that share a fact with them) only; see
    // _rebuildDisplay.
    final touchedEvents = <String>{};
    final touchedFacts = <String>{};
    financial.batch(() {
      _db.execute('SAVEPOINT sms_v2_pull');
      try {
        for (final json in body['facts'] as List? ?? []) {
          final fact = Fact.fromJson((json as Map).cast<String, Object?>());
          touchedFacts.add(fact.factId);
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
          touchedEvents.add(incoming.eventId);
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
          touchedEvents.add(incoming.eventId);
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
        _rebuildDisplay(touchedEvents, touchedFacts);
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
      final rewritten = jsonEncode(json);
      // Most rows do not mention the adopted instrument; leave them alone.
      if (rewritten == row['payload']) continue;
      _db.execute(
        'UPDATE v2_ledger SET payload=? WHERE namespace=? AND entry_id=?',
        [rewritten, namespace, row['entry_id']],
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


  // ---------------------------------------------------------------------------
  // Display projection after a pull
  //
  // The ledger and the display rows are a pure function of: an event, the facts
  // of its legs, the instruments, the rule bundle, the category catalogue and
  // the category decisions already stored. A pull used to rebuild and rewrite
  // all of that for every event of the account, on the UI isolate, once per
  // page. Now the cost follows what the page changed:
  //
  //  * `projection:context` (sync state) is a hash of everything that is NOT one
  //    event's own records: the bundle, the catalogue and the shape of every
  //    instrument (kind, mask, name, status, card link, aliases; not counters
  //    that move on every message). When it differs from the last projection
  //    the whole account is rebuilt once, exactly as before.
  //  * Otherwise only the events this page named (event, ledger and fact
  //    records), events with unsent local edits, and the events that share a
  //    fact with them (a refund inherits its purchase's category) are rebuilt.
  //  * Reads are batched per chunk of ids; nothing queries inside a per-event
  //    loop, and ProjectionWriter skips rows that would not change.
  // ---------------------------------------------------------------------------

  static const _contextKey = 'projection:context';
  static const _contextVersion = 'v1';
  static final _bundleDigests = Expando<String>('SyncPull bundle digest');
  static const _volatileInstrumentFields = {
    'firstSeenAt',
    'lastSeenAt',
    'evidenceCount',
    'creditLimitMinor',
    'creditLimitSource',
    'creditLimitAt',
    'availableMinor',
    'availableAt',
    'pointsBalance',
    'pointsAt',
  };

  String _projectionContext(Iterable<Instrument> instruments) {
    final bundleDigest = _bundleDigests[bundle] ??= sha256
        .convert(utf8.encode(jsonEncode(bundle.toJson())))
        .toString();
    final catalogue = [
      for (final entry in categoryIdBySlug.entries)
        '${entry.key}=${entry.value}',
    ]..sort();
    final shapes = [
      for (final instrument in instruments)
        jsonEncode({
          for (final field in instrument.toJson().entries)
            if (!_volatileInstrumentFields.contains(field.key))
              field.key: field.value,
        }),
    ]..sort();
    return sha256
        .convert(
          utf8.encode(
            [_contextVersion, bundleDigest, ...catalogue, '|', ...shapes].join(
              '\n',
            ),
          ),
        )
        .toString();
  }

  Set<String> _dirtyEventIds() => {
    for (final row in _db.select(
      'SELECT event_id FROM v2_events WHERE namespace=? AND dirty=1',
      [namespace],
    ))
      row['event_id'] as String,
  };

  /// Instrument id of each of [factIds] that has one, one query per 400 ids.
  Map<String, String> _instrumentIdsFor(Iterable<String> factIds) {
    final ids = factIds.toList();
    final out = <String, String>{};
    for (var offset = 0; offset < ids.length; offset += 400) {
      final chunk = ids.skip(offset).take(400).toList();
      for (final row in _db.select(
        'SELECT fact_id,instrument_id FROM v2_facts WHERE namespace=? AND instrument_id IS NOT NULL '
        'AND fact_id IN (${List.filled(chunk.length, '?').join(',')})',
        [namespace, ...chunk],
      )) {
        out[row['fact_id'] as String] = row['instrument_id'] as String;
      }
    }
    return out;
  }

  /// [seeds] plus every event that shares a fact with one of them or holds one
  /// of [newFacts], oldest first (the order the full rebuild uses, which the
  /// "last purchase owns a fact" rule of LedgerSnapshot depends on).
  List<Event> _impactedEvents(Set<String> seeds, Set<String> newFacts) {
    final byId = <String, Event>{};
    for (final id in seeds) {
      // Bounded by the seeds, which are this page's records.
      final event = _events.get(id);
      if (event != null) byId[id] = event;
    }
    final factIds = {
      ...newFacts,
      for (final event in byId.values) ...event.legs.map((leg) => leg.factId),
    };
    for (final event in _events.findByFactIds(factIds)) {
      byId[event.eventId] = event;
    }
    return byId.values.toList()..sort((a, b) {
      final byTime = a.occurredAt.compareTo(b.occurredAt);
      return byTime != 0 ? byTime : a.eventId.compareTo(b.eventId);
    });
  }

  void _rebuildDisplay(Set<String> touchedEvents, Set<String> touchedFacts) {
    final instruments = {
      for (final instrument in _instruments.list())
        instrument.instrumentId: instrument,
    };
    final context = _projectionContext(instruments.values);
    final full = _state.get(_contextKey) != context;
    final dirtyEvents = _dirtyEventIds();
    // null means the whole account.
    final Set<String>? scope;
    final List<Event> events;
    if (full) {
      scope = null;
      events = _events.listSince(DateTime.utc(1900));
    } else {
      final seeds = {
        ...touchedEvents,
        ...dirtyEvents,
        ..._ledger.dirtyEntries().values,
      };
      events = _impactedEvents(seeds, touchedFacts);
      scope = {...seeds, for (final event in events) event.eventId};
    }
    final facts = <String, Fact>{};
    if (full) {
      for (final fact in _facts.all()) {
        facts[fact.factId] = fact;
      }
    } else {
      for (final event in events) {
        for (final leg in event.legs) {
          if (facts.containsKey(leg.factId)) continue;
          // Bounded by the legs of the impacted events.
          final fact = _facts.get(leg.factId);
          if (fact != null) facts[leg.factId] = fact;
        }
      }
    }
    final ready = [
      for (final event in events)
        if (transactionKindForEvent(event) == null ||
            event.legs.every((leg) => facts.containsKey(leg.factId)))
          event,
    ];
    final readyIds = ready.map((event) => event.eventId).toSet();
    final instrumentIds = full
        ? _facts.instrumentIdsSince(DateTime.utc(1900))
        : _instrumentIdsFor(facts.keys);
    final ledgerByEvent = <String, List<LedgerEntry>>{};
    if (full) {
      for (final entry in _ledger.list()) {
        (ledgerByEvent[entry.eventId] ??= []).add(entry);
      }
    } else {
      ledgerByEvent.addAll(_ledger.forEvents(scope!));
    }
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
      for (final entry in ledgerByEvent.values.expand((rows) => rows))
        if ([entry.from, entry.to].whereType<InstrumentEndpoint>().any(
          (endpoint) =>
              instruments[endpoint.instrumentId]?.status ==
              InstrumentStatus.rejected,
        ))
          entry.eventId,
    };
    for (final id in invalidEvents) {
      for (final entry in ledgerByEvent[id] ?? const <LedgerEntry>[]) {
        _db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
          namespace,
          'ledger:${entry.entryId}',
        ]);
      }
    }
    final entries = [
      for (final event in ready)
        if (!invalidEvents.contains(event.eventId))
          ...?ledgerByEvent[event.eventId],
    ];
    final dirtyBefore = _ledger.dirtyEntries(eventIds: scope).keys.toSet();
    final locked = Map<String, CategoryDecision>.of(
      _ledger.categoryDecisions(eventIds: scope),
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
    // These are server projections, so writing the display does not queue a push:
    // rows the write just made dirty are marked clean again, except rows that
    // were already waiting to be pushed and events with unsent edits.
    _ledger.markClean([
      for (final dirty in _ledger.dirtyEntries(eventIds: scope).entries)
        if (readyIds.contains(dirty.value) &&
            !dirtyEvents.contains(dirty.value) &&
            !dirtyBefore.contains(dirty.key))
          dirty.key,
    ]);
    _state.put(_contextKey, context);
  }
}
