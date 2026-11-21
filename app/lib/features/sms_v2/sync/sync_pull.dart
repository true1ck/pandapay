import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

import '../../../data/cached_regexp.dart';
import '../../../data/connectivity/server_backoff.dart';
import '../../../data/local/financial_store.dart';
import '../category/category_snapshot.dart';
import '../ledger/projection_writer.dart';
import '../storage/draft_verdict_store.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/subscription_store.dart';
import '../storage/sync_state_store.dart';
import 'corrections_sync.dart';
import 'instrument_adoption.dart';

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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    SmsV2Schema.ensure(financial.database.db);
  }

  static bool _alwaysCurrent() => true;
  final bool Function() accountIsCurrent;
  final DateTime Function() _clock;
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
    operation = _recordOutcome(_pull()).whenComplete(() {
      if (identical(_running, operation)) _running = null;
    });
    return _running = operation;
  }

  /// Where the last failed pull is kept for the phone details (not uploaded).
  /// A phone that cannot save a page asks for the same page again on every
  /// sync; without a record the only trace was a count of failures.
  static const problemKey = 'pull:error';

  /// Set when the server answered 429: no pull is sent before this time. Same place as the upload's `template:wait`.
  static const waitKey = 'pull:wait';

  Future<int> _recordOutcome(Future<int> run) async {
    try {
      final pages = await run;
      if (pages > 0) _forgetProblem();
      return pages;
    } catch (error) {
      _rememberProblem(error);
      rethrow;
    }
  }

  void _rememberProblem(Object error) {
    try {
      final text = '$error'.replaceAll(cachedRegExp(r'\s+'), ' ').trim();
      _state.put(
        problemKey,
        jsonEncode({
          'at': _clock().toUtc().toIso8601String(),
          'type': error.runtimeType.toString(),
          'message': text.length > 240 ? '${text.substring(0, 240)}…' : text,
        }),
      );
    } catch (_) {
      // The record is a convenience; never hide the real failure behind it.
    }
  }

  void _forgetProblem() {
    try {
      if (_state.get(problemKey) == null) return;
      _db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [
        namespace,
        problemKey,
      ]);
    } catch (_) {
      // Left for the next successful pull to clear.
    }
  }

  /// The answers in [results] that pass the contract's own check, applied to
  /// the answers alone: what is kept ahead of the page is exactly what the page
  /// itself would have kept. One bad answer does not cost the good ones.
  List<Map> _validAnswers(List results) {
    bool valid(List items) => validateSyncResponseJson({
      'cursor': 'answers',
      'instruments': <Object?>[],
      'events': <Object?>[],
      'ledger': <Object?>[],
      'aiResults': items,
      'corrections': <Object?>[],
      'latestBundleVersion': 0,
    }).ok;
    if (valid(results)) return [for (final result in results) result as Map];
    return [
      for (final result in results)
        if (valid([result])) result as Map,
    ];
  }

  /// Keeps the AI answers a response carries, on their own, before the page is
  /// checked or saved. The page is all-or-nothing, so a page that fails on this
  /// phone (a row it cannot save, a shape it does not know) used to take the
  /// answers down with it and be asked for again, for ever, while the same
  /// answers worked on another phone. An answer says nothing about entities:
  /// keeping it again when the page is asked for again changes nothing.
  void _keepAiAnswers(Object? decoded) {
    final results = decoded is Map ? decoded['aiResults'] : null;
    if (results is! List || results.isEmpty) return;
    final answers = _validAnswers(results);
    if (answers.isEmpty) return;
    financial.batch(() {
      // One transaction for all of them: a commit per answer is a disk sync each.
      _db.execute('SAVEPOINT sms_v2_ai');
      try {
        for (final result in answers) {
          _state.put('ai:${result['templateHash']}', jsonEncode(result));
          // A replacement draft (new id) is checked afresh on this phone.
          DraftVerdictStore(_state).clearIfReplaced(
            '${result['templateHash']}',
            DraftVerdictStore.draftIdOf(result),
          );
        }
        _db.execute('RELEASE SAVEPOINT sms_v2_ai');
      } catch (_) {
        _db.execute('ROLLBACK TO SAVEPOINT sms_v2_ai');
        _db.execute('RELEASE SAVEPOINT sms_v2_ai');
        rethrow;
      }
    });
  }

  /// A pull the server did not answer with 200 used to end with no trace. The status (and the server's error code
  /// when it sent one) is recorded for the phone details, and a 429 holds the next pull for what the server said
  /// (clamped to 30 s to 1 h). A 401 is the shared client's business (it refreshes the session and retries once),
  /// so it is left as it was. Nothing is thrown: the callers see the same quiet 'no pages' as before.
  void _noteRefusal(http.Response response) {
    final status = response.statusCode;
    if (status == 401) return;
    String? code;
    try {
      final body = jsonDecode(response.body);
      final raw = body is Map ? (body['error'] ?? body['code']) : null;
      if (raw is String && raw.isNotEmpty) code = raw.length > 60 ? raw.substring(0, 60) : raw;
    } catch (_) {
      // No readable code; the status says enough.
    }
    _rememberProblem(SyncHttpStatus(status, code));
    if (status == 429) {
      final now = _clock();
      final asked = ServerBackoff.parseRetryAfter(response.headers['retry-after'], now) ?? const Duration(seconds: 60);
      final wait = asked < const Duration(seconds: 30)
          ? const Duration(seconds: 30)
          : asked > const Duration(hours: 1)
          ? const Duration(hours: 1)
          : asked;
      try {
        _state.put(waitKey, now.add(wait).toUtc().toIso8601String());
      } catch (_) {
        // A hold that cannot be saved just means the next pull asks again.
      }
    }
  }

  Future<int> _pull() async {
    var pages = 0;
    final holdUntil = DateTime.tryParse(_state.get(waitKey) ?? '');
    if (holdUntil != null && _clock().isBefore(holdUntil)) return pages;
    final touched = <String>{};
    _fullRebuildSeen = false;
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
              // `decided-at`: this build reads when the user last decided about
              // an instrument or an event (`decidedAt`).
              'X-Sms-Contract-Features':
                  'refund-category,draft-feedback,decided-at',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (!accountIsCurrent()) return pages;
      if (response.statusCode != 200) {
        _noteRefusal(response);
        return pages;
      }
      if (_state.get(waitKey) != null) {
        _db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [namespace, waitKey]);
      }
      final decoded = jsonDecode(response.body);
      _keepAiAnswers(decoded);
      final check = validateSyncResponseJson(decoded);
      if (!check.ok) throw ContractException(check.errors);
      final body = (decoded as Map).cast<String, Object?>();
      final next = body['cursor'] as String;
      final more = response.headers['x-sms-sync-has-more'] == '1';
      if (more && next == cursor) {
        throw const FormatException('Sync cursor did not advance');
      }
      touched.addAll(_apply(body));
      pages++;
      if (!more) {
        // Only now: events and ledger rows page independently, so a ledger row
        // can still be on the next page while its event is already here.
        await _healMissingLedger(touched);
        return pages;
      }
    }
    return pages;
  }

  // ---------------------------------------------------------------------------
  // Events the server holds without ledger rows
  //
  // A phone builds its transactions from the ledger rows the server sends. The
  // server deletes an event's ledger rows when an account the event touches is
  // marked "Not mine" (the sync contract has no tombstones), and nothing sends
  // them back when the account is restored. An event with its facts and its
  // account but no ledger rows then showed nothing for ever on every phone that
  // was installed again. Here the rows are derived the way capture derives them
  // (`LedgerSnapshot.project`, which already returns them and is already run for
  // the categories), written, and queued so the server learns them again.
  // ---------------------------------------------------------------------------

  /// Set once every event of the account has been looked at under this rule.
  static const _healKey = 'ledger:heal:v1';
  static const _healErrorKey = 'ledger:heal:error';

  /// Events derived in one transaction; bounded so a slice stays small (R1).
  static const _healSlice = 500;

  /// Set by [_rebuildDisplay] when an account or rule change made it rebuild
  /// every event (an account marked "Not mine" came back, for example).
  bool _fullRebuildSeen = false;

  /// Looks for money events with no ledger rows after a finished pull: all of
  /// them the first time on this build and after a full rebuild, otherwise only
  /// the events this pull named. Best effort: the pull itself already
  /// succeeded, so a failure is recorded under [_healErrorKey] and tried again
  /// by the next pull (the marker is written only after a complete look).
  Future<void> _healMissingLedger(Set<String> touched) async {
    try {
      final all = _state.get(_healKey) == null || _fullRebuildSeen;
      if (!all && touched.isEmpty) return;
      final ids = _eventsWithoutLedger(only: all ? null : touched);
      for (var start = 0; start < ids.length; start += _healSlice) {
        if (!accountIsCurrent()) return;
        _deriveLedger(ids.skip(start).take(_healSlice).toList());
        if (start + _healSlice < ids.length) {
          await Future<void>.delayed(Duration.zero); // perf-ok: one slice (<= 500 events) per turn
        }
      }
      if (all) _state.put(_healKey, '1');
      if (_state.get(_healErrorKey) != null) {
        _db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [
          namespace,
          _healErrorKey,
        ]);
      }
    } catch (error) {
      _state.put(_healErrorKey, '${error.runtimeType}');
    }
  }

  /// Events of the account (or of [only]) that have no ledger row. Ambiguous and
  /// unknown events never have one. One indexed look-up per event
  /// (`idx_v2_ledger_event`), chunked for [only].
  List<String> _eventsWithoutLedger({Set<String>? only}) {
    const noLedger =
        'NOT EXISTS (SELECT 1 FROM v2_ledger l WHERE l.namespace=e.namespace AND l.event_id=e.event_id) '
        "AND e.status<>'ambiguous' AND e.type<>'unknown'";
    if (only == null) {
      return [
        for (final row in _db.select(
          'SELECT e.event_id FROM v2_events e WHERE e.namespace=? AND $noLedger ORDER BY e.event_id',
          [namespace],
        ))
          row['event_id'] as String,
      ];
    }
    final wanted = only.toList();
    final out = <String>[];
    for (var start = 0; start < wanted.length; start += 400) {
      final chunk = wanted.skip(start).take(400).toList();
      for (final row in _db.select(
        'SELECT e.event_id FROM v2_events e WHERE e.namespace=? AND e.event_id IN (${List.filled(chunk.length, '?').join(',')}) AND $noLedger',
        [namespace, ...chunk],
      )) {
        out.add(row['event_id'] as String);
      }
    }
    return out;
  }

  /// Derives and writes the ledger rows of [ids] (one slice), then queues them
  /// for upload. An event the projector gives no rows (not a money event, an
  /// account marked "Not mine", a leg whose fact is not here) is left alone.
  void _deriveLedger(List<String> ids) {
    final events = <Event>[];
    for (final id in ids) {
      // Bounded by the slice.
      final event = _events.get(id);
      if (event != null) events.add(event);
    }
    final facts = <String, Fact>{};
    for (final event in events) {
      for (final leg in event.legs) {
        if (facts.containsKey(leg.factId)) continue;
        // Bounded by the legs of the slice.
        final fact = _facts.get(leg.factId);
        if (fact != null) facts[leg.factId] = fact;
      }
    }
    final ready = [
      for (final event in events)
        if (transactionKindForEvent(event) != null &&
            event.legs.every((leg) => facts.containsKey(leg.factId)))
          event,
    ];
    if (ready.isEmpty) return;
    final instruments = {
      for (final instrument in _instruments.list())
        instrument.instrumentId: instrument,
    };
    final instrumentIds = _instrumentIdsFor(facts.keys);
    final categories = CategorySnapshot.load(
      financial.database,
      namespace: namespace,
      aliases: bundle.merchantAliases,
    );
    final snapshot = LedgerSnapshot.project(
      events: ready,
      factsById: facts,
      instrumentsById: instruments,
      bundle: bundle,
      userRules: categories.userRules,
      confirmedHistory: categories.confirmedHistory,
      instrumentIdByFactId: instrumentIds,
    );
    final withRows = {for (final entry in snapshot.entries) entry.eventId};
    if (withRows.isEmpty) return;
    financial.batch(() {
      _db.execute('SAVEPOINT sms_v2_ledger_heal');
      try {
        ProjectionWriter(financial, _ledger).write(
          LedgerSnapshot(
            events: [
              for (final event in ready)
                if (withRows.contains(event.eventId)) event,
            ],
            entries: snapshot.entries,
            categoryByEvent: snapshot.categoryByEvent,
          ),
          factsById: facts,
          instrumentsById: instruments,
          instrumentIdByFactId: instrumentIds,
          categoryIdBySlug: categoryIdBySlug,
        );
        // The rows stay dirty until the server accepts them (`FactsUpload`
        // cleans a row it delivered), so a later pull cannot replace them with
        // an older copy meanwhile.
        final queue = OutboxStore(_db, namespace: namespace);
        for (final entry in snapshot.entries) {
          queue.enqueue('ledger', entry.entryId, entry.toJson());
        }
        _db.execute('RELEASE SAVEPOINT sms_v2_ledger_heal');
      } catch (_) {
        _db.execute('ROLLBACK TO SAVEPOINT sms_v2_ledger_heal');
        _db.execute('RELEASE SAVEPOINT sms_v2_ledger_heal');
        rethrow;
      }
    });
    financial.notifyExternalChanges(namespace, const [
      'transactions',
      'observations',
    ]);
  }

  bool _dirty(String table, String column, String id) => _db.select(
    'SELECT 1 FROM $table WHERE namespace=? AND $column=? AND dirty=1',
    [namespace, id],
  ).isNotEmpty;

  /// Whether the server's copy of an instrument replaces a local one that has
  /// not been sent yet. The later explicit choice by the user wins; the
  /// pending local change is then dropped, because the server already holds a
  /// newer decision.
  ///
  /// Without a `decidedAt` on the server's copy (a server or an app from
  /// before it existed) a local dated choice is kept, and an undated local
  /// change yields only to a "not mine", as before.
  @visibleForTesting
  static bool incomingDecisionBeatsLocalEdit(
    Instrument incoming,
    Instrument? local,
  ) {
    final incomingAt = incoming.decidedAt;
    final localAt = local?.decidedAt;
    if (incomingAt != null) return localAt == null || incomingAt.isAfter(localAt);
    if (localAt != null) return false;
    return incoming.status == InstrumentStatus.rejected;
  }

  /// Whether the server's copy of an event replaces a local one that has not
  /// been sent yet. Only a user confirmation can: the later `decidedAt` wins,
  /// and the pending local change is then dropped because the server already
  /// holds a newer decision.
  ///
  /// Without a `decidedAt` on the server's copy a local dated decision is
  /// kept; with neither side dated the server's confirmation wins, as before
  /// `decidedAt` existed.
  @visibleForTesting
  static bool incomingEventDecisionBeatsLocalEdit(
    Event incoming,
    Event? local,
  ) {
    if (incoming.status != EventStatus.userConfirmed) return false;
    final incomingAt = incoming.decidedAt;
    final localAt = local?.decidedAt;
    if (incomingAt != null) return localAt == null || incomingAt.isAfter(localAt);
    return localAt == null;
  }

  /// Applies one page. Returns the events the page named.
  Set<String> _apply(Map<String, Object?> body) {
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
        // Facts (mandates, announcements) and events pulled from another device
        // can start, change or end a subscription; the saved rows follow.
        if (touchedFacts.isNotEmpty || (body['events'] as List? ?? const []).isNotEmpty) {
          SubscriptionStore(_db, namespace: namespace).markDirty();
          financial.notifyExternalChanges(namespace, const ['subscriptions']);
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
          final locallyEdited = _dirty(
            'v2_instruments',
            'instrument_id',
            incoming.instrumentId,
          );
          if ((!locallyEdited ||
                  incomingDecisionBeatsLocalEdit(
                    incoming,
                    _instruments.get(incoming.instrumentId),
                  )) &&
              newer('instruments', incoming.instrumentId)) {
            _instruments.upsert(incoming, dirty: false);
            if (locallyEdited || incoming.status == InstrumentStatus.rejected) {
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
          final eventEdited = _dirty('v2_events', 'event_id', incoming.eventId);
          if ((!eventEdited ||
                  incomingEventDecisionBeatsLocalEdit(
                    incoming,
                    _events.get(incoming.eventId),
                  )) &&
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
        // The AI answers in body['aiResults'] were kept before this page was
        // checked ([_keepAiAnswers]), so a failure below does not lose them.
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
    return touchedEvents;
  }

  void _adopt(Instrument local, String serverId) =>
      adoptServerInstrumentId(_db, namespace, local, serverId);


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
    // When the user decided changes no ledger row; the status itself is what
    // moves the ledger, and it is still part of the hash.
    'decidedAt',
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
    if (full) _fullRebuildSeen = true;
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

/// What the phone details show when `GET /sms/v2/sync` is answered with something other than 200.
class SyncHttpStatus implements Exception {
  const SyncHttpStatus(this.status, this.code);
  final int status;
  final String? code;

  @override
  String toString() => code == null ? 'sync answered HTTP $status' : 'sync answered HTTP $status ($code)';
}
