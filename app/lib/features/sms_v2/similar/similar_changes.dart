import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart';
import '../migration/history_category_recheck.dart';
import '../personal/personal_merchant_aliases.dart';
import '../pipeline/trace.dart';
import '../providers/data_providers.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../ui/review_controller.dart';
import 'fact_keys.dart';
import 'similar_finder.dart';

/// What a person can change on one transaction and then be offered to change
/// on the others that look the same.
enum SimilarField { shopName, category, paymentMethod, type }

/// Facts about a transaction as it was before the edit, kept because the edit
/// itself changes them (a payment-method change moves the card, a rename
/// changes the shop on the current reading).
class EditSnapshot {
  const EditSnapshot({
    required this.eventId,
    this.merchantKey,
    this.printedName,
    this.ruleId,
    this.instrumentId,
    this.type,
    this.observedAt,
  });
  final String eventId;
  final String? merchantKey;
  final String? printedName;
  final String? ruleId;
  final String? instrumentId;
  final EventType? type;
  final DateTime? observedAt;
}

/// A question for the person: apply this change to [summary.count] others?
class SimilarOffer {
  const SimilarOffer({
    required this.field,
    required this.criteria,
    required this.summary,
    required this.eventId,
    required this.change,
    required this.snapshot,
  });
  final SimilarField field;
  final SimilarCriteria criteria;
  final SimilarSummary summary;

  /// The transaction that was edited; it is never part of the others.
  final String eventId;

  /// The new value: `name`, `category`, `instrumentId` or `eventType`.
  final Map<String, Object?> change;
  final EditSnapshot snapshot;

  /// Payment method and type move money between cards and totals, so the
  /// person is always asked. A shop name and a category are applied to later
  /// SMS on their own; only the earlier ones are asked about.
  bool get movesMoney =>
      field == SimilarField.paymentMethod || field == SimilarField.type;

  /// Only a shop name can be taken back in one step.
  bool get canUndo => field == SimilarField.shopName;
}

class SimilarResult {
  const SimilarResult({
    required this.changed,
    required this.stopped,
    this.changeId,
    this.awaitingSync = 0,
  });
  final int changed;

  /// Transactions whose money has not reached the server yet. They are left
  /// alone for now (a category pass never changes money that is still in
  /// flight) and can be offered again after the next sync.
  final int awaitingSync;

  /// True when the person cancelled or the account changed part way.
  final bool stopped;

  /// Set when the change can be undone.
  final String? changeId;
}

/// Looks for other transactions a change could also apply to, applies it in
/// small chunks, and takes back a shop-name change.
class SimilarChanges {
  SimilarChanges({
    required this.financial,
    required this.namespace,
    required this.bundle,
    required this.controller,
    this.categoryIdBySlug = const {},
    this.chunkSize = 25,
  });

  /// The same account, rules and sharing choice as [controller].
  factory SimilarChanges.forController(
    ReviewController controller, {
    Map<String, String> categoryIdBySlug = const {},
  }) => SimilarChanges(
    financial: controller.financial,
    namespace: controller.namespace,
    bundle: controller.bundle,
    controller: controller,
    categoryIdBySlug: categoryIdBySlug,
  );

  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final ReviewController controller;
  final Map<String, String> categoryIdBySlug;
  final int chunkSize;

  Database get _db => financial.database.db;
  SimilarFinder get _finder => SimilarFinder(_db, namespace: namespace);

  /// Read BEFORE the edit is saved.
  EditSnapshot? snapshot(TransactionEntry original) {
    final eventId = original.eventId;
    if (original.pipelineVersion != 2 || eventId == null) return null;
    final facts = FactStore(_db, namespace: namespace);
    final anchor = facts.get(eventId);
    if (anchor == null) return null;
    final key = FactKeys.of(anchor);
    final instrument = _db.select(
      'SELECT instrument_id FROM v2_facts WHERE namespace=? AND fact_id=?',
      [namespace, anchor.factId],
    );
    return EditSnapshot(
      eventId: eventId,
      merchantKey: key.merchantKey,
      printedName: anchor.counterparty?.name,
      ruleId: key.ruleId,
      instrumentId: instrument.firstOrNull?['instrument_id'] as String?,
      type: EventStore(_db, namespace: namespace).get(eventId)?.type,
      observedAt: anchor.observedAt,
    );
  }

