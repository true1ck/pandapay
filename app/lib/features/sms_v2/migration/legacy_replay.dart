import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:sqlite3/sqlite3.dart';
import '../../../data/local/app_database.dart';
import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../../../data/local/sms_learning_feedback.dart';
import '../../../data/user_cards_repository.dart';
import '../../sms_import/sms_text_hint.dart';
import '../category/category_snapshot.dart';
import '../corrections/corrections_service.dart';
import '../instruments/instrument_seeder.dart';
import '../pipeline/sms_v2_pipeline.dart';
import '../pipeline/intake_gate.dart';
import '../pipeline/trace.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/schema.dart';
import '../ledger/reports.dart';

class ReplayReport {
  const ReplayReport(this.data);
  final Map<String, Object?> data;
  int get retainedBodies => data['retainedMessages'] as int;
  int get legacyWithoutBody => data['legacyWithoutText'] as int;
  int get duplicatesMerged => data['duplicatesMerged'] as int;
  int get holdsRemoved => data['holdsRemoved'] as int;
  bool get complete => data['complete'] == true;
  Map<String, Object?> toJson() => Map.of(data);
}

/// One account's retained history. Originals are archived before any projection
/// and each chunk's local effects, archive visibility and progress commit together.
class LegacyReplay {
  LegacyReplay({
    required this.financial,
    required this.namespace,
    required this.bundle,
    required this.appVersion,
    this.catalogue = const [],
    this.categoryIdBySlug = const {},
    this.accountIsCurrent = _current,
    RuleEngine? engine,
  }) : engine = engine ?? RuleEngine();
  static bool _current() => true;
  final FinancialStore financial;
  final String namespace, appVersion;
  final RuleBundle bundle;
  final List<CardProduct> catalogue;
  final Map<String, String> categoryIdBySlug;
  final bool Function() accountIsCurrent;
  final RuleEngine engine;
  Database get db => financial.database.db;
  void _check() {
    if (!accountIsCurrent()) throw StateError('Migration account changed');
  }

