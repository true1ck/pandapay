import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../../sms_import/sms_background_queue.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/ledger_store.dart';
import '../storage/sync_state_store.dart';
import 'ai_withdrawal.dart';

/// What one slice found: messages looked at, readings that changed and were
/// taken back, and messages handed back to capture.
typedef ReadingRefreshSlice = ({
  int scanned,
  int changed,
  List<String> withdraw,
  List<QueuedSms> reread,
  bool more,
});

/// Applies a new rule set (or a new engine, or a person's own formats) to the
/// messages already read, without reading the whole inbox again.
///
/// A message is read once, when it arrives. Before this, a newer rule set
/// reached only messages that were still "unknown", or a few narrow groups
/// (spends without a payee, salary without an employer, weak reads). In Nov
/// 2026 18% of one phone's readings came from a rule version that had since
/// changed, and nothing would ever have read them again.
///
/// Smart about cost (R1, R4, R5):
/// * A fingerprint per sender brand covers everything that can change how its
///   messages are read: the engine version, the person's own formats, the
///   rules and ignore rules for that brand or for every sender, the sender's
///   registry entry, the counterparty purposes and the solver pack. Only
///   messages from brands whose fingerprint differs from the one recorded by
///   the last finished pass are looked at. A rule set that changed one bank's
///   rules looks at that bank's messages only.
/// * A message is first read on the side, in memory (the rule engine only, no
///   database write). Only when that reading differs from the stored one is it
///   taken back and read for real. Most messages cost one regex pass.
/// * Messages the person acted on (an edit, a confirmed event, a note, a tag,
///   "leave out of spending", their own category) are never touched: their word
///   wins over any rule. A known transaction is never turned back into an
///   "unknown" message by a rule set that cannot read it any more.
/// * It runs in the capture worker, at most [defaultChunk] candidates per slice
///   in one transaction with the re-read itself, so a crash loses nothing; the
///   cursor survives the app being closed.
class ReadingRefresh {
  ReadingRefresh({
    required this.financial,
    required this.namespace,
    required this.bundle,
    required this.engine,
    required this.appVersion,
    required this.passRevision,
    this.personalRevision = '',
  });

  final FinancialStore financial;
  final String namespace;

  /// The rules in force for this account (shared bundle plus its overlay).
  final RuleBundle bundle;
  final RuleEngine engine;
  final String appVersion;

  /// Changes whenever a pass may be due (see [passRevisionFor]).
  final String passRevision;

  /// The revision of the person's own formats, part of every fingerprint.
  final String personalRevision;

  static const doneKey = 'reading:done';
  static const targetKey = 'reading:target';
  static const cursorKey = 'reading:cursor';
  static const failuresKey = 'reading:failures';
  static const brandsKey = 'reading:brands';
  static const targetBrandsKey = 'reading:target-brands';

  /// Candidates (messages from a changed brand) per slice.
  static const defaultChunk = 150;

  /// Rows looked at per slice when few are candidates, so a pass over an
  /// inbox where only one bank changed still ends in a few slices.
  static const scanLimit = 2000;

  /// The value the runtime and the worker both compute for the rules in force:
  /// engine version plus the overlay and personal revisions.
  static String passRevisionFor(String pipelineRevision) =>
      '$smsEngineVersion|$pipelineRevision';

  late final _db = financial.database.db;
  late final _state = SyncStateStore(_db, namespace: namespace);
  late final _intake = SmsIntakeRepository(financial.database);

  /// True while a pass is due or unfinished for [passRevision].
  bool get pending => isPending(_state, passRevision);

  /// [pending] without building a refresh: one state row read, for the runtime.
  static bool isPending(SyncStateStore state, String passRevision) =>
      state.get(doneKey) != passRevision;