  /// One offer for each changed field that has other transactions to apply to.
  /// A field nobody else shares produces nothing.
  List<SimilarOffer> offers(
    EditSnapshot before, {
    String? shopName,
    String? categorySlug,
    String? instrumentId,
    EventType? eventType,
  }) {
    SimilarOffer? offer(
      SimilarField field,
      SimilarCriteria? criteria,
      Map<String, Object?> change,
    ) {
      if (criteria == null) return null;
      final summary = _finder.summarize(
        criteria,
        excludeEventId: before.eventId,
      );
      if (summary.isEmpty) return null;
      return SimilarOffer(
        field: field,
        criteria: criteria,
        summary: summary,
        eventId: before.eventId,
        change: change,
        snapshot: before,
      );
    }

    final shop = before.merchantKey == null
        ? null
        : SimilarCriteria.shop(before.merchantKey!);
    return [
      if (shopName != null)
        ?offer(SimilarField.shopName, shop, {'name': shopName}),
      if (categorySlug != null)
        ?offer(SimilarField.category, shop, {'category': categorySlug}),
      if (instrumentId != null &&
          before.instrumentId != null &&
          before.ruleId != null)
        ?offer(
          SimilarField.paymentMethod,
          SimilarCriteria.instrument(
            instrumentId: before.instrumentId!,
            ruleId: before.ruleId!,
          ),
          {'instrumentId': instrumentId},
        ),
      if (eventType != null && before.ruleId != null && before.type != null)
        ?offer(
          SimilarField.type,
          SimilarCriteria.type(ruleId: before.ruleId!, type: before.type!),
          {'eventType': eventType.wire},
        ),
    ];
  }

  /// Applies [offer] to every other transaction it matches, [chunkSize] at a
  /// time, yielding between chunks. [shouldContinue] false stops cleanly after
  /// the current chunk; what was done stays done.
  Future<SimilarResult> apply(
    SimilarOffer offer, {
    void Function(int done, int total)? onProgress,
    bool Function()? shouldContinue,
  }) async {
    final ids = <String>[];
    SimilarCursor? after;
    // The list is read once, up front, so a change that moves transactions
    // out of the criteria (a payment-method change) cannot skip any.
    while (true) {
      final page = _finder.page(
        offer.criteria,
        limit: 500,
        excludeEventId: offer.eventId,
        after: after,
      );
      if (page.isEmpty) break;
      ids.addAll(page.map((item) => item.eventId));
      after = page.last.cursor;
    }
    return switch (offer.field) {
      SimilarField.shopName => _applyShopName(offer, ids, onProgress, shouldContinue),
      SimilarField.category => _applyCategory(offer, ids, onProgress, shouldContinue),
      SimilarField.paymentMethod || SimilarField.type => _applyEach(
        offer,
        ids,
        onProgress,
        shouldContinue,
      ),
    };
  }