  bool _exists(String table) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
    [table],
  ).isNotEmpty;
  void _ensure() {
    SmsV2Schema.ensure(db);
    SmsIntakeRepository(financial.database);
    db.execute(
      '''CREATE TABLE IF NOT EXISTS sms_v2_migration_state(namespace TEXT PRIMARY KEY,status TEXT NOT NULL,before_json TEXT NOT NULL,report_json TEXT);
CREATE TABLE IF NOT EXISTS sms_v2_migration_originals(namespace TEXT NOT NULL,id TEXT NOT NULL,source_key TEXT,payload TEXT NOT NULL,PRIMARY KEY(namespace,id));
CREATE TABLE IF NOT EXISTS sms_v2_migration_sources(namespace TEXT NOT NULL,source_key TEXT NOT NULL,message_json TEXT NOT NULL,choices_json TEXT NOT NULL,done INTEGER NOT NULL DEFAULT 0,checked INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(namespace,source_key));''',
    );
  }

  Map<String, Map<String, Object?>> _messages({DateTime? from, DateTime? to}) {
    final result = <String, Map<String, Object?>>{};
    for (final table in ['sms_captured_messages', 'sms_intake']) {
      if (!_exists(table)) continue;
      for (final row in db.select(
        'SELECT id,sender,body,received_at FROM $table WHERE namespace=?${from == null ? '' : ' AND received_at>=?'}${to == null ? '' : ' AND received_at<?'} ORDER BY received_at,id',
        [
          namespace,
          if (from != null) from.millisecondsSinceEpoch,
          if (to != null) to.millisecondsSinceEpoch,
        ],
      )) {
        if ((row['body'] as String).trim().isEmpty ||
            classifySmsV2Intake(
                  row['sender'] as String,
                  row['body'] as String,
                ).kind ==
                SmsTriageKind.sensitive) {
          continue;
        }
        result.putIfAbsent(
          row['id'] as String,
          () => {
            'sourceKey': row['id'],
            'sender': row['sender'],
            'body': row['body'],
            'observedAt': DateTime.fromMillisecondsSinceEpoch(
              row['received_at'] as int,
              isUtc: true,
            ).toIso8601String(),
          },
        );
      }
    }
    for (final row in db.select(
      'SELECT id,payload FROM local_needs_review WHERE namespace=?',
      [namespace],
    )) {
      final j = (jsonDecode(row['payload'] as String) as Map)
          .cast<String, Object?>();
      if (j['body'] is String &&
          (j['body'] as String).trim().isNotEmpty &&
          j['sender'] is String) {
        result.putIfAbsent(
          row['id'] as String,
          () => {
            'sourceKey': row['id'],
            'sender': j['sender'],
            'body': j['body'],
            'observedAt': j['receivedAt'] ?? j['received_at'],
          },
        );
      }
    }
    result.removeWhere((_, message) {
      final date = DateTime.tryParse(message['observedAt'] as String? ?? '');
      return date == null ||
          from != null && date.isBefore(from) ||
          to != null && !date.isBefore(to);
    });
    return result;
  }

  Map<String, Map<String, Object?>> _choices({Set<String>? sources}) {
    final result = <String, Map<String, Object?>>{};
    void add(String source, Map<String, Object?> value) =>
        result.putIfAbsent(source, () => {}).addAll(value);
    if (_exists('sms_learning_feedback_outbox')) {
      for (final row in db.select(
        'SELECT source_key,payload FROM sms_learning_feedback_outbox WHERE namespace=? ORDER BY queued_at,event_id',
        [namespace],
      )) {
        if (sources != null && !sources.contains(row['source_key'])) continue;
        final j = jsonDecode(row['payload'] as String) as Map;
        if (j['action'] == 'edited' || j['action'] == 'category_changed') {
          add(
            row['source_key'] as String,
            ((j['correctedFields'] as Map?) ?? {}).cast<String, Object?>(),
          );
        }
        if (j['correctionKind'] == 'false_transaction' ||
            j['action'] == 'dismissed') {
          if (sources == null || sources.contains(row['source_key'])) {
            add(row['source_key'] as String, {'deleted': true});
          }
        }
      }
    }
    final legacy = financial
        .entities(namespace, 'transactions')
        .where(
          (r) =>
              (r['pipeline_version'] ?? 1) == 1 &&
              ['sms', 'sms_bulk'].contains(r['source']),
        );
    for (final row in legacy) {
      final source = row['source_key'];
      if (source is! String || sources != null && !sources.contains(source)) {
        continue;
      }
      if (row['status'] == 'ignored' ||
          row['status'] == 'deleted' ||
          (row['note'] as String? ?? '').startsWith('[deleted')) {
        add(source, {'deleted': true});
      }
      if (row['status'] == 'active' && result[source]?['deleted'] != true) {
        add(source, {'deleted': false});
      }
      if (row['user_category_id'] case final String chosenCategory) {
        add(source, {'categoryId': chosenCategory});
      }
      // Explicit edit evidence is separate from parser output. A plain legacy
      // reading never becomes a user fact just because the new parser differs.
      final modified =
          row['is_user_modified'] == true ||
          row['user_modified'] == true ||
          (_exists('local_auto_resolved_history') &&
              db.select(
                'SELECT 1 FROM local_auto_resolved_history WHERE namespace=? AND source_key=? AND is_user_modified=1',
                [namespace, source],
              ).isNotEmpty);
      if (modified) {
        add(source, {
          'amountInr': row['amount_inr'],
          'merchant': row['merchant_name'],
          'occurredAt': row['occurred_at'],
          if (row['user_category_id'] ?? row['category_id']
              case final String id)
            'categoryId': id,
          if (row['category_name'] != null)
            'categoryName': row['category_name'],
        });
      }
      if (_exists('sync_pending_changes')) {
        for (final pending in db.select(
          "SELECT op,payload_json FROM sync_pending_changes WHERE namespace=? AND entity='transactions' AND entity_id=? ORDER BY client_seq",
          [namespace, row['id']],
        )) {
          if (pending['op'] == 'delete') {
            add(source, {'deleted': true});
            continue;
          }
          final fields = (jsonDecode(pending['payload_json'] as String) as Map)
              .cast<String, Object?>();
          add(
            source,
            {
              'amountInr': fields['amountInr'] ?? fields['amount_inr'],
              'merchant': fields['merchantName'] ?? fields['merchant_name'],
              'occurredAt': fields['occurredAt'] ?? fields['occurred_at'],
              'categoryId': fields['categoryId'] ?? fields['category_id'],
            }..removeWhere((k, v) => v == null),
          );
        }
      }
    }
    if (_exists('sync_pending_changes')) {
      for (final row in db.select(
        "SELECT r.source_key FROM sync_pending_changes p JOIN financial_source_receipts r ON r.namespace=p.namespace AND r.transaction_id=p.entity_id WHERE p.namespace=? AND p.entity='transactions' AND p.op='delete'",
        [namespace],
      )) {
        if (sources == null || sources.contains(row['source_key'])) {
          add(row['source_key'] as String, {'deleted': true});
        }
      }
    }
    return result;
  }

  void _prepare({
    bool includeNewSources = false,
    DateTime? from,
    DateTime? to,
  }) {
    _ensure();
    final previous = db.select(
      'SELECT status FROM sms_v2_migration_state WHERE namespace=?',
      [namespace],
    ).firstOrNull;
    final prepared = previous != null;
    if (prepared && !includeNewSources) {
      return;
    }
    final messages = _messages(from: from, to: to);
    final choices = _choices();
    final before = _monthly();
    db.execute('SAVEPOINT sms_migration_prepare');
    try {
      for (final row in financial.entities(namespace, 'transactions')) {
        db.execute(
          'INSERT OR IGNORE INTO sms_v2_migration_originals VALUES(?,?,?,?)',
          [namespace, row['id'], row['source_key'], jsonEncode(row)],
        );
      }
      for (final entry in messages.entries) {
        db.execute(
          'INSERT OR IGNORE INTO sms_v2_migration_sources(namespace,source_key,message_json,choices_json) VALUES(?,?,?,?)',
          [
            namespace,
            entry.key,
            jsonEncode(entry.value),
            jsonEncode(choices[entry.key] ?? {}),
          ],
        );
      }
      for (final pending in db.select(
        'SELECT id,payload FROM local_needs_review WHERE namespace=?',
        [namespace],
      )) {
        final source = pending['id'] as String;
        if (from == null && to == null && !messages.containsKey(source)) {
          _review(source);
        }
      }
      if (!prepared) {
        db.execute(
          'INSERT INTO sms_v2_migration_state(namespace,status,before_json) VALUES(?,?,?)',
          [namespace, 'running', jsonEncode(before)],
        );
      } else if (previous['status'] == 'complete' &&
          db.select(
            'SELECT 1 FROM sms_v2_migration_sources WHERE namespace=? AND done=0 LIMIT 1',
            [namespace],
          ).isNotEmpty) {
        db.execute(
          "UPDATE sms_v2_migration_state SET status='running',report_json=NULL,before_json=? WHERE namespace=?",
          [jsonEncode(before), namespace],
        );
      }
      InstrumentSeeder(InstrumentStore(db, namespace: namespace)).seed(
        cards: financial
            .entities(namespace, 'cards')
            .map(UserCard.fromJson)
            .toList(),
        issuerSlugOf: cardIssuerSlugFromCatalogue(catalogue),
        bankAccounts: const [],
      );
      db.execute('RELEASE sms_migration_prepare');
    } catch (_) {
      db.execute('ROLLBACK TO sms_migration_prepare');
      db.execute('RELEASE sms_migration_prepare');
      rethrow;
    }
  }

  ReplayReport? savedReport() {
    if (!_exists('sms_v2_migration_state')) return null;
    final row = db.select(
      "SELECT report_json FROM sms_v2_migration_state WHERE namespace=? AND status='complete'",
      [namespace],
    ).firstOrNull;
    if (row == null) return null;
    return ReplayReport(
      (jsonDecode(row['report_json'] as String) as Map).cast<String, Object?>(),
    );
  }

  bool get hasLegacyHistory =>
      financial
          .entities(namespace, 'transactions')
          .any(
            (r) =>
                (r['pipeline_version'] ?? 1) == 1 &&
                ['sms', 'sms_bulk'].contains(r['source']),
          ) ||
      db.select('SELECT 1 FROM local_needs_review WHERE namespace=? LIMIT 1', [
        namespace,
      ]).isNotEmpty;
  Future<ReplayReport> run({
    int chunkSize = 200,
    void Function(int)? onChunk,
    bool includeNewSources = false,
    DateTime? from,
    DateTime? to,
  }) async {
    if (chunkSize < 1 || chunkSize > 500) {
      throw ArgumentError('Use chunks of 1 to 500');
    }
    _check();
    if (from != null && to != null && !from.isBefore(to)) {
      throw ArgumentError('Choose a nonempty period');
    }
    // A requested maintenance preview compares against the account now, not
    // the initial migration's archived baseline. Keep the saved global report.
    final requestedBefore = from == null && to == null ? null : _monthly();
    ReplayReport requestedReport({bool complete = true}) => ReplayReport({
      ..._report(complete: complete, from: from, to: to).toJson(),
      'beforeByMonth': requestedBefore,
    });
    _prepare(includeNewSources: includeNewSources, from: from, to: to);
    final saved = db.select(
      'SELECT status,report_json FROM sms_v2_migration_state WHERE namespace=?',
      [namespace],
    ).single;
    if (saved['status'] == 'complete') {
      if (from != null || to != null) {
        return requestedReport();
      }
      return ReplayReport(
        (jsonDecode(saved['report_json'] as String) as Map)
            .cast<String, Object?>(),
      );
    }
    var chunks = 0;
    while (true) {
      _check();
      final rows = db.select(
        'SELECT source_key,message_json,choices_json FROM sms_v2_migration_sources WHERE namespace=? AND done=0${from == null ? '' : ' AND julianday(json_extract(message_json,\'\$.observedAt\'))>=julianday(?)'}${to == null ? '' : ' AND julianday(json_extract(message_json,\'\$.observedAt\'))<julianday(?)'} ORDER BY json_extract(message_json,\'\$.observedAt\'),source_key LIMIT ?',
        [
          namespace,
          if (from != null) from.toUtc().toIso8601String(),
          if (to != null) to.toUtc().toIso8601String(),
          chunkSize,
        ],
      );
      if (rows.isEmpty) break;
      financial.batch(() {
        db.execute('SAVEPOINT sms_migration_chunk');
        try {
          final queuedBefore = {
            for (final row in db.select(
              'SELECT id,payload FROM v2_outbox WHERE namespace=?',
              [namespace],
            ))
              row['id']: row['payload'],
          };
          // Refresh after every yield/resume: the user may edit or delete a
          // legacy row after preparation but before its chunk is processed.
          final sourceIds = rows.map((r) => r['source_key'] as String).toSet();
          final latestChoices = _choices(sources: sourceIds);
          final choicesBySource = <String, Map<String, Object?>>{
            for (final row in rows)
              row['source_key'] as String: {
                ...(jsonDecode(row['choices_json'] as String) as Map)
                    .cast<String, Object?>(),
                ...?latestChoices[row['source_key']],
              },
          };
          for (final current in financial.entities(namespace, 'transactions')) {
            if ((current['pipeline_version'] ?? 1) != 1 ||
                !sourceIds.contains(current['source_key'])) {
              continue;
            }
            db.execute(
              'INSERT INTO sms_v2_migration_originals VALUES(?,?,?,?) '
              'ON CONFLICT(namespace,id) DO UPDATE SET payload=excluded.payload',
              [
                namespace,
                current['id'],
                current['source_key'],
                jsonEncode(current),
              ],
            );
          }
          for (final entry in choicesBySource.entries) {
            db.execute(
              'UPDATE sms_v2_migration_sources SET choices_json=? WHERE namespace=? AND source_key=?',
              [jsonEncode(entry.value), namespace, entry.key],
            );
          }
          final deferred = <String>{};
          final messages = <SmsMessage>[];
          for (final row in rows) {
            final j = (jsonDecode(row['message_json'] as String) as Map)
                .cast<String, Object?>();
            final source = row['source_key'] as String;
            final choice = choicesBySource[source]!;
            if (choice['deleted'] == true) {
              SmsLearningFeedback(
                financial.database,
                namespace: namespace,
              ).recordFalseTransactionRule(
                sender: j['sender'] as String,
                body: j['body'] as String,
              );
              SmsIntakeRepository(financial.database).recordDecision(
                namespace,
                sourceKey: source,
                decision: 'user_corrected_not_financial',
                state: 'final',
                reasonCode: 'migration_deleted',
                receivedAt: DateTime.parse(
                  j['observedAt'] as String,
                ).millisecondsSinceEpoch,
                policyVersion: 'v2',
              );
              continue;
            }
            final editedDate = DateTime.tryParse(
              choice['occurredAt'] as String? ?? '',
            );
            final categoryId = choice['categoryId'] as String?;
            if (categoryId != null &&
                    !categoryIdBySlug.containsValue(categoryId) ||
                editedDate != null &&
                    editedDate.isAfter(
                      DateTime.parse(j['observedAt'] as String),
                    )) {
              // Unsupported user choices remain visible exactly as entered.
              // They need a human decision; never overwrite them or stop the
              // rest of the account's history migration.
              deferred.add(source);
              _review(source, reason: 'legacy_user_choice');
              continue;
            }
            final triage = classifySmsV2Intake(
              j['sender'] as String,
              j['body'] as String,
            );
            if (triage.kind != SmsTriageKind.financialCandidate) continue;
            for (final old in _originalFor(source)) {
              if (old['status'] == 'active') {
                _writeRaw({...old, 'status': 'superseded'});
              }
            }
            messages.add(
              SmsMessage(
                sender: j['sender'] as String,
                body: j['body'] as String,
                sourceKey: source,
                observedAt: DateTime.parse(j['observedAt'] as String).toUtc(),
              ),
            );
          }
          final category = CategorySnapshot.load(
            financial.database,
            namespace: namespace,
            aliases: bundle.merchantAliases,
          );
          SmsV2Pipeline(
            financial: financial,
            namespace: namespace,
            bundle: bundle,
            appVersion: appVersion,
            engine: engine,
            userRules: category.userRules,
            confirmedHistory: category.confirmedHistory,
            categoryIdBySlug: categoryIdBySlug,
          ).processBatch(messages, backfill: true);
          for (final row in rows) {
            final source = row['source_key'] as String;
            final facts = FactStore(db, namespace: namespace).forSource(source);
            final events = EventStore(
              db,
              namespace: namespace,
            ).findByFactIds(facts.map((f) => f.factId));
            final choice = choicesBySource[source]!;
            final nonMoney =
                facts.isNotEmpty &&
                facts.every(
                  (fact) =>
                      fact is! MovementFact &&
                      fact is! HoldFact &&
                      fact is! InfoFact,
                );
            if (events.isNotEmpty && choice['deleted'] != true) {
              _carryChoices(source, choice, events.first, facts);
            }
            if (events.isEmpty &&
                !nonMoney &&
                choice['deleted'] != true &&
                !deferred.contains(source)) {
              for (final old in _originalFor(source)) {
                _writeRaw(old);
              }
              if (facts.isEmpty) _review(source);
            }
            db.execute(
              'UPDATE sms_v2_migration_sources SET done=1,checked=? WHERE namespace=? AND source_key=?',
              [
                (events.isNotEmpty || nonMoney || choice['deleted'] == true) &&
                        !deferred.contains(source)
                    ? 1
                    : 0,
                namespace,
                source,
              ],
            );
          }
          for (final queued in db.select(
            "SELECT id,payload FROM v2_outbox WHERE namespace=? AND kind IN ('source','instrument','event','ledger')",
            [namespace],
          )) {
            if (queuedBefore[queued['id']] != queued['payload']) {
              db.execute(
                "UPDATE v2_outbox SET payload=json_set(payload,'\$._backfill',json('true')) WHERE namespace=? AND id=?",
                [namespace, queued['id']],
              );
            }
          }
          db.execute('RELEASE sms_migration_chunk');
          financial.notifyExternalChanges(namespace, const [
            'transactions',
            'observations',
            'needs_review',
          ]);
        } catch (_) {
          db.execute('ROLLBACK TO sms_migration_chunk');
          db.execute('RELEASE sms_migration_chunk');
          rethrow;
        }
      });
      onChunk?.call(++chunks);
      await Future<void>.delayed(Duration.zero);
    }
    _check();
    final complete = db.select(
      'SELECT 1 FROM sms_v2_migration_sources WHERE namespace=? AND done=0 LIMIT 1',
      [namespace],
    ).isEmpty;
    final report = _report(complete: complete);
    db.execute(
      'UPDATE sms_v2_migration_state SET status=?,report_json=? WHERE namespace=?',
      [
        complete ? 'complete' : 'running',
        jsonEncode(report.toJson()),
        namespace,
      ],
    );
    return from == null && to == null
        ? report
        : requestedReport(complete: complete);
  }

  List<Map<String, Object?>> _originalFor(String source) => [
    for (final row in db.select(
      'SELECT payload FROM sms_v2_migration_originals WHERE namespace=? AND source_key=?',
      [namespace, source],
    ))
      (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
  ];
  void _writeRaw(Map<String, Object?> row) {
    db.execute(
      "UPDATE financial_entities SET payload=?,pending=0 WHERE namespace=? AND entity='transactions' AND id=?",
      [jsonEncode(row), namespace, row['id']],
    );
  }

  void _review(String source, {String reason = 'legacy_unchecked'}) {
    db.execute(
      "INSERT OR IGNORE INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,?)",
      [
        namespace,
        'migration:$source',
        'template',
        jsonEncode({
          'sourceKey': source,
          'templateHash': 'migration:$source',
          'reason': reason,
        }),
        'open',
      ],
    );
  }

  void _carryChoices(
    String source,
    Map<String, Object?> choices,
    Event event,
    List<Fact> facts,
  ) {
    final fact =
        facts.whereType<MovementFact>().firstOrNull ??
        facts.whereType<HoldFact>().firstOrNull;
    if (fact == null) return;
    final service = CorrectionsService(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      categoryIdBySlug: categoryIdBySlug,
    );
    void apply(CorrectionKind kind, Map<String, Object?> patch) {
      final id = sha256
          .convert(
            utf8.encode(
              'migration|$namespace|$source|${kind.wire}|${canonicalJson(patch)}',
            ),
          )
          .toString();
      service.apply(
        SmsCorrection(
          id: id,
          sourceKey: source,
          kind: kind,
          corrected: patch,
          factIds: [fact.factId],
          eventId: event.eventId,
          reportCase: false,
          trace: DecisionTrace(
            appVersion: appVersion,
            engineVersion: engine.engineVersion,
            bundleVersion: bundle.bundleVersion,
            outcome: 'matched',
            facts: facts,
            event: event,
          ),
        ),
      );
    }

    if (choices['amountInr'] case final num amount) {
      apply(CorrectionKind.wrongAmount, {
        'amountMinor': (amount * 100).round(),
      });
    }
    if (choices['merchant'] case final String merchant) {
      if (merchant.trim().isNotEmpty) {
        apply(CorrectionKind.wrongMerchant, {'merchantName': merchant});
      }
    }
    if (choices['occurredAt'] case final String date) {
      apply(CorrectionKind.wrongDate, {
        'occurredAt': DateTime.parse(date).toUtc().toIso8601String(),
      });
    }
    String? slug = choices['categorySlug'] as String?;
    if (slug == null && choices['categoryId'] is String) {
      slug = categoryIdBySlug.entries
          .where((e) => e.value == choices['categoryId'])
          .firstOrNull
          ?.key;
    }
    if (slug == null && choices['categoryName'] is String) {
      slug = TaxonomyRegistry.v1.categories
          .where(
            (c) =>
                c.displayName.toLowerCase() ==
                (choices['categoryName'] as String).toLowerCase(),
          )
          .firstOrNull
          ?.slug;
    }
    if (slug != null) {
      apply(CorrectionKind.wrongCategory, {
        'category': slug,
        'merchantKey': normalizeMerchantText(
          choices['merchant'] as String? ??
              fact.counterparty?.name ??
              'UNKNOWN',
        ),
      });
    }
  }

  Map<String, Object?> _monthly() {
    final rows = financial
        .entities(namespace, 'transactions')
        .map(TransactionEntry.fromJson)
        .toList();
    final snapshot = LedgerReadModel(
      ledger: LedgerSnapshot(
        events: EventStore(
          db,
          namespace: namespace,
        ).listSince(DateTime.utc(1900)),
        entries: LedgerStore(db, namespace: namespace).list(),
      ),
      transactions: rows,
    ).snapshot();
    final months = <String, Map<String, Object?>>{};
    for (final row in rows.where((r) => r.status == 'active')) {
      final local = row.occurredAt.toUtc().add(
        const Duration(hours: 5, minutes: 30),
      );
      final key = '${local.year}-${local.month.toString().padLeft(2, '0')}';
      if (months.containsKey(key)) continue;
      final from = DateTime.utc(
        local.year,
        local.month,
      ).subtract(const Duration(hours: 5, minutes: 30));
      final to = DateTime.utc(
        local.year,
        local.month + 1,
      ).subtract(const Duration(hours: 5, minutes: 30));
      final t = snapshot.totals(from, to);
      months[key] = {
        'spendMinor': t.spendMinor,
        'incomeMinor': t.incomeMinor,
        'investmentMinor': t.investmentMinor,
        'transactionCount': t.transactionCount,
      };
    }
    return months;
  }

  ReplayReport _report({bool complete = true, DateTime? from, DateTime? to}) {
    final originals = [
      for (final r in db.select(
        'SELECT payload FROM sms_v2_migration_originals WHERE namespace=?',
        [namespace],
      ))
        (jsonDecode(r['payload'] as String) as Map).cast<String, Object?>(),
    ];
    final sources = db.select(
      'SELECT source_key,checked FROM sms_v2_migration_sources WHERE namespace=?${from == null ? '' : ' AND julianday(json_extract(message_json,\'\$.observedAt\'))>=julianday(?)'}${to == null ? '' : ' AND julianday(json_extract(message_json,\'\$.observedAt\'))<julianday(?)'}',
      [
        namespace,
        if (from != null) from.toUtc().toIso8601String(),
        if (to != null) to.toUtc().toIso8601String(),
      ],
    );
    final retained = sources.map((r) => r['source_key']).toSet();
    final oldSms = originals
        .where(
          (r) =>
              ['sms', 'sms_bulk'].contains(r['source']) &&
              (r['pipeline_version'] ?? 1) == 1 &&
              (from == null && to == null ||
                  () {
                    final date = DateTime.tryParse(
                      r['occurred_at'] as String? ?? '',
                    );
                    return date != null &&
                        (from == null || !date.isBefore(from)) &&
                        (to == null || date.isBefore(to));
                  }()),
        )
        .toList();
    final events = EventStore(
      db,
      namespace: namespace,
    ).listSince(DateTime.utc(1900));
    final facts = FactStore(db, namespace: namespace);
    var duplicates = 0, holds = 0, transfers = 0;
    for (final event in events) {
      final eventSources = event.legs
          .map((l) => facts.get(l.factId)?.sourceKey)
          .whereType<String>()
          .toSet();
      final old = oldSms
          .where((r) => eventSources.contains(r['source_key']))
          .toList();
      if (old.length > 1) duplicates += old.length - 1;
      if (event.type == EventType.ipoApplication &&
          event.legs.any((l) => l.role == LegRole.holdPlaced) &&
          old.isNotEmpty) {
        holds++;
      }
      if (event.type == EventType.ownTransfer) {
        transfers += old.where((r) => r['entry_kind'] != 'transfer').length;
      }
    }
    final before = jsonDecode(
      db.select(
            'SELECT before_json FROM sms_v2_migration_state WHERE namespace=?',
            [namespace],
          ).single['before_json']
          as String,
    );
    return ReplayReport({
      'complete': complete,
      'retainedMessages': sources.length,
      'legacyWithoutText': oldSms
          .where((r) => !retained.contains(r['source_key']))
          .length,
      'uncheckedMessages': sources.where((r) => r['checked'] == 0).length,
      'duplicatesMerged': duplicates,
      'holdsRemoved': holds,
      'transfersRemoved': transfers,
      'beforeByMonth': before,
      'afterByMonth': _monthly(),
    });
  }

  /// SQLite's native backup makes a private memory copy. Neither schema setup,
  /// progress, projection nor test uploads write to the real account database.
  Future<ReplayReport> dryRun() async {
    _check();
    final clone = sqlite3.copyIntoMemory(db);
    final copy = AppDatabase.forTesting(clone);
    final store = FinancialStore(copy);
    try {
      return await LegacyReplay(
        financial: store,
        namespace: namespace,
        bundle: bundle,
        appVersion: appVersion,
        catalogue: catalogue,
        categoryIdBySlug: categoryIdBySlug,
        engine: engine,
        accountIsCurrent: accountIsCurrent,
      ).run();
    } finally {
      store.dispose();
      clone.dispose();
    }
  }
}