  /// Fingerprint of everything that decides how [brand]'s messages are read.
  String fingerprint(String brand) {
    _global ??= jsonEncode([
      smsEngineVersion,
      personalRevision,
      [for (final c in bundle.counterpartyPurposes) c.toJson()],
      bundle.solverPack,
      [
        for (final r in bundle.rules)
          if (r.senders.contains('*')) [r.id, r.version, r.status.wire],
      ],
      [
        for (final r in bundle.ignoreRules)
          if (r.senders.contains('*')) r.toJson(),
      ],
    ]);
    return _fingerprints[brand] ??= sha256
        .convert(
          utf8.encode(
            jsonEncode([
              _global,
              [
                for (final r in bundle.rules)
                  if (r.senders.contains(brand))
                    [r.id, r.version, r.status.wire],
              ],
              [
                for (final r in bundle.ignoreRules)
                  if (r.senders.contains(brand)) r.toJson(),
              ],
              [
                for (final s in bundle.senders)
                  if (s.brand == brand) s.toJson(),
              ],
            ]),
          ),
        )
        .toString();
  }

  String? _global;
  final _fingerprints = <String, String>{};

  String _brandOf(String sender) =>
      normalizeSenderBrand(sender, bundle.senders).brand;

  Map<String, String> _readBrands(String key) {
    final raw = _state.get(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  /// One slice: picks the next candidates, reads each on the side, and
  /// returns the sources to take back and the messages to read again. The
  /// caller withdraws and captures them in the same transaction (see
  /// `runCaptureChunk`), then the cursor saved here is final.
  ///
  /// [evaluate] false only moves the cursor over the slice (nothing is read on
  /// the side or handed back): used to pass over a slice that keeps failing.
  ReadingRefreshSlice prepare({
    int limit = defaultChunk,
    bool evaluate = true,
  }) {
    const none = <String>[];
    const noMessages = <QueuedSms>[];
    if (!pending) {
      return (
        scanned: 0,
        changed: 0,
        withdraw: none,
        reread: noMessages,
        more: false,
      );
    }
    var cursor = _state.get(cursorKey) ?? '';
    if (_state.get(targetKey) != passRevision) {
      cursor = '';
      _state.put(targetKey, passRevision);
      _state.put(cursorKey, '');
      _state.put(targetBrandsKey, '{}');
    }
    final recorded = _readBrands(brandsKey);
    final seen = _readBrands(targetBrandsKey);

    final rows = _db.select(
      'SELECT id, sender, body, received_at FROM sms_captured_messages '
      'WHERE namespace = ? AND id > ? ORDER BY id LIMIT ?',
      [namespace, cursor, scanLimit],
    );
    final facts = FactStore(_db, namespace: namespace);
    final differing = <String, ({QueuedSms message, List<Fact> facts})>{};
    final withdraw = <String>[];
    final reread = <QueuedSms>[];
    var candidates = 0;
    var scanned = 0;
    String? last;
    for (final row in rows) {
      if (candidates >= limit) break;
      scanned++;
      last = row['id'] as String;
      final sender = row['sender'] as String;
      final brand = _brandOf(sender);
      final print = fingerprint(brand);
      seen[brand] = print;
      if (recorded[brand] == print) continue;
      final decision = _intake.decision(namespace, last)?.decision;
      if (decision != 'matched' && decision != 'ignored') continue;
      candidates++;
      if (!evaluate) continue;
      final message = QueuedSms(
        sender: sender,
        body: row['body'] as String,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          row['received_at'] as int,
          isUtc: true,
        ),
      );
      if (decision == 'ignored') {
        // Capture reads an "ignored" message again by itself when its rules
        // changed (its decision records the older revision); nothing to take
        // back first.
        reread.add(message);
        continue;
      }
      final stored = facts.forSource(last);
      if (_differs(message, last, stored)) {
        differing[last] = (message: message, facts: stored);
      }
    }
    // The person's word is checked once for all differing messages of the
    // slice (one look-up of their events, not one per message: the events
    // table has no index on its legs).
    for (final source in _untouched(differing)) {
      withdraw.add(source);
      reread.add(differing[source]!.message);
    }
    final more =
        last != null && (candidates >= limit || rows.length == scanLimit);
    _state.put(targetBrandsKey, jsonEncode(seen));
    if (more) {
      _state.put(cursorKey, last);
    } else {
      // The pass is complete: every brand looked at now counts as current.
      _state.put(brandsKey, jsonEncode({...recorded, ...seen}));
      _state.put(doneKey, passRevision);
      _state.put(cursorKey, '');
      _state.put(targetBrandsKey, '{}');
    }
    return (
      scanned: scanned,
      changed: withdraw.length,
      withdraw: withdraw,
      reread: reread,
      more: more,
    );
  }

  /// True when reading [message] now gives another answer than [stored], and
  /// the new answer may replace it: no fact of the person's own, and the new
  /// reading is neither a step back to "unknown" nor a wait for history.
  bool _differs(QueuedSms message, String sourceKey, List<Fact> stored) {
    if (stored.any((f) => f.provenance.engine == Engine.user)) return false;
    final outcome = engine.interpretDetailed(
      SmsMessage(
        sender: message.sender,
        body: message.body,
        observedAt: message.receivedAt.toUtc(),
        sourceKey: sourceKey,
        iosFilter: normalizeSenderBrand(message.sender).iosFilter,
      ),
      bundle,
      appVersion: appVersion,
    );
    // A reading that needs earlier messages (a bill reminder or a refund that
    // borrows from history) cannot be judged on its own here.
    if (outcome.pendingBill != null || outcome.pendingRefund != null) {
      return false;
    }
    final result = outcome.result;
    if (result.outcome == InterpretOutcome.unknown) return false;
    return _shape(result.facts) != _shape(stored);
  }

  /// A reading without what only says how it was made (rule id, version, app
  /// and engine versions): two readings with the same shape need no re-read.
  static String _shape(List<Fact> facts) {
    final parts = [
      for (final fact in facts)
        jsonEncode(
          Map.of(fact.toJson())
            ..remove('factId')
            ..remove('provenance'),
        ),
    ]..sort();
    return parts.join('\n');
  }

  /// The sources of [differing] the person has not acted on: no confirmed
  /// event, no category of their own in the ledger, and no display edit on the
  /// row (note, tags, leave out of spending, their category). One look-up per
  /// kind for the whole slice.
  List<String> _untouched(
    Map<String, ({QueuedSms message, List<Fact> facts})> differing,
  ) {
    if (differing.isEmpty) return const [];
    final sourceByFact = {
      for (final entry in differing.entries)
        for (final fact in entry.value.facts) fact.factId: entry.key,
    };
    final touched = <String>{};
    final events = EventStore(
      _db,
      namespace: namespace,
    ).findByFactIds(sourceByFact.keys);
    final sourcesByEvent = <String, Set<String>>{};
    for (final event in events) {
      final sources = {for (final leg in event.legs) ?sourceByFact[leg.factId]};
      sourcesByEvent[event.eventId] = sources;
      if (event.status == EventStatus.userConfirmed) touched.addAll(sources);
    }
    if (sourcesByEvent.isNotEmpty) {
      final decisions = LedgerStore(
        _db,
        namespace: namespace,
      ).categoryDecisions(eventIds: sourcesByEvent.keys.toSet());
      for (final entry in decisions.entries) {
        if (entry.value.source == CategorySource.user) {
          touched.addAll(sourcesByEvent[entry.key] ?? const {});
        }
      }
    }
    final keys = differing.keys.toList();
    for (var start = 0; start < keys.length; start += 400) {
      final chunk = keys.skip(start).take(400).toList();
      for (final row in _db.select(
        "SELECT source_key, payload FROM financial_entities WHERE namespace=? AND entity='transactions' "
        'AND source_key IN (${List.filled(chunk.length, '?').join(',')})',
        [namespace, ...chunk],
      )) {
        final j = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        final note = j['note'];
        final tags = j['tags'];
        if ((note is String && note.trim().isNotEmpty) ||
            (tags is List && tags.isNotEmpty) ||
            j['exclude_from_spend'] == true ||
            j['user_category_id'] != null) {
          touched.add(row['source_key'] as String);
        }
      }
    }
    return [
      for (final source in keys)
        if (!touched.contains(source)) source,
    ];
  }

  /// Takes back [sources] (the ones the person has not acted on, checked again
  /// by the withdrawal itself) and returns those taken.
  static List<String> withdrawAll({
    required FinancialStore financial,
    required String namespace,
    required RuleBundle bundle,
    required Map<String, String> categoryIdBySlug,
    required List<String> sources,
  }) {
    if (sources.isEmpty) return const [];
    return AiWithdrawal(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      categoryIdBySlug: categoryIdBySlug,
    ).withdraw(sources, personChecked: true);
  }
}