  Future<SimilarResult> _applyShopName(
    SimilarOffer offer,
    List<String> ids,
    void Function(int, int)? onProgress,
    bool Function()? shouldContinue,
  ) async {
    final printed = offer.snapshot.printedName;
    final name = offer.change['name'] as String;
    if (printed == null) return const SimilarResult(changed: 0, stopped: false);
    final aliases = PersonalMerchantAliases(_db, namespace: namespace);
    final key = normalizeMerchantText(printed);
    final previous = aliases.get(key);
    final changeId = const Uuid().v4();
    _db.execute(
      'INSERT INTO v2_bulk_changes(namespace,change_id,kind,detail,created_at) VALUES(?,?,?,?,?)',
      [
        namespace,
        changeId,
        'shop_name',
        jsonEncode({
          'printedKey': key,
          'previousAlias': previous == null
              ? null
              : {
                  'name': previous.name,
                  'since': previous.since.toIso8601String(),
                },
        }),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    // From now on the name applies to SMS of every date, so it also reaches
    // the earlier ones whenever they are projected again.
    aliases.save(
      printedName: printed,
      name: name,
      since: PersonalMerchantAliases.beginning,
    );
    var done = 0;
    var stopped = false;
    for (var offset = 0; offset < ids.length; offset += chunkSize) {
      if (shouldContinue?.call() == false) {
        stopped = true;
        break;
      }
      final chunk = ids.skip(offset).take(chunkSize).toList();
      financial.batch(() {
        _db.execute('SAVEPOINT v2_bulk_shop_name');
        try {
          for (final id in chunk) {
            for (final row in _db.select(
              "SELECT id,payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND json_extract(payload,'\$.event_id')=?",
              [namespace, id],
            )) {
              final payload = (jsonDecode(row['payload'] as String) as Map)
                  .cast<String, Object?>();
              _db.execute(
                'INSERT OR IGNORE INTO v2_bulk_change_items(namespace,change_id,event_id,previous) VALUES(?,?,?,?)',
                [
                  namespace,
                  changeId,
                  id,
                  jsonEncode({
                    'rowId': row['id'],
                    'merchant_name': payload['merchant_name'],
                  }),
                ],
              );
              payload['merchant_name'] = name;
              _db.execute(
                "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
                [jsonEncode(payload), namespace, row['id']],
              );
            }
          }
          _db.execute('RELEASE v2_bulk_shop_name');
        } catch (_) {
          _db.execute('ROLLBACK TO v2_bulk_shop_name');
          _db.execute('RELEASE v2_bulk_shop_name');
          rethrow;
        }
      });
      done += chunk.length;
      onProgress?.call(done, ids.length);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    financial.notifyExternalChanges(namespace, const [
      'transactions',
      'observations',
    ]);
    return SimilarResult(changed: done, stopped: stopped, changeId: changeId);
  }

  Future<SimilarResult> _applyCategory(
    SimilarOffer offer,
    List<String> ids,
    void Function(int, int)? onProgress,
    bool Function()? shouldContinue,
  ) async {
    if (ids.isEmpty) return const SimilarResult(changed: 0, stopped: false);
    final report = await HistoryCategoryRecheck(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      from: DateTime.utc(1970),
      to: DateTime.now().toUtc().add(const Duration(days: 2)),
      accountIsCurrent: () => true,
      categoryIdBySlug: categoryIdBySlug,
      // The person's own earlier choices and confirmed readings stay as they
      // are; only what the rules chose is worked out again with the new rule.
      onlySources: automaticCategorySources,
      onlyEventIds: ids.toSet(),
    ).run(
      chunkSize: chunkSize,
      shouldContinue: shouldContinue,
      onProgress: (report) => onProgress?.call(report.processed, report.total),
    );
    return SimilarResult(
      changed: report.changed,
      stopped: !report.complete,
      awaitingSync: report.awaitingSync,
    );
  }

  /// Payment method and type change money between cards and totals, so each
  /// transaction goes through the same correction as the one the person
  /// edited, one at a time, in chunks.
  Future<SimilarResult> _applyEach(
    SimilarOffer offer,
    List<String> ids,
    void Function(int, int)? onProgress,
    bool Function()? shouldContinue,
  ) async {
    final facts = FactStore(_db, namespace: namespace);
    final kind = offer.field == SimilarField.paymentMethod
        ? CorrectionKind.wrongInstrument
        : CorrectionKind.wrongKind;
    var done = 0;
    var changed = 0;
    var stopped = false;
    for (var offset = 0; offset < ids.length; offset += chunkSize) {
      if (shouldContinue?.call() == false) {
        stopped = true;
        break;
      }
      final chunk = ids.skip(offset).take(chunkSize).toList();
      for (final id in chunk) {
        final anchor = facts.get(id);
        if (anchor == null) continue;
        try {
          controller.apply(
            items: [
              LocalReviewItem(
                id: 'similar:$id',
                kind: 'event',
                payload: {'sourceKey': anchor.sourceKey, 'eventId': id},
              ),
            ],
            kind: kind,
            corrected: {...offer.change},
            // One report for the edit the person made, not one per copy.
            confirm: true,
          );
          changed++;
        } catch (_) {
          // A transaction that cannot take the change (for example a type its
          // reading does not allow) is skipped; the rest still go through.
        }
      }
      done += chunk.length;
      onProgress?.call(done, ids.length);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return SimilarResult(changed: changed, stopped: stopped);
  }

  /// Takes back a shop-name change: the earlier alias returns and every
  /// transaction gets its earlier name back. Returns how many were restored.
  int undo(String changeId) {
    final change = _db.select(
      'SELECT kind, detail, undone_at FROM v2_bulk_changes WHERE namespace=? AND change_id=?',
      [namespace, changeId],
    );
    if (change.isEmpty ||
        change.single['kind'] != 'shop_name' ||
        change.single['undone_at'] != null) {
      return 0;
    }
    final detail =
        (jsonDecode(change.single['detail'] as String) as Map)
            .cast<String, Object?>();
    var restored = 0;
    financial.batch(() {
      _db.execute('SAVEPOINT v2_bulk_undo');
      try {
        final previous = detail['previousAlias'] as Map?;
        PersonalMerchantAliases(_db, namespace: namespace).restore(
          detail['printedKey'] as String,
          previous == null
              ? null
              : PersonalMerchantAlias(
                  printedKey: detail['printedKey'] as String,
                  name: previous['name'] as String,
                  since: DateTime.parse(previous['since'] as String),
                ),
        );
        for (final item in _db.select(
          'SELECT event_id, previous FROM v2_bulk_change_items WHERE namespace=? AND change_id=?',
          [namespace, changeId],
        )) {
          final before =
              (jsonDecode(item['previous'] as String) as Map)
                  .cast<String, Object?>();
          final rows = _db.select(
            "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=?",
            [namespace, before['rowId']],
          );
          if (rows.isEmpty) continue;
          final payload = (jsonDecode(rows.single['payload'] as String) as Map)
              .cast<String, Object?>();
          payload['merchant_name'] = before['merchant_name'];
          _db.execute(
            "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
            [jsonEncode(payload), namespace, before['rowId']],
          );
          restored++;
        }
        _db.execute(
          'UPDATE v2_bulk_changes SET undone_at=? WHERE namespace=? AND change_id=?',
          [DateTime.now().toUtc().toIso8601String(), namespace, changeId],
        );
        _db.execute('RELEASE v2_bulk_undo');
      } catch (_) {
        _db.execute('ROLLBACK TO v2_bulk_undo');
        _db.execute('RELEASE v2_bulk_undo');
        rethrow;
      }
    });
    financial.notifyExternalChanges(namespace, const [
      'transactions',
      'observations',
    ]);
    return restored;
  }
}
