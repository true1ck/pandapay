import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'commitments_repository.dart';
import 'past_bill_receipts.dart';
import 'adjustment_matcher.dart';
import 'local/app_database.dart';
import 'local/financial_store.dart' show FinancialChange;
import 'local/sms_learning_feedback.dart';
import 'local_sms_parser.dart';
import 'user_cards_repository.dart';
import 'investment_classifier.dart';
import '../features/sms_import/sms_text_hint.dart';
import 'pending_bills.dart';

enum NeedsReviewKind {
  transaction,
  commitment,
  securityOrServiceAlert,
  investmentSettlement,
  mandate,
  receipt,
  payLaterDrawdown,
}

enum AiReviewStatus { notChecked, queued, processing, checked, unavailable }

/// Task D-4 (ui-spec D4 Needs Review Queue) â€” one raw SMS the parser
/// couldn't match, kept entirely ON-DEVICE.
///
/// **Why on-device, not server-side**: `parser_failures` (api/'s existing
/// admin-triage table) is deliberately admin-only (`pandapay.is_admin()`
/// RLS) and has no `profile_id` column at all â€” checked against the live
/// migration, not just database.sql â€” plus a `redacted_shape_has_no_digits`
/// CHECK constraint that strips every digit before it's ever stored. That
/// table exists to help admins tune parser_patterns across ALL users, not
/// to give one user back their own message text â€” the two are different
/// features that happen to share a trigger event (a failed parse). The
/// existing review item stays on-device. If the server parser cannot classify
/// it, the AI fallback may send a redacted copy to the configured PandaPay AI
/// provider; local review remains available when AI is disabled or fails.
/// ui-spec D4 explicitly wants "raw text shown for context," which a
/// digit-stripped admin record structurally cannot provide. Rather than
/// requesting a schema change to a table designed for anonymized telemetry
/// (a real, separate decision â€” flagged, not made unilaterally here), this
/// keeps the raw SMS exactly where it already lives today: the device that
/// received it. The separate, explicit AI fallback uploads only after the
/// normal financial-message filter and removes sensitive identifiers on the
/// server before calling PandaPay AI.
class NeedsReviewItem {
  final String id;
  final String sender;
  final String body;
  final String? reason;
  final DateTime receivedAt;
  final NeedsReviewKind kind;
  final List<Map<String, dynamic>>? aiSuggestions;
  final AiReviewStatus aiStatus;
  final String? aiTopic;
  final Map<String, dynamic>? aiDecision;
  final String? aiSummary;
  final String? aiFailureReason;

  const NeedsReviewItem({
    required this.id,
    required this.sender,
    required this.body,
    this.reason,
    required this.receivedAt,
    this.kind = NeedsReviewKind.transaction,
    this.aiSuggestions,
    this.aiStatus = AiReviewStatus.notChecked,
    this.aiTopic,
    this.aiDecision,
    this.aiSummary,
    this.aiFailureReason,
  });

  NeedsReviewItem copyWith({
    NeedsReviewKind? kind,
    List<Map<String, dynamic>>? aiSuggestions,
    AiReviewStatus? aiStatus,
    String? aiTopic,
    Map<String, dynamic>? aiDecision,
    String? aiSummary,
    String? aiFailureReason,
    bool clearAiFailureReason = false,
  }) => NeedsReviewItem(
    id: id,
    sender: sender,
    body: body,
    reason: reason,
    receivedAt: receivedAt,
    kind: kind ?? this.kind,
    aiSuggestions: aiSuggestions ?? this.aiSuggestions,
    aiStatus: aiStatus ?? this.aiStatus,
    aiTopic: aiTopic ?? this.aiTopic,
    aiDecision: aiDecision ?? this.aiDecision,
    aiSummary: aiSummary ?? this.aiSummary,
    aiFailureReason: clearAiFailureReason
        ? null
        : aiFailureReason ?? this.aiFailureReason,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender': sender,
    'body': body,
    'reason': reason,
    'receivedAt': receivedAt.toIso8601String(),
    'kind': kind.name,
    if (aiSuggestions != null) 'aiSuggestions': aiSuggestions,
    'aiStatus': aiStatus.name,
    if (aiTopic != null) 'aiTopic': aiTopic,
    if (aiDecision != null) 'aiDecision': aiDecision,
    if (aiSummary != null) 'aiSummary': aiSummary,
    if (aiFailureReason != null) 'aiFailureReason': aiFailureReason,
  };

  factory NeedsReviewItem.fromJson(Map<String, dynamic> json) {
    final rawSuggestions = json['aiSuggestions'];
    return NeedsReviewItem(
      id: json['id'] as String,
      sender: json['sender'] as String,
      body: json['body'] as String,
      reason: json['reason'] as String?,
      receivedAt: DateTime.parse(json['receivedAt'] as String),
      kind: NeedsReviewKind.values.firstWhere(
        (kind) => kind.name == json['kind'],
        orElse: () => NeedsReviewKind.transaction,
      ),
      aiSuggestions: rawSuggestions is List
          ? rawSuggestions
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : null,
      aiStatus: AiReviewStatus.values.firstWhere(
        (status) => status.name == json['aiStatus'],
        orElse: () => AiReviewStatus.notChecked,
      ),
      aiTopic: json['aiTopic'] as String?,
      aiDecision: json['aiDecision'] is Map
          ? Map<String, dynamic>.from(json['aiDecision'] as Map)
          : null,
      aiSummary: json['aiSummary'] as String?,
      aiFailureReason: json['aiFailureReason'] as String?,
    );
  }
}

const _needsReviewKey = 'pandapay_app.needs_review_queue_v1';

bool _capturesReviewableFinancial(NeedsReviewItem item) {
  if (LocalSmsParser.isActionableInsuranceRenewal(item.body)) return true;

  final bodyLower = item.body.toLowerCase();
  final hasAmount = RegExp(
    r'(?:₹|\brs\.?|\binr|\$|usd|eur|gbp)\s*[:.]?\s*[\d,]+|\b[\d,]+(?:\.\d{1,2})?\s*(?:₹|rs\.?|inr|\$|usd|eur|gbp)\b',
  ).hasMatch(bodyLower);
  final hasBalanceSnapshot = RegExp(
    r'\b(?:available|current|closing|avl|avail)\s+(?:bal(?:ance)?|limit)\b[\s\S]{0,60}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?|\b(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?[\s\S]{0,40}\b(?:available|current|closing|avl|avail)\s+(?:bal(?:ance)?|limit)\b|\bcredit\s+limit\b[\s\S]{0,30}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?',
  ).hasMatch(bodyLower);
  final hasBillOrMandate =
      LocalSmsParser.isAutoPayNotice(item.body) ||
      RegExp(
        r'\b(?:auto[-\s]?pay|e[-\s]?mandate|mandate|auto[-\s]?debit|sip\b|standing\s+instruction)\b',
      ).hasMatch(bodyLower) ||
      RegExp(
        r'\b(?:payment|amount|minimum|total|premium)\s+due\b|\bdue\s+(?:date|on|by)\b|\b(?:statement|bill|premium)\b[\s\S]{0,100}\b(?:generated|ready|available|due)\b|\bbill\s+generated\b|\be-statement\s+generated\b',
      ).hasMatch(bodyLower);
  final hasMovement = RegExp(
    r'\b(?:debited|credited|spent|paid|charged|transferred|withdrawn|deposited|refunded|reversed|deducted)\b',
    caseSensitive: false,
  ).hasMatch(bodyLower);

  if (!hasAmount && !hasBalanceSnapshot && !hasBillOrMandate && !hasMovement) {
    return false;
  }
  if (capturesFinancialSms(item.body, sender: item.sender)) return true;
  return switch (NeedsReviewRepository.resolveItemKind(item).kind) {
    NeedsReviewKind.investmentSettlement ||
    NeedsReviewKind.mandate ||
    NeedsReviewKind.receipt ||
    NeedsReviewKind.payLaterDrawdown => true,
    _ => false,
  };
}

/// Synchronous capture path used by the local SMS parser, which deliberately
/// remains synchronous so foreground/background capture share one transaction.
/// The stable SMS id makes this insert idempotent.
void addNeedsReviewSync(
  AppDatabase database,
  String namespace,
  NeedsReviewItem item, {
  List<TransactionEntry>? existingTransactions,
}) {
  if (NeedsReviewRepository.isNoiseItem(item)) return;
  if (!_capturesReviewableFinancial(item)) return;
  if (isInvestmentFolioAllotment(item.body) &&
      NeedsReviewRepository.hasMatchingInvestmentTransactionSync(
        database,
        namespace,
        item,
        transactions: existingTransactions,
      )) {
    return;
  }
  if (NeedsReviewRepository.isMerchantReceiptOrEbill(item.body)) {
    final linkedId = NeedsReviewRepository.matchingSpendTransactionIdSync(
      database,
      namespace,
      item,
      transactions: existingTransactions,
    );
    if (linkedId != null) {
      PastBillReceiptRepository(database, namespace: namespace).archiveReceipt(
        id: item.id,
        sender: item.sender,
        body: item.body,
        receivedAt: item.receivedAt,
        linkedTransactionId: linkedId,
        status: PastBillReceiptStatus.paidLinked,
      );
      return;
    }
  }
  if (NeedsReviewRepository.isRefundOrReversal(item.body) &&
      NeedsReviewRepository.hasMatchingRefundDebitSync(
        database,
        namespace,
        item,
        transactions: existingTransactions,
      )) {
    return;
  }
  final parsed = LocalSmsParser.parse(
    body: item.body,
    sender: item.sender,
    receivedAt: item.receivedAt,
    namespace: namespace,
    // Learned user categories are a capture-level hint, not a new grammar:
    // the same rule table SmsImportStore passes into every parse.
    userCategoryRules: SmsLearningFeedback(
      database,
      namespace: namespace,
    ).loadRulesSync(),
  );
  if (NeedsReviewRepository.isMonthOnlyPremiumNotice(parsed)) {
    if (NeedsReviewRepository.isPastMonthOnlyPremiumNotice(parsed, item.body)) {
      NeedsReviewRepository._archiveMonthOnlyPremiumSync(
        database,
        namespace,
        parsed!,
        item,
      );
    }
    return;
  }
  if (!NeedsReviewRepository.isPayLaterDrawdown(
        item.body,
        sender: item.sender,
      ) &&
      parsed != null &&
      parsed.eventType == LocalSmsEventType.bill &&
      parsed.cardLast4 == null &&
      parsed.dueDate != null) {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    if (!parsed.dueDate!.isBefore(startOfToday)) {
      NeedsReviewRepository._persistResolvedCommitmentSync(
        database,
        namespace,
        parsed,
        item,
      );
      NeedsReviewRepository._persistResolvedBillObservationSync(
        database,
        namespace,
        parsed,
        item,
      );
      return;
    } else {
      PastBillReceiptRepository(database, namespace: namespace).archiveBill(
        id: item.id,
        sender: item.sender,
        merchant: parsed.billerName ?? item.sender,
        amount: parsed.amountDue,
        receivedAt: item.receivedAt,
        dueDate: parsed.dueDate,
        cardLast4: parsed.cardLast4,
        accountLast4: parsed.accountLast4,
        body: item.body,
        status: PastBillReceiptStatus.historicalUnpaid,
      );
      NeedsReviewRepository._persistResolvedBillObservationSync(
        database,
        namespace,
        parsed,
        item,
      );
      return;
    }
  }
  final resolved = NeedsReviewRepository.resolveItemKind(item);
  database.db.execute(
    'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
  );
  final existingRows = database.db.select(
    'SELECT payload FROM local_needs_review WHERE namespace = ?',
    [namespace],
  );
  final normalizedSender = resolved.sender.trim().toLowerCase();
  final normalizedBody = NeedsReviewRepository.normalizeBody(resolved.body);
  for (final row in existingRows) {
    try {
      final payload = row['payload'] as String?;
      if (payload == null) continue;
      final existing = NeedsReviewItem.fromJson(
        jsonDecode(payload) as Map<String, dynamic>,
      );
      if (existing.id == resolved.id) {
        return;
      }
      final sameSender =
          existing.sender.trim().toLowerCase() == normalizedSender;
      final sameBody =
          NeedsReviewRepository.normalizeBody(existing.body) == normalizedBody;
      final closeInTime =
          existing.receivedAt.difference(resolved.receivedAt).abs() <=
          const Duration(minutes: 5);
      if (sameSender && sameBody && closeInTime) {
        return;
      }
    } catch (_) {}
  }
  database.db.execute(
    'INSERT OR REPLACE INTO local_needs_review VALUES (?,?,?)',
    [namespace, resolved.id, jsonEncode(resolved.toJson())],
  );
  NeedsReviewRepository._notify(database, namespace, 'needs_review');
}

/// Plain on-device store, same SharedPreferences mechanism
/// dueDateRemindersProvider (providers.dart) already uses for a similar
/// "no server round-trip needed, this is purely local" case.
class NeedsReviewRepository {
  static final _changes = Expando<StreamController<FinancialChange>>();

  static Stream<FinancialChange> changesFor(AppDatabase database) =>
      (_changes[database] ??= StreamController<FinancialChange>.broadcast())
          .stream;

  static void _notify(AppDatabase database, String namespace, String entity) {
    _changes[database]?.add(FinancialChange(namespace, entity));
  }

  final String namespace;
  final Future<AppDatabase> Function()? loadDatabase;
  final List<TransactionEntry>? existingTransactions;
  Future<AppDatabase>? _databaseFuture;
  NeedsReviewRepository({
    this.namespace = 'legacy',
    this.loadDatabase,
    this.existingTransactions,
  });
  Future<AppDatabase> _database() async {
    final pending = _databaseFuture ??= _initializeDatabase();
    try {
      return await pending;
    } catch (_) {
      if (identical(_databaseFuture, pending)) _databaseFuture = null;
      rethrow;
    }
  }

  Future<AppDatabase> _initializeDatabase() async {
    final db = await loadDatabase!();
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getStringList(_needsReviewKey);
    if (old != null && old.isNotEmpty) {
      final corrupt = <String>[];
      final migrated = <NeedsReviewItem>[];
      for (var i = 0; i < old.length; i++) {
        if (i > 0 && i % 64 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        try {
          migrated.add(
            NeedsReviewItem.fromJson(
              jsonDecode(old[i]) as Map<String, dynamic>,
            ),
          );
        } catch (_) {
          corrupt.add(old[i]);
        }
      }
      db.db.execute('SAVEPOINT migrate_review');
      try {
        for (final item in migrated) {
          db.db.execute(
            "INSERT OR IGNORE INTO local_needs_review VALUES ('legacy',?,?)",
            [item.id, jsonEncode(item.toJson())],
          );
        }
        db.db.execute('RELEASE SAVEPOINT migrate_review');
      } catch (_) {
        db.db.execute('ROLLBACK TO SAVEPOINT migrate_review');
        db.db.execute('RELEASE SAVEPOINT migrate_review');
        rethrow;
      }
      if (corrupt.isEmpty) {
        await prefs.remove(_needsReviewKey);
      } else {
        await prefs.setStringList(_needsReviewKey, corrupt);
      }
    }
    final lastPurgedVersion =
        prefs.getInt('pandapay.needs_review_noise_version') ?? 0;
    if (lastPurgedVersion < LocalSmsParser.version) {
      final rows = db.db.select(
        'SELECT id, payload FROM local_needs_review WHERE namespace=?',
        [namespace],
      );
      final noiseIds = <String>[];
      for (final r in rows) {
        try {
          final item = NeedsReviewItem.fromJson(
            jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          );
          if (_isNoiseOrStale(item)) {
            noiseIds.add(item.id);
          }
        } catch (_) {}
      }
      if (noiseIds.isNotEmpty) {
        db.db.execute('SAVEPOINT purge_startup_noise');
        try {
          for (final id in noiseIds) {
            db.db.execute(
              'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
              [namespace, id],
            );
          }
          db.db.execute('RELEASE SAVEPOINT purge_startup_noise');
        } catch (_) {
          db.db.execute('ROLLBACK TO SAVEPOINT purge_startup_noise');
          db.db.execute('RELEASE SAVEPOINT purge_startup_noise');
        }
      }
      await prefs.setInt(
        'pandapay.needs_review_noise_version',
        LocalSmsParser.version,
      );
    }
    return db;
  }

  Future<int> count() async {
    if (loadDatabase != null) {
      final db = await _database();
      final rows = db.db.select(
        'SELECT COUNT(*) AS count FROM local_needs_review WHERE namespace=?',
        [namespace],
      );
      return (rows.single['count'] as int?) ?? 0;
    }
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_needsReviewKey) ?? const []).length;
  }

  Future<List<NeedsReviewItem>> fetchAll({
    List<TransactionEntry>? transactions,
  }) async {
    final txns = transactions ?? existingTransactions;
    if (loadDatabase != null) {
      final db = await _database();
      Future<List<TransactionEntry>>? transactionSnapshot;
      Future<List<TransactionEntry>> allTransactions() =>
          transactionSnapshot ??= _loadTransactionSnapshot(db, namespace, txns);
      Map<String, String>? cardLast4Snapshot;
      Map<String, String> allCardLast4() =>
          cardLast4Snapshot ??= _loadCardLast4Sync(db, namespace);
      final rows = db.db.select(
        'SELECT id, payload FROM local_needs_review WHERE namespace=?',
        [namespace],
      );
      final items = <NeedsReviewItem>[];
      final toUpdate = <NeedsReviewItem>[];
      final corruptIds = <String>[];
      var readCount = 0;
      for (final r in rows) {
        if (++readCount % 32 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        try {
          final raw = r['payload'] as String;
          final original = NeedsReviewItem.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
          final resolved = resolveItemKind(original);
          if (resolved.kind != original.kind) {
            toUpdate.add(resolved);
          }
          items.add(resolved);
        } catch (_) {
          final id = r['id'] as String?;
          if (id != null) corruptIds.add(id);
        }
      }
      if (corruptIds.isNotEmpty) {
        await removeAll(corruptIds);
      }
      if (toUpdate.isNotEmpty) {
        db.db.execute('SAVEPOINT update_resolved_kinds');
        try {
          for (final item in toUpdate) {
            db.db.execute(
              'UPDATE local_needs_review SET payload=? WHERE namespace=? AND id=?',
              [jsonEncode(item.toJson()), namespace, item.id],
            );
          }
          db.db.execute('RELEASE SAVEPOINT update_resolved_kinds');
          _notify(db, namespace, 'needs_review');
        } catch (_) {
          db.db.execute('ROLLBACK TO SAVEPOINT update_resolved_kinds');
          db.db.execute('RELEASE SAVEPOINT update_resolved_kinds');
        }
      }
      final noise = items
          .where(_isNoiseOrStale)
          .map((item) => item.id)
          .toList();
      if (noise.isNotEmpty) await removeAll(noise);
      final nonNoise = items.where((item) => !_isNoiseOrStale(item)).toList();
      final kept = <NeedsReviewItem>[];
      final toRemove = <String>[];
      final now = DateTime.now();
      var processed = 0;
      for (final item in nonNoise) {
        if (++processed % 8 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        if ((item.aiSuggestions != null && item.aiSuggestions!.isNotEmpty) ||
            (item.aiSummary != null && item.aiSummary!.trim().isNotEmpty)) {
          kept.add(item);
          continue;
        }
        final parsed = LocalSmsParser.parse(
          body: item.body,
          sender: item.sender,
          receivedAt: item.receivedAt,
          namespace: namespace,
        );
        if (item.kind == NeedsReviewKind.payLaterDrawdown) {
          kept.add(item);
          continue;
        }
        if (item.kind != NeedsReviewKind.transaction &&
            item.kind != NeedsReviewKind.mandate &&
            item.kind != NeedsReviewKind.receipt) {
          if (parsed != null &&
              parsed.eventType == LocalSmsEventType.bill &&
              parsed.dueDate != null) {
            // Bill obligation with due date is resolvable
          } else if (parsed?.reasonCodes.contains(
                'next_premium_due_month_only',
              ) !=
              true) {
            kept.add(item);
            continue;
          }
        }
        final needsTransactions =
            isInvestmentFolioAllotment(item.body) ||
            isMerchantReceiptOrEbill(item.body) ||
            isRefundOrReversal(item.body) ||
            (parsed?.eventType == LocalSmsEventType.bill &&
                parsed?.dueDate != null &&
                parsed!.dueDate!.isBefore(now));
        final matchTransactions = needsTransactions
            ? await allTransactions()
            : const <TransactionEntry>[];
        // Snapshot loading yields. Do not resolve a message dismissed or edited
        // while that snapshot was being read.
        final live = db.db.select(
          'SELECT payload FROM local_needs_review WHERE namespace=? AND id=?',
          [namespace, item.id],
        );
        if (live.isEmpty ||
            jsonEncode(
                  NeedsReviewItem.fromJson(
                    jsonDecode(live.single['payload'] as String)
                        as Map<String, dynamic>,
                  ).toJson(),
                ) !=
                jsonEncode(item.toJson())) {
          continue;
        }
        if (isInvestmentFolioAllotment(item.body)) {
          if (_hasMatchingInvestmentTransaction(
            item,
            database: db,
            transactions: matchTransactions,
            transactionsAreComplete: true,
          )) {
            toRemove.add(item.id);
            continue;
          }
        }
        if (isMerchantReceiptOrEbill(item.body)) {
          final linkedId = matchingSpendTransactionIdSync(
            db,
            namespace,
            item,
            transactions: matchTransactions,
            transactionsAreComplete: true,
          );
          if (linkedId != null) {
            PastBillReceiptRepository(db, namespace: namespace).archiveReceipt(
              id: item.id,
              sender: item.sender,
              body: item.body,
              receivedAt: item.receivedAt,
              linkedTransactionId: linkedId,
              status: PastBillReceiptStatus.paidLinked,
            );
            toRemove.add(item.id);
            continue;
          }
          if (now.difference(item.receivedAt).abs() >
              const Duration(days: 30)) {
            PastBillReceiptRepository(db, namespace: namespace).archiveReceipt(
              id: item.id,
              sender: item.sender,
              body: item.body,
              receivedAt: item.receivedAt,
              status: PastBillReceiptStatus.needsConfirmation,
            );
            toRemove.add(item.id);
            continue;
          }
        }

        if (isRefundOrReversal(item.body)) {
          if (_hasMatchingRefundDebit(
            item,
            database: db,
            transactions: matchTransactions,
            transactionsAreComplete: true,
          )) {
            toRemove.add(item.id);
            continue;
          }
        }

        if (parsed != null) {
          if (isMonthOnlyPremiumNotice(parsed)) {
            if (isPastMonthOnlyPremiumNotice(parsed, item.body, now: now)) {
              _archiveMonthOnlyPremiumSync(db, namespace, parsed, item);
            }
            toRemove.add(item.id);
            continue;
          }
          final isCardBill =
              parsed.eventType == LocalSmsEventType.bill &&
              parsed.cardLast4 != null &&
              parsed.disposition != LocalSmsDisposition.localCommitment &&
              !parsed.reasonCodes.contains('mandate_notice');
          final isMonthOnlyPremium = parsed.reasonCodes.contains(
            'next_premium_due_month_only',
          );
          final isMandateOrAutopay =
              !isMonthOnlyPremium &&
              !isCardBill &&
              (parsed.isAutopay ||
                  parsed.disposition == LocalSmsDisposition.localCommitment ||
                  parsed.reasonCodes.contains('mandate_notice') ||
                  parsed.reasonCodes.contains('commitment_detected') ||
                  item.kind == NeedsReviewKind.mandate ||
                  isMandateReview(item.body));
          if (isMandateOrAutopay) {
            _persistResolvedCommitmentSync(db, namespace, parsed, item);
            toRemove.add(item.id);
            continue;
          }

          if (parsed.disposition == LocalSmsDisposition.localIgnore ||
              LocalSmsParser.isNonTransactionNoise(item.sender, item.body) ||
              isSecurityOrServiceAlert(item.body)) {
            toRemove.add(item.id);
            continue;
          }

          if (parsed.eventType == LocalSmsEventType.bill &&
              (parsed.cardLast4 != null || parsed.dueDate != null)) {
            final due = parsed.dueDate;
            final now = DateTime.now();
            final dueDay = due == null
                ? null
                : DateTime(due.year, due.month, due.day);
            final today = DateTime(now.year, now.month, now.day);
            if (due != null && dueDay != null && dueDay.isBefore(today)) {
              final matchWindowStart = due.subtract(
                Duration(days: parsed.cardLast4 == null ? 3 : 30),
              );
              final matchWindowEnd = due.add(const Duration(days: 10));
              final windowTransactions = matchTransactions
                  .where(
                    (transaction) =>
                        !transaction.occurredAt.isBefore(matchWindowStart) &&
                        !transaction.occurredAt.isAfter(matchWindowEnd),
                  )
                  .toList(growable: false);
              final billRows = deriveSmsBillRows(
                observations: [
                  {
                    'event_type': parsed.eventType.wireValue,
                    'received_at': item.receivedAt.toIso8601String(),
                    'biller_name': parsed.billerName,
                    'card_last4': parsed.cardLast4,
                    'account_last4': parsed.accountLast4,
                    'amount_due_paise': parsed.amountDue?.paise,
                    'minimum_due_paise': parsed.minimumDue?.paise,
                    'due_date': parsed.dueDate?.toIso8601String(),
                    'is_autopay': parsed.isAutopay,
                  },
                ],
                transactions: windowTransactions,
                cardsLast4ById: allCardLast4(),
                now: now,
                lookbackDays: 36525,
              );
              final matched =
                  billRows.isEmpty ||
                      billRows.single.state != SmsBillState.linked ||
                      parsed.amountDue == null
                  ? null
                  : billRows.single;
              PastBillReceiptRepository(db, namespace: namespace).archiveBill(
                id: item.id,
                sender: item.sender,
                merchant: parsed.billerName ?? item.sender,
                amount: parsed.amountDue,
                receivedAt: item.receivedAt,
                dueDate: due,
                cardLast4: parsed.cardLast4,
                accountLast4: parsed.accountLast4,
                body: item.body,
                status: matched == null
                    ? PastBillReceiptStatus.historicalUnpaid
                    : PastBillReceiptStatus.paidLinked,
                linkedTransactionId: matched?.linkedTxnId,
              );
            } else if (due != null &&
                dueDay != null &&
                !dueDay.isBefore(today) &&
                parsed.cardLast4 == null) {
              _persistResolvedCommitmentSync(db, namespace, parsed, item);
            }
            _persistResolvedBillObservationSync(db, namespace, parsed, item);
            toRemove.add(item.id);
            continue;
          }

          if (parsed.disposition == LocalSmsDisposition.sync &&
              parsed.transaction != null) {
            final isWallet =
                parsed.transaction!.instrument == TxnInstrument.wallet;
            final cardMatches =
                parsed.cardLast4 != null &&
                _matchesUserCardSync(db, namespace, parsed.cardLast4!);
            final isNonCard = parsed.cardLast4 == null;
            if (isWallet || cardMatches || isNonCard) {
              _persistResolvedTransactionSync(
                db,
                namespace,
                parsed.transaction!,
                item.id,
              );
              toRemove.add(item.id);
              continue;
            }
          }
        }

        kept.add(item);
      }
      if (toRemove.isNotEmpty) {
        await removeAll(toRemove);
      }
      return kept..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final items = raw
        .map(
          (s) => resolveItemKind(
            NeedsReviewItem.fromJson(jsonDecode(s) as Map<String, dynamic>),
          ),
        )
        .toList();
    final noise = items.where(_isNoiseOrStale).map((item) => item.id).toList();
    if (noise.isNotEmpty) await removeAll(noise);
    final nonNoise = items.where((item) => !_isNoiseOrStale(item)).toList();
    final kept = <NeedsReviewItem>[];
    final toRemove = <String>[];
    final now = DateTime.now();
    for (final item in nonNoise) {
      if ((item.aiSuggestions != null && item.aiSuggestions!.isNotEmpty) ||
          (item.aiSummary != null && item.aiSummary!.trim().isNotEmpty)) {
        kept.add(item);
        continue;
      }
      if (item.kind == NeedsReviewKind.payLaterDrawdown) {
        kept.add(item);
        continue;
      }
      if (item.kind != NeedsReviewKind.transaction &&
          item.kind != NeedsReviewKind.mandate &&
          item.kind != NeedsReviewKind.receipt) {
        kept.add(item);
        continue;
      }
      if (isMerchantReceiptOrEbill(item.body)) {
        if (_hasMatchingSpendTransaction(item, transactions: txns)) {
          toRemove.add(item.id);
          continue;
        }
        if (now.difference(item.receivedAt).abs() > const Duration(days: 30)) {
          toRemove.add(item.id);
          continue;
        }
      }
      if (isRefundOrReversal(item.body)) {
        if (_hasMatchingRefundDebit(item, transactions: txns)) {
          toRemove.add(item.id);
          continue;
        }
      }
      final parsed = LocalSmsParser.parse(
        body: item.body,
        sender: item.sender,
        receivedAt: item.receivedAt,
        namespace: namespace,
      );
      if (parsed != null) {
        final isCardBill =
            parsed.eventType == LocalSmsEventType.bill &&
            parsed.cardLast4 != null &&
            parsed.disposition != LocalSmsDisposition.localCommitment &&
            !parsed.reasonCodes.contains('mandate_notice');
        final isMandateOrAutopay =
            !isCardBill &&
            (parsed.isAutopay ||
                parsed.disposition == LocalSmsDisposition.localCommitment ||
                parsed.reasonCodes.contains('mandate_notice') ||
                parsed.reasonCodes.contains('commitment_detected') ||
                item.kind == NeedsReviewKind.mandate ||
                isMandateReview(item.body));
        if (isMandateOrAutopay) {
          toRemove.add(item.id);
          continue;
        }

        if (parsed.disposition == LocalSmsDisposition.localIgnore ||
            LocalSmsParser.isNonTransactionNoise(item.sender, item.body) ||
            isSecurityOrServiceAlert(item.body)) {
          toRemove.add(item.id);
          continue;
        }
        if (parsed.eventType == LocalSmsEventType.bill &&
            (parsed.cardLast4 != null || parsed.dueDate != null)) {
          toRemove.add(item.id);
          continue;
        }
        if (parsed.disposition == LocalSmsDisposition.sync &&
            parsed.transaction != null &&
            parsed.transaction!.entryKind == TxnEntryKind.spend) {
          final isWallet =
              parsed.transaction!.instrument == TxnInstrument.wallet;
          final isNonCard = parsed.cardLast4 == null;
          if (isWallet || isNonCard) {
            toRemove.add(item.id);
            continue;
          }
        }
      }
      kept.add(item);
    }
    if (toRemove.isNotEmpty) {
      await removeAll(toRemove);
    }
    return kept..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  }

  static bool isSecurityOrServiceAlert(String body) {
    if (LocalSmsParser.isActionableInsuranceRenewal(body)) return false;
    final text = body.toLowerCase();
    return RegExp(
      r'\b(?:transaction\s+check\s+alert|check\s+alert|confirm\s+(?:the\s+)?(?:following\s+)?txn|call\s+forwarding\b|sim\s+swap|service\s+alert|fraud\s+alert|suspicious\s+activity|'
      r'modification\s+success!?|card\s+usage\s+settings?|card\s+(?:usage\s+)?settings?\s+(?:for|modified|updated)|card\s+controls?\s+(?:modified|updated)|card\s+usage\s+(?:limits?|controls?|preferences?)|usage\s+(?:&|and)\s+transaction\s+limit|transaction\s+limits?\s+options?|limits?\s+(?:have|has)\s+been\s+updated|usage\s+options?\s+(?:have|has)\s+been\s+updated|'
      r'(?:daily|domestic|international|atm|pos|online)?\s*(?:transaction|usage)?\s*limits?\s*(?:of\s+(?:₹|rs\.?|inr)?\s*[\d,]+)?\s*(?:has\s+been|is)?\s*(?:set|modified|updated|changed|configured))\b|'
      r'\b(?:positive\s+pay\s+(?:details|system|alert)|aadhaar\s+(?:linked|seeded)|npci\s+mapper)\b|'
      r'\b(?:will\s+remain\s+open\s+and\s+fully\s+operational|available\s+at\s+our\s+branches\s+during\s+normal\s+working\s+hours|submission\s+of\s+positive\s+pay\s+details\s+is\s+mandatory)\b|'
      r'\bdone\s+\d+\s+out\s+of\s+\d+\s+free\s+transactions\s+at\s+[\w\s]+atms\b|'
      r'\b(?:cdsl|nsdl)\s*:\s*(?:debit|credit)\s+in\s+a/c\b[\s\S]{0,40}\b(?:etf|bees|shares?|units?|mf)\b|'
      r"\b(?:track\s+it\s+using\s+this\s+ticket\s+id|ticket\s+id\s*:\s*\d+\s+on\s+the\s+help\s+section|we're\s+on\s+it\s+and\s+will\s+get\s+back\s+to\s+you\s+in\s+\d+[-–]\d+\s+hours)\b|"
      r'\benable\s+online,\s+international\s+(?:and|&)\s+contactless\s+transactions\b|'
      r'\byour\s+ekyc\s+has\s+been\s+successfully\s+completed\b|'
      r'\b(?:scheduled\s+maintenance|maintenance\s+activity|system\s+maintenance|routine\s+maintenance|undergoing\s+maintenance|due\s+to\s+scheduled\s+maintenance)\b|'
      r'\b(?:bse\s+trade\s+confirmation|welcome\s+to\s+nse,\s+you\s+have\s+been\s+registered\b|registered\s+with\s+[\w\s]+in\s+segment(?:\(s\))?|registered\s+with\s+[\w\s]+in\s+segment\(s\))\b|'
      r'\b(?:puc\s+certificate\s+for\s+vehicle\b|your\s+itr\s+for\s+ay\b[\s\S]{0,30}\bawaits\s+at\s+the\s+e[- ]?filing\s+portal)\b|'
      r'\b(?:(?:last\s+chance\s*:?\s*)?renew\s+(?:your\s+)?expired\b|(?:(?:car|motor|two[ -]?wheeler|vehicle|bike|health)\s+)?insurance\s+will\s+expire\s+on\b|will\s+expire\s+on\b[\s\S]{0,80}\b(?:premium|insurance|renew|policy|visit|starts?\s+(?:just\s+)?(?:at\s+)?(?:rs\.?|inr)|instant\s+renewal)\b|\+\s*taxes\*?)\b|'
      r'\b(?:claim\s+your\s+[\w\s]+(?:insta\s+)?emi\s+card|avail\s+(?:credit\s+)?card\s+with\s+limit|eligible\s+for\s+(?:a\s+)?(?:[\w\s]{0,20}\s+)?loan\b|use\s+card\s+loan\s+limit\s+of\b|complete\s+your\s+[\w\s]+emi\s+card\s+application|pre[-\s]?approved\s+loan)\b|'
      r'\b(?:is\s+still\s+not\s+renewed|renew\s+to\s+avoid\s+unexpected\s+expenses|renew\s+before\s+expiry\s+on|registration\s+for\s+(?:fingerprint|face\s+id|biometric)|your\s+request\s+for\s+renewal\s+has\s+been\s+received\s+&\s+processed)\b|'
      r'\b(?:pledge(?:d)?|unpledge(?:d)?|margin\s+pledge)\b|'
      r'\b(?:kra\b[\s\S]{0,60}\b(?:address|update|kyc)|(?:address|kyc|update)\b[\s\S]{0,60}\bkra|(?:cvy|cvl|ndml|cams|karvy)\s*kra)\b|'
      r'\b(?:(?:new\s+)?device\s+(?:registration|registered)|registration\s+(?:for|of)\s+(?:new\s+)?device|registered\s+(?:a\s+)?new\s+device|you(?:\x27ve|\s+have)\s+registered\b[\s\S]{0,60}\bon\s+your\b|registered\b[\s\S]{0,40}\bapp\s+on\s+your\b)\b|'
      r'\b(?:(?:successfully\s+)?(?:set|reset|changed|updated)\s+(?:an?\s+)?mpin|mpin\s+(?:has\s+been\s+)?(?:set|reset|changed|updated)|set\s+(?:an?\s+)?mpin)\b|'
      r'\b(?:(?:cdsl|nsdl)\b[\s\S]{0,40}\be[- ]?voting\b|e[- ]?voting\b[\s\S]{0,40}\b(?:cdsl|nsdl|agm|egm|resolution|ballot)|cast\s+your\s+vote\s+(?:on|via)\s+(?:cdsl|nsdl|evoting))\b|'
      r'\b(?:ckyc\b[\s\S]{0,60}\b(?:registry|fetch|fetched|downloaded|accessed|record|reference|search|details)|central\s+kyc\s+registry|ckyc\s+number)\b|'
      r'\b(?:indialends?|pre[-\s]?approved\s+(?:personal\s+)?loan)\b|'
      r'\b(?:expired\s+insurance|insurance\s+(?:has\s+)?expired|policy\s+(?:has\s+)?expired)\b|'
      r'\b(?:use\s+coupon|apply\s+coupon|coupon\s+code|discount\s+coupon|promotional\s+coupon|coupons?|voucher\s+code)\b|'
      r'\b(?:(?:order|item|package|shipment|consignment|courier)\s+(?:has\s+been\s+)?dispatched|has\s+been\s+dispatched|dispatched\s+(?:via|through|with))\b',
    ).hasMatch(text);
  }

  static bool isInvestmentSettlement(String body) {
    final text = body.toLowerCase();
    return RegExp(
      r'\b(?:kotak\s+neo|demat|settlement\s+payout|running\s+a/?c\s+settlement|'
      r'asba\b|'
      r'ipo\s+application|'
      r'funds?\s+(?:blocked|lien)\s+(?:for|towards)\s+(?:asba|ipo)\b|'
      r'funds?\s+of\s+(?:rs\.?|inr)?\s*[\d,.]+\s+(?:blocked|lien)\s+(?:for|towards)\s+(?:asba|ipo)\b|'
      r'lien\s+(?:of\s+(?:rs\.?|inr)?\s*[\d,.]+|marked|blocked|created)\b|'
      r'lien\b[\s\S]{0,40}\b(?:asba|ipo)\b)\b',
    ).hasMatch(text);
  }

  static bool isMandateReview(String body) {
    final text = body.toLowerCase();
    final hasMandateMarker = RegExp(
      r'\b(?:auto[-\s]?pay|e[-\s]?mandate|standing\s+instruction|sihub)\b',
    ).hasMatch(text);
    if (!hasMandateMarker) return false;

    final isCardBillPayment = RegExp(
      r'\b(?:credit\s+card\s+bill|towards\s+(?:your\s+)?credit\s+card|for\s+(?:your\s+)?credit\s+card\s+bill)\b',
    ).hasMatch(text);
    if (isCardBillPayment) return false;

    final hasMerchantOrLimit = RegExp(
      r'\b(?:merchant|payee|biller|max\s+limit|maximum\s+limit|created\s+towards|subscription\s+to|initiated\s+by)\b',
    ).hasMatch(text);
    if (hasMerchantOrLimit) return true;

    if (RegExp(r'\bcredit\s+card\b').hasMatch(text)) return false;

    return true;
  }

  static bool isPayLaterDrawdown(String body, {String? sender}) {
    final text = body.toLowerCase();
    final cleanSender = sender?.toLowerCase() ?? '';

    final senderMatches = RegExp(
      r'\b(?:axio|lazypay|lazypy|simpl|postpe)\b|axio|lazypay|lazypy|simpl|postpe',
      caseSensitive: false,
    ).hasMatch(cleanSender);

    if (senderMatches) {
      final hasDrawdownSignal = RegExp(
        r'\b(?:amazon\s+)?pay\s+later\b|'
        r'\b(?:availing|availed)\s+(?:amazon\s+)?pay\s+later\b|'
        r'\b(?:availing|availed)\s+credit\s+of\b|'
        r'\bpay\s+later\s+credit\b|'
        r'\bpay\s+later(?:\s+[\w\d]+)?\s+(?:a\/c|account)\b|'
        r'\b(?:lazypay|simpl|postpe)\b|'
        r'\b(?:credit|drawdown|limit|repay(?:ment)?|emi|spent|paid|purchase|order|txn|transaction|availed|availing)\b',
        caseSensitive: false,
      ).hasMatch(text);
      if (hasDrawdownSignal) return true;
    }

    return RegExp(
      r'\b(?:(?:amazon|flipkart)\s+)?pay\s+later\b|'
      r'\b(?:availing|availed)\s+(?:(?:amazon|flipkart)\s+)?pay\s+later\b|'
      r'\b(?:availing|availed)\s+credit\s+of\b|'
      r'\bpay\s+later\s+credit\b|'
      r'\bpay\s+later(?:\s+[\w\d]+)?\s+(?:a\/c|account)\b|'
      r'\b(?:lazypay|simpl|postpe)\b',
      caseSensitive: false,
    ).hasMatch(text);
  }

  static NeedsReviewItem resolveItemKind(NeedsReviewItem item) {
    if (item.kind != NeedsReviewKind.transaction) return item;
    if (isPayLaterDrawdown(item.body, sender: item.sender)) {
      return item.copyWith(kind: NeedsReviewKind.payLaterDrawdown);
    }
    if (isSecurityOrServiceAlert(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.securityOrServiceAlert);
    }
    if (isInvestmentSettlement(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.investmentSettlement);
    }
    if (isMandateReview(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.mandate);
    }
    if (isMerchantReceiptOrEbill(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.receipt);
    }
    return item;
  }

  static bool hasMatchingInvestmentTransactionSync(
    AppDatabase database,
    String namespace,
    NeedsReviewItem item, {
    List<TransactionEntry>? transactions,
    bool transactionsAreComplete = false,
  }) {
    final extracted = LocalSmsParser.extractReceiptAmount(item.body);
    if (extracted == null || extracted.paise <= 0) return false;

    if (transactions != null) {
      for (final txn in transactions) {
        if (txn.status != 'active') continue;
        final entryKindStr = txn.entryKind.name.toLowerCase();
        final wireValueStr = txn.entryKind.wireValue.toLowerCase();
        if (entryKindStr != 'investment' &&
            entryKindStr != 'spend' &&
            wireValueStr != 'investment' &&
            wireValueStr != 'spend') {
          continue;
        }
        if (txn.amount.paise != extracted.paise) continue;
        if (txn.occurredAt.difference(item.receivedAt).abs() <=
            const Duration(hours: 72)) {
          return true;
        }
      }
      if (transactionsAreComplete) return false;
    }

    try {
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS financial_entities (
          namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
          payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
          pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
          occurred_at INTEGER, amount_paise INTEGER,
          PRIMARY KEY(namespace, entity, id)
        );
      ''');
      final rows = database.db.select(
        "SELECT payload, occurred_at, amount_paise FROM financial_entities WHERE namespace = ? AND entity = 'transactions'",
        [namespace],
      );
      for (final row in rows) {
        final payloadJson = row['payload'] as String?;
        if (payloadJson == null) continue;
        final data = jsonDecode(payloadJson) as Map<String, dynamic>;

        if ((data['status'] ?? 'active') != 'active') continue;

        final entryKind = (data['entry_kind'] as String?)?.toLowerCase();
        if (entryKind != null &&
            entryKind != 'investment' &&
            entryKind != 'spend') {
          continue;
        }

        final paiseCol = row['amount_paise'] as int?;
        final amountInr = data['amount_inr'] as num?;
        var amountMatched = false;
        if (paiseCol != null) {
          amountMatched = paiseCol == extracted.paise;
        } else if (amountInr != null) {
          amountMatched = (amountInr * 100).round() == extracted.paise;
        } else if (data['amount'] is Map &&
            (data['amount'] as Map)['paise'] is int) {
          amountMatched = (data['amount'] as Map)['paise'] == extracted.paise;
        }
        if (!amountMatched) continue;

        DateTime? occurredAt;
        final occurredCol = row['occurred_at'] as int?;
        if (occurredCol != null) {
          occurredAt = DateTime.fromMillisecondsSinceEpoch(occurredCol);
        } else if (data['occurred_at'] != null) {
          final rawOccurred = data['occurred_at'];
          if (rawOccurred is String) {
            occurredAt = DateTime.tryParse(rawOccurred);
          } else if (rawOccurred is int) {
            occurredAt = DateTime.fromMillisecondsSinceEpoch(rawOccurred);
          }
        }
        if (occurredAt == null) continue;

        if (occurredAt.difference(item.receivedAt).abs() <=
            const Duration(hours: 72)) {
          return true;
        }
      }
    } catch (_) {}

    return false;
  }

  bool _hasMatchingInvestmentTransaction(
    NeedsReviewItem item, {
    AppDatabase? database,
    List<TransactionEntry>? transactions,
    bool transactionsAreComplete = false,
  }) {
    final txns = transactions ?? existingTransactions;
    if (database != null) {
      return hasMatchingInvestmentTransactionSync(
        database,
        namespace,
        item,
        transactions: txns,
        transactionsAreComplete: transactionsAreComplete,
      );
    }
    final extracted = LocalSmsParser.extractReceiptAmount(item.body);
    if (extracted == null || extracted.paise <= 0) return false;
    if (txns != null) {
      for (final txn in txns) {
        if (txn.status != 'active') continue;
        final entryKindStr = txn.entryKind.name.toLowerCase();
        final wireValueStr = txn.entryKind.wireValue.toLowerCase();
        if (entryKindStr != 'investment' &&
            entryKindStr != 'spend' &&
            wireValueStr != 'investment' &&
            wireValueStr != 'spend') {
          continue;
        }
        if (txn.amount.paise != extracted.paise) continue;
        if (txn.occurredAt.difference(item.receivedAt).abs() <=
            const Duration(hours: 72)) {
          return true;
        }
      }
    }
    return false;
  }

  static bool isMerchantReceiptOrEbill(String body) =>
      LocalSmsParser.isMerchantReceiptOrEbill(body);

  static TransactionEntry? matchingSpendTransactionInList(
    NeedsReviewItem item,
    List<TransactionEntry>? transactions,
  ) {
    final extracted = LocalSmsParser.extractReceiptAmount(item.body);
    if (extracted == null || extracted.paise <= 0) return null;
    for (final txn in transactions ?? const <TransactionEntry>[]) {
      if (txn.status != 'active') continue;
      final entryKind = txn.entryKind.name.toLowerCase();
      final wireValue = txn.entryKind.wireValue.toLowerCase();
      if (entryKind != 'spend' &&
          entryKind != 'payment' &&
          wireValue != 'spend' &&
          wireValue != 'payment') {
        continue;
      }
      if (txn.amount.paise != extracted.paise ||
          txn.occurredAt.difference(item.receivedAt).abs() >
              const Duration(hours: 72)) {
        continue;
      }
      if (_merchantMatchesOrOverlaps(
        txn.merchantName,
        item.body,
        item.sender,
      )) {
        return txn;
      }
    }
    return null;
  }

  static bool _merchantMatchesOrOverlaps(
    String? txnMerchant,
    String receiptBody,
    String receiptSender,
  ) {
    if (txnMerchant == null || txnMerchant.trim().isEmpty) {
      return true;
    }
    final merchantLower = txnMerchant.trim().toLowerCase();
    const stopWords = {
      'pvt',
      'ltd',
      'limited',
      'india',
      'retail',
      'store',
      'stores',
      'online',
      'payment',
      'payments',
      'pay',
      'corp',
      'corporation',
      'services',
      'service',
      'the',
      'and',
      'for',
      'with',
      'from',
      'upi',
      'pos',
      'txn',
      'bank',
      'com',
      'in',
      'org',
      'net',
    };
    final rawTokens = merchantLower
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty && !stopWords.contains(t))
        .toList();

    if (rawTokens.isEmpty) {
      return true;
    }

    final cleanBody = receiptBody.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    final cleanSender = receiptSender.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    final lowerBody = receiptBody.toLowerCase();
    final lowerSender = receiptSender.toLowerCase();

    for (final token in rawTokens) {
      if (token.length >= 4) {
        if (cleanBody.contains(token) || cleanSender.contains(token)) {
          return true;
        }
      } else if (token.length == 3) {
        if (RegExp(r'\b' + RegExp.escape(token) + r'\b').hasMatch(lowerBody) ||
            RegExp(
              r'\b' + RegExp.escape(token) + r'\b',
            ).hasMatch(lowerSender) ||
            cleanSender.contains(token)) {
          return true;
        }
      }
    }

    return false;
  }

  static bool hasMatchingSpendTransactionSync(
    AppDatabase database,
    String namespace,
    NeedsReviewItem item, {
    List<TransactionEntry>? transactions,
    bool transactionsAreComplete = false,
  }) =>
      matchingSpendTransactionIdSync(
        database,
        namespace,
        item,
        transactions: transactions,
        transactionsAreComplete: transactionsAreComplete,
      ) !=
      null;

  static String? matchingSpendTransactionIdSync(
    AppDatabase database,
    String namespace,
    NeedsReviewItem item, {
    List<TransactionEntry>? transactions,
    bool transactionsAreComplete = false,
  }) {
    final extracted = LocalSmsParser.extractReceiptAmount(item.body);
    if (extracted == null || extracted.paise <= 0) return null;

    final listed = matchingSpendTransactionInList(item, transactions);
    if (listed != null) return listed.id;
    if (transactionsAreComplete) return null;

    try {
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS financial_entities (
          namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
          payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
          pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
          occurred_at INTEGER, amount_paise INTEGER,
          PRIMARY KEY(namespace, entity, id)
        );
      ''');
      final rows = database.db.select(
        "SELECT id, payload, occurred_at, amount_paise FROM financial_entities WHERE namespace = ? AND entity = 'transactions'",
        [namespace],
      );
      for (final row in rows) {
        final payloadJson = row['payload'] as String?;
        if (payloadJson == null) continue;
        final data = jsonDecode(payloadJson) as Map<String, dynamic>;

        if ((data['status'] ?? 'active') != 'active') continue;
        final entryKind = (data['entry_kind'] as String?)?.toLowerCase();
        if (entryKind != null &&
            entryKind != 'spend' &&
            entryKind != 'payment') {
          continue;
        }

        final paiseCol = row['amount_paise'] as int?;
        final amountInr = data['amount_inr'] as num?;
        var amountMatched = false;
        if (paiseCol != null) {
          amountMatched = paiseCol == extracted.paise;
        } else if (amountInr != null) {
          amountMatched = (amountInr * 100).round() == extracted.paise;
        } else if (data['amount'] is Map &&
            (data['amount'] as Map)['paise'] is int) {
          amountMatched = (data['amount'] as Map)['paise'] == extracted.paise;
        }
        if (!amountMatched) continue;

        DateTime? occurredAt;
        final occurredCol = row['occurred_at'] as int?;
        if (occurredCol != null) {
          occurredAt = DateTime.fromMillisecondsSinceEpoch(occurredCol);
        } else if (data['occurred_at'] != null) {
          final rawOccurred = data['occurred_at'];
          if (rawOccurred is String) {
            occurredAt = DateTime.tryParse(rawOccurred);
          } else if (rawOccurred is int) {
            occurredAt = DateTime.fromMillisecondsSinceEpoch(rawOccurred);
          }
        }
        if (occurredAt == null) continue;

        if (occurredAt.difference(item.receivedAt).abs() <=
            const Duration(hours: 72)) {
          final txnMerchant =
              data['merchant_name'] as String? ??
              data['merchant'] as String? ??
              data['merchantName'] as String?;
          if (_merchantMatchesOrOverlaps(txnMerchant, item.body, item.sender)) {
            return row['id'] as String;
          }
        }
      }
    } catch (_) {}

    return null;
  }

  bool _hasMatchingSpendTransaction(
    NeedsReviewItem item, {
    AppDatabase? database,
    List<TransactionEntry>? transactions,
    bool transactionsAreComplete = false,
  }) {
    final txns = transactions ?? existingTransactions;
    if (database != null) {
      return hasMatchingSpendTransactionSync(
        database,
        namespace,
        item,
        transactions: txns,
        transactionsAreComplete: transactionsAreComplete,
      );
    }
    final extracted = LocalSmsParser.extractReceiptAmount(item.body);
    if (extracted == null || extracted.paise <= 0) return false;
    if (txns != null) {
      for (final txn in txns) {
        if (txn.status != 'active') continue;
        final entryKindStr = txn.entryKind.name.toLowerCase();
        final wireValueStr = txn.entryKind.wireValue.toLowerCase();
        if (entryKindStr != 'spend' &&
            entryKindStr != 'payment' &&
            wireValueStr != 'spend' &&
            wireValueStr != 'payment') {
          continue;
        }
        if (txn.amount.paise != extracted.paise) continue;
        if (txn.occurredAt.difference(item.receivedAt).abs() <=
            const Duration(hours: 72)) {
          if (_merchantMatchesOrOverlaps(
            txn.merchantName,
            item.body,
            item.sender,
          )) {
            return true;
          }
        }
      }
    }
    return false;
  }

  static bool isRefundOrReversal(String body) {
    final text = body.toLowerCase();
    return RegExp(
      r'\b(?:refund(?:ed)?|chargeback|reversal|reversed)\b',
    ).hasMatch(text);
  }

  static bool hasMatchingRefundDebitSync(
    AppDatabase database,
    String namespace,
    NeedsReviewItem item, {
    List<TransactionEntry>? transactions,
    bool transactionsAreComplete = false,
  }) {
    final parsed = LocalSmsParser.parse(
      body: item.body,
      sender: item.sender,
      receivedAt: item.receivedAt,
      namespace: namespace,
    );
    final refundAmount =
        parsed?.transaction?.amount ??
        LocalSmsParser.extractReceiptAmount(item.body);
    if (refundAmount == null || refundAmount.paise <= 0) return false;

    var refundMerchant = parsed?.transaction?.merchantName;
    if (refundMerchant == null ||
        refundMerchant.isEmpty ||
        refundMerchant.toLowerCase() == 'refund' ||
        refundMerchant.toLowerCase() == 'reversal') {
      final match = RegExp(
        r'\b(?:at|to|for|from|by|towards?)\s+(?!(?:₹|rs\.?|inr)(?:\b|\s|\d)|\d+[\s.,])([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:by\s+upi|from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block|umrn|nach|mandate)\b|\s*\(|[.,;]|$)',
        caseSensitive: false,
      ).firstMatch(item.body);
      refundMerchant = match?.group(1)?.trim();
    }
    if (refundMerchant == null || refundMerchant.isEmpty) {
      final senderClean = item.sender
          .toUpperCase()
          .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
          .replaceFirst(RegExp(r'-[A-Z]$'), '');
      if (senderClean.isNotEmpty) {
        refundMerchant = senderClean;
      }
    }
    refundMerchant ??= item.body;

    final candidateDebits = <TransactionEntry>[];
    if (transactions != null) {
      candidateDebits.addAll(
        transactions.where(
          (t) => t.status == 'active' && t.entryKind == TxnEntryKind.spend,
        ),
      );
    }

    if (!transactionsAreComplete) {
      try {
        database.db.execute('''
        CREATE TABLE IF NOT EXISTS financial_entities (
          namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
          payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
          pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
          occurred_at INTEGER, amount_paise INTEGER,
          PRIMARY KEY(namespace, entity, id)
        );
        ''');
        final rows = database.db.select(
          "SELECT payload FROM financial_entities WHERE namespace = ? AND entity = 'transactions'",
          [namespace],
        );
        for (final row in rows) {
          final payloadJson = row['payload'] as String?;
          if (payloadJson == null) continue;
          try {
            final data = jsonDecode(payloadJson) as Map<String, dynamic>;
            final entry = TransactionEntry.fromJson(data);
            if (entry.status == 'active' &&
                entry.entryKind == TxnEntryKind.spend) {
              candidateDebits.add(entry);
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    final refundDate = parsed?.transaction?.occurredAt ?? item.receivedAt;
    final matchResult = AdjustmentMatcher.findMatchingDebit(
      refundAmount: refundAmount,
      refundMerchant: refundMerchant,
      refundDate: refundDate,
      candidateDebits: candidateDebits,
    );

    if (matchResult != null) {
      _persistResolvedRefundMatchSync(database, namespace, item, matchResult);
      return true;
    }
    return false;
  }

  bool _hasMatchingRefundDebit(
    NeedsReviewItem item, {
    AppDatabase? database,
    List<TransactionEntry>? transactions,
    bool transactionsAreComplete = false,
  }) {
    final txns = transactions ?? existingTransactions;
    if (database != null) {
      return hasMatchingRefundDebitSync(
        database,
        namespace,
        item,
        transactions: txns,
        transactionsAreComplete: transactionsAreComplete,
      );
    }
    final parsed = LocalSmsParser.parse(
      body: item.body,
      sender: item.sender,
      receivedAt: item.receivedAt,
      namespace: namespace,
    );
    final refundAmount =
        parsed?.transaction?.amount ??
        LocalSmsParser.extractReceiptAmount(item.body);
    if (refundAmount == null || refundAmount.paise <= 0) return false;

    var refundMerchant = parsed?.transaction?.merchantName;
    if (refundMerchant == null ||
        refundMerchant.isEmpty ||
        refundMerchant.toLowerCase() == 'refund' ||
        refundMerchant.toLowerCase() == 'reversal') {
      final match = RegExp(
        r'\b(?:at|to|for|from|by|towards?)\s+(?!(?:₹|rs\.?|inr)(?:\b|\s|\d)|\d+[\s.,])([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:by\s+upi|from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block|umrn|nach|mandate)\b|\s*\(|[.,;]|$)',
        caseSensitive: false,
      ).firstMatch(item.body);
      refundMerchant = match?.group(1)?.trim();
    }
    if (refundMerchant == null || refundMerchant.isEmpty) {
      final senderClean = item.sender
          .toUpperCase()
          .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
          .replaceFirst(RegExp(r'-[A-Z]$'), '');
      if (senderClean.isNotEmpty) {
        refundMerchant = senderClean;
      }
    }
    refundMerchant ??= item.body;

    final candidateDebits = <TransactionEntry>[];
    if (txns != null && txns.isNotEmpty) {
      candidateDebits.addAll(
        txns.where(
          (t) => t.status == 'active' && t.entryKind == TxnEntryKind.spend,
        ),
      );
    }

    final refundDate = parsed?.transaction?.occurredAt ?? item.receivedAt;
    final matchResult = AdjustmentMatcher.findMatchingDebit(
      refundAmount: refundAmount,
      refundMerchant: refundMerchant,
      refundDate: refundDate,
      candidateDebits: candidateDebits,
    );

    return matchResult != null;
  }

  static void _persistResolvedRefundMatchSync(
    AppDatabase database,
    String namespace,
    NeedsReviewItem item,
    LiveRefundMatchResult match,
  ) {
    try {
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS financial_entities (
          namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
          payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
          pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
          occurred_at INTEGER, amount_paise INTEGER,
          PRIMARY KEY(namespace, entity, id)
        );
      ''');
      final linkPayload = {
        'id': 'refund_link:${item.id}',
        'debit_txn_id': match.debitTxnId,
        'original_debit_amount_paise': match.originalDebitAmount.paise,
        'refund_amount_paise': match.refundAmount.paise,
        'net_amount_paise': match.netAmount.paise,
        'days_apart': match.daysApart,
        'matched_at': DateTime.now().toUtc().toIso8601String(),
        'refund_sms_id': item.id,
      };
      database.db.execute(
        '''
        INSERT INTO financial_entities(
          namespace, entity, id, payload, observed_at, pending, source_key, occurred_at, amount_paise
        ) VALUES (?, 'refund_adjustments', ?, ?, ?, 0, ?, ?, ?)
        ON CONFLICT(namespace, entity, id) DO UPDATE SET
          payload=excluded.payload, observed_at=excluded.observed_at
      ''',
        [
          namespace,
          'refund_link:${item.id}',
          jsonEncode(linkPayload),
          item.receivedAt.millisecondsSinceEpoch,
          item.id,
          item.receivedAt.millisecondsSinceEpoch,
          match.refundAmount.paise,
        ],
      );
      _notify(database, namespace, 'transactions');
    } catch (_) {
      rethrow;
    }
  }

  static bool isNoiseItem(NeedsReviewItem item) {
    final cleanSender = item.sender.trim().toLowerCase();
    if (cleanSender.contains('indialend') ||
        cleanSender.contains('indlnd') ||
        cleanSender.contains('idlnd')) {
      return true;
    }
    if (isSecurityOrServiceAlert(item.body)) {
      return true;
    }
    final resolved = resolveItemKind(item);
    if (resolved.kind == NeedsReviewKind.payLaterDrawdown) {
      return false;
    }
    if (resolved.kind == NeedsReviewKind.securityOrServiceAlert) {
      return true;
    }
    if (resolved.kind == NeedsReviewKind.investmentSettlement ||
        resolved.kind == NeedsReviewKind.mandate ||
        resolved.kind == NeedsReviewKind.receipt) {
      return false;
    }
    if (isMerchantReceiptOrEbill(resolved.body) ||
        isInvestmentFolioAllotment(resolved.body)) {
      return false;
    }
    return LocalSmsParser.isNonTransactionNoise(resolved.sender, resolved.body);
  }

  bool _isNoiseOrStale(NeedsReviewItem item) {
    if (item.kind == NeedsReviewKind.payLaterDrawdown ||
        isPayLaterDrawdown(item.body, sender: item.sender)) {
      return !_capturesReviewableFinancial(item);
    }
    return isNoiseItem(item) || !_capturesReviewableFinancial(item);
  }

  Future<void> add(
    NeedsReviewItem item, {
    List<TransactionEntry>? transactions,
  }) async {
    if (isNoiseItem(item)) return;
    if (!_capturesReviewableFinancial(item)) return;
    final txns = transactions ?? existingTransactions;
    if (isMerchantReceiptOrEbill(item.body)) {
      if (loadDatabase != null) {
        final db = await _database();
        final linkedId = matchingSpendTransactionIdSync(
          db,
          namespace,
          item,
          transactions: txns,
        );
        if (linkedId != null) {
          PastBillReceiptRepository(db, namespace: namespace).archiveReceipt(
            id: item.id,
            sender: item.sender,
            body: item.body,
            receivedAt: item.receivedAt,
            linkedTransactionId: linkedId,
            status: PastBillReceiptStatus.paidLinked,
          );
          return;
        }
      } else if (_hasMatchingSpendTransaction(item, transactions: txns)) {
        return;
      }
    }
    if (isRefundOrReversal(item.body)) {
      if (loadDatabase != null) {
        final db = await _database();
        if (_hasMatchingRefundDebit(item, database: db, transactions: txns)) {
          return;
        }
      } else if (_hasMatchingRefundDebit(item, transactions: txns)) {
        return;
      }
    }
    final parsed = LocalSmsParser.parse(
      body: item.body,
      sender: item.sender,
      receivedAt: item.receivedAt,
      namespace: namespace,
    );
    if (isMonthOnlyPremiumNotice(parsed)) {
      if (loadDatabase != null &&
          isPastMonthOnlyPremiumNotice(parsed, item.body)) {
        final db = await _database();
        _archiveMonthOnlyPremiumSync(db, namespace, parsed!, item);
      }
      return;
    }
    if (!isPayLaterDrawdown(item.body, sender: item.sender) &&
        parsed != null &&
        parsed.eventType == LocalSmsEventType.bill &&
        parsed.cardLast4 == null &&
        parsed.dueDate != null) {
      if (loadDatabase != null) {
        final db = await _database();
        final now = DateTime.now();
        final startOfToday = DateTime(now.year, now.month, now.day);
        if (!parsed.dueDate!.isBefore(startOfToday)) {
          _persistResolvedCommitmentSync(db, namespace, parsed, item);
          _persistResolvedBillObservationSync(db, namespace, parsed, item);
          return;
        } else {
          final allTransactions = await _loadTransactionSnapshot(
            db,
            namespace,
            txns,
          );
          final linked = deriveSmsBillRows(
            observations: [
              {
                'event_type': parsed.eventType.wireValue,
                'received_at': item.receivedAt.toIso8601String(),
                'sender_bank': item.sender,
                'biller_name': parsed.billerName,
                'card_last4': parsed.cardLast4,
                'account_last4': parsed.accountLast4,
                'amount_due_paise': parsed.amountDue?.paise,
                'minimum_due_paise': parsed.minimumDue?.paise,
                'due_date': parsed.dueDate?.toIso8601String(),
                'is_autopay': parsed.isAutopay,
              },
            ],
            transactions: allTransactions,
            cardsLast4ById: _loadCardLast4Sync(db, namespace),
            now: now,
            lookbackDays: 36525,
          ).where((row) => row.state == SmsBillState.linked).firstOrNull;
          PastBillReceiptRepository(db, namespace: namespace).archiveBill(
            id: item.id,
            sender: item.sender,
            merchant: parsed.billerName ?? item.sender,
            amount: parsed.amountDue,
            receivedAt: item.receivedAt,
            dueDate: parsed.dueDate,
            cardLast4: parsed.cardLast4,
            accountLast4: parsed.accountLast4,
            body: item.body,
            status: linked == null
                ? PastBillReceiptStatus.historicalUnpaid
                : PastBillReceiptStatus.paidLinked,
            linkedTransactionId: linked?.linkedTxnId,
          );
          _persistResolvedBillObservationSync(db, namespace, parsed, item);
          return;
        }
      }
    }
    final resolved = resolveItemKind(item);
    if (loadDatabase != null) {
      final db = await _database();
      final current = await fetchAll();
      if (current.any(
        (old) =>
            old.id != resolved.id &&
            old.sender.trim().toLowerCase() ==
                resolved.sender.trim().toLowerCase() &&
            _normalizeBody(old.body) == _normalizeBody(resolved.body) &&
            old.receivedAt.difference(resolved.receivedAt).abs() <=
                const Duration(minutes: 5),
      )) {
        return;
      }
      db.db.execute(
        'INSERT OR REPLACE INTO local_needs_review VALUES (?,?,?)',
        [namespace, resolved.id, jsonEncode(resolved.toJson())],
      );
      _notify(db, namespace, 'needs_review');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final normalizedSender = resolved.sender.trim().toLowerCase();
    // SMS gateways sometimes add indentation/newlines when the same alert is
    // delivered through two channels. Treat that as the same message while
    // preserving the original body for display and one-tap resolution.
    final normalizedBody = _normalizeBody(resolved.body);
    var duplicate = false;
    final withoutRetry = raw.where((entry) {
      try {
        final existing = NeedsReviewItem.fromJson(
          jsonDecode(entry) as Map<String, dynamic>,
        );
        if (existing.id == resolved.id) return false;
        final sameMessage =
            existing.sender.trim().toLowerCase() == normalizedSender &&
            _normalizeBody(existing.body) == normalizedBody;
        final closeInTime =
            existing.receivedAt.difference(resolved.receivedAt).abs() <=
            const Duration(minutes: 5);
        if (sameMessage && closeInTime) duplicate = true;
        return true;
      } catch (_) {
        return true;
      }
    }).toList();
    if (duplicate) return;
    await prefs.setStringList(_needsReviewKey, [
      ...withoutRetry,
      jsonEncode(resolved.toJson()),
    ]);
  }

  /// Persists owner-scoped, validated PandaPay AI facts onto an existing local
  /// review row. It deliberately never recreates a row that the user already
  /// dismissed or resolved while the network request was in flight.
  Future<bool> updateAiSuggestions(
    String id,
    List<Map<String, dynamic>> suggestions, {
    String? aiTopic,
    Map<String, dynamic>? aiDecision,
    String? aiSummary,
  }) async {
    final items = await fetchAll();
    final current = items.where((item) => item.id == id).firstOrNull;
    if (current == null) return false;
    final nextTopic = aiTopic ?? current.aiTopic;
    final nextDecision = aiDecision ?? current.aiDecision;
    final nextSummary = aiSummary ?? current.aiSummary;
    if (jsonEncode(current.aiSuggestions ?? const []) ==
            jsonEncode(suggestions) &&
        current.aiTopic == nextTopic &&
        jsonEncode(current.aiDecision) == jsonEncode(nextDecision) &&
        current.aiSummary == nextSummary) {
      return false;
    }
    final updated = jsonEncode(
      current
          .copyWith(
            aiSuggestions: suggestions,
            aiTopic: nextTopic,
            aiDecision: nextDecision,
            aiSummary: nextSummary,
          )
          .toJson(),
    );
    if (loadDatabase != null) {
      final db = await _database();
      db.db.execute(
        'UPDATE local_needs_review SET payload=? WHERE namespace=? AND id=?',
        [updated, namespace, id],
      );
      final changed = db.db.updatedRows > 0;
      if (changed) _notify(db, namespace, 'needs_review');
      return changed;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    var changed = false;
    final patched = raw.map((entry) {
      final value = jsonDecode(entry) as Map<String, dynamic>;
      if (value['id'] != id) return entry;
      changed = true;
      return updated;
    }).toList();
    if (changed) await prefs.setStringList(_needsReviewKey, patched);
    return changed;
  }

  static String normalizeBody(String body) =>
      body.trim().replaceAll(RegExp(r'\s+'), ' ');

  String _normalizeBody(String body) => normalizeBody(body);

  /// "Not a transaction" dismiss, or a successful one-tap-fill resolution â€”
  /// either way, the item leaves the queue. Which one happened is the
  /// caller's concern (screen-level), not this store's.
  Future<void> remove(String id) async {
    if (loadDatabase != null) {
      final db = await _database();
      db.db.execute(
        'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
        [namespace, id],
      );
      if (db.db.updatedRows > 0) _notify(db, namespace, 'needs_review');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final kept = raw
        .where((s) => (jsonDecode(s) as Map<String, dynamic>)['id'] != id)
        .toList();
    await prefs.setStringList(_needsReviewKey, kept);
  }

  /// A month-only insurance reminder ("next premium falls due on 12/2024")
  /// carries no day and no amount. Past months are archived as history, and
  /// current or future months are shown on the Bills page, so neither belongs
  /// in the open review queue.
  static bool isMonthOnlyPremiumNotice(LocalSmsObservation? parsed) {
    return parsed != null &&
        parsed.eventType == LocalSmsEventType.bill &&
        parsed.reasonCodes.contains('next_premium_due_month_only');
  }

  /// Once the month named by a month-only reminder has passed it is history,
  /// not an open review task; no payment can ever be linked to it.
  static bool isPastMonthOnlyPremiumNotice(
    LocalSmsObservation? parsed,
    String body, {
    DateTime? now,
  }) {
    if (!isMonthOnlyPremiumNotice(parsed)) return false;
    final month = LocalSmsParser.nextPremiumDueMonth(body);
    if (month == null) return false;
    final at = now ?? DateTime.now();
    return DateTime(
      month.year,
      month.month,
    ).isBefore(DateTime(at.year, at.month));
  }

  static void _archiveMonthOnlyPremiumSync(
    AppDatabase database,
    String namespace,
    LocalSmsObservation parsed,
    NeedsReviewItem item,
  ) {
    PastBillReceiptRepository(database, namespace: namespace).archiveBill(
      // Archive under the source key so the observation-derived history and
      // this archived row never show the same notice twice.
      id: item.id.startsWith('commitment:')
          ? item.id.substring('commitment:'.length)
          : item.id,
      sender: item.sender,
      merchant: parsed.billerName ?? item.sender,
      amount: null,
      receivedAt: item.receivedAt,
      dueDate: null,
      status: PastBillReceiptStatus.needsConfirmation,
      body: item.body,
    );
  }

  Future<void> archivePastPremiumNotice(NeedsReviewItem item) async {
    final parsed = LocalSmsParser.parse(
      namespace: namespace,
      sender: item.sender,
      body: item.body,
      receivedAt: item.receivedAt,
    );
    final month = LocalSmsParser.nextPremiumDueMonth(item.body);
    final now = DateTime.now();
    if (loadDatabase == null ||
        parsed?.reasonCodes.contains('next_premium_due_month_only') != true ||
        month == null ||
        !DateTime(
          month.year,
          month.month,
        ).isBefore(DateTime(now.year, now.month))) {
      throw StateError('Only past month-only premium notices can be archived.');
    }
    final db = await _database();
    final existing = db.db.select(
      'SELECT id FROM local_needs_review WHERE namespace=? AND id=?',
      [namespace, item.id],
    );
    if (existing.isEmpty) return;
    PastBillReceiptRepository(db, namespace: namespace).archiveBill(
      id: item.id,
      sender: item.sender,
      merchant: parsed?.billerName ?? item.sender,
      amount: null,
      receivedAt: item.receivedAt,
      dueDate: null,
      status: PastBillReceiptStatus.needsConfirmation,
      body: item.body,
    );
    await remove(item.id);
  }

  Future<void> removeAll(Iterable<String> ids) async {
    final idList = ids.toList();
    if (idList.isEmpty) return;
    if (loadDatabase != null) {
      final db = await _database();
      db.db.execute('SAVEPOINT remove_all_needs_review');
      var changed = false;
      try {
        for (final id in idList) {
          db.db.execute(
            'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
            [namespace, id],
          );
          changed = changed || db.db.updatedRows > 0;
        }
        db.db.execute('RELEASE SAVEPOINT remove_all_needs_review');
        if (changed) _notify(db, namespace, 'needs_review');
      } catch (_) {
        db.db.execute('ROLLBACK TO SAVEPOINT remove_all_needs_review');
        db.db.execute('RELEASE SAVEPOINT remove_all_needs_review');
        rethrow;
      }
      return;
    }
    final idSet = ids.toSet();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final kept = raw
        .where(
          (s) => !idSet.contains((jsonDecode(s) as Map<String, dynamic>)['id']),
        )
        .toList();
    await prefs.setStringList(_needsReviewKey, kept);
  }

  static void _persistResolvedTransactionSync(
    AppDatabase database,
    String namespace,
    TransactionEntry txn,
    String sourceKey,
  ) {
    try {
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS financial_entities (
          namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
          payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
          pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
          occurred_at INTEGER, amount_paise INTEGER,
          PRIMARY KEY(namespace, entity, id)
        );
      ''');
      database.db.execute(
        '''
        INSERT INTO financial_entities(
          namespace, entity, id, payload, observed_at, pending, source_key, occurred_at, amount_paise
        ) VALUES (?, 'transactions', ?, ?, ?, 1, ?, ?, ?)
        ON CONFLICT(namespace, entity, id) DO UPDATE SET
          payload=excluded.payload, observed_at=excluded.observed_at,
          source_key=excluded.source_key, occurred_at=excluded.occurred_at,
          amount_paise=excluded.amount_paise
      ''',
        [
          namespace,
          txn.id,
          jsonEncode(txn.toJson()),
          txn.occurredAt.millisecondsSinceEpoch,
          sourceKey,
          txn.occurredAt.millisecondsSinceEpoch,
          txn.amount.paise,
        ],
      );
      _notify(database, namespace, 'transactions');
    } catch (_) {
      rethrow;
    }
  }

  Future<bool> updateAiStatus(
    String id,
    AiReviewStatus status, {
    String? failureReason,
  }) async {
    final items = await fetchAll();
    final current = items.where((item) => item.id == id).firstOrNull;
    if (current == null ||
        (current.aiStatus == status &&
            (status != AiReviewStatus.unavailable ||
                current.aiFailureReason == failureReason))) {
      return false;
    }
    final updated = jsonEncode(
      current
          .copyWith(
            aiStatus: status,
            aiFailureReason: failureReason,
            clearAiFailureReason: status != AiReviewStatus.unavailable,
          )
          .toJson(),
    );
    if (loadDatabase != null) {
      final db = await _database();
      db.db.execute(
        'UPDATE local_needs_review SET payload=? WHERE namespace=? AND id=?',
        [updated, namespace, id],
      );
      final changed = db.db.updatedRows > 0;
      if (changed) _notify(db, namespace, 'needs_review');
      return changed;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    var changed = false;
    final patched = raw.map((entry) {
      final value = jsonDecode(entry) as Map<String, dynamic>;
      if (value['id'] != id) return entry;
      changed = true;
      return updated;
    }).toList();
    if (changed) await prefs.setStringList(_needsReviewKey, patched);
    return changed;
  }

  static void _persistResolvedBillObservationSync(
    AppDatabase database,
    String namespace,
    LocalSmsObservation parsed,
    NeedsReviewItem item,
  ) {
    try {
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS financial_entities (
          namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
          payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
          pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
          occurred_at INTEGER, amount_paise INTEGER,
          PRIMARY KEY(namespace, entity, id)
        );
      ''');
      final obsPayload = {
        'id': item.id,
        'sender_bank': item.sender
            .toUpperCase()
            .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
            .replaceFirst(RegExp(r'-[A-Z]$'), ''),
        'parser_version': LocalSmsParser.version,
        'received_at': item.receivedAt.toUtc().toIso8601String(),
        'account_last4': parsed.accountLast4,
        'is_bank_account': false,
        'card_last4': parsed.cardLast4,
        'biller_name': parsed.billerName,
        'cadence_hint': parsed.cadenceHint,
        'balance_paise': parsed.availableBalance?.paise,
        'amount_due_paise': parsed.amountDue?.paise,
        'minimum_due_paise': parsed.minimumDue?.paise,
        'autopay_limit_paise': parsed.autopayLimit?.paise,
        'due_date': parsed.dueDate?.toIso8601String(),
        'statement_date': parsed.statementDate?.toIso8601String(),
        'statement_date_explicit': parsed.statementDateExplicit,
        'event_type': parsed.eventType.wireValue,
        'disposition': parsed.disposition.wireValue,
        'reason_codes': parsed.reasonCodes,
        'is_autopay': parsed.isAutopay,
        'confidence': parsed.confidence,
        'sample_body': item.body,
      };
      database.db.execute(
        '''
        INSERT INTO financial_entities(
          namespace, entity, id, payload, observed_at, pending, source_key
        ) VALUES (?, 'sms_observations', ?, ?, ?, 0, ?)
        ON CONFLICT(namespace, entity, id) DO UPDATE SET
          payload=excluded.payload, observed_at=excluded.observed_at
      ''',
        [
          namespace,
          item.id,
          jsonEncode(obsPayload),
          item.receivedAt.millisecondsSinceEpoch,
          item.id,
        ],
      );
      _notify(database, namespace, 'observations');
    } catch (_) {
      rethrow;
    }
  }

  static void _persistResolvedCommitmentSync(
    AppDatabase database,
    String namespace,
    LocalSmsObservation parsed,
    NeedsReviewItem item,
  ) {
    try {
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS local_commitments (
          namespace TEXT NOT NULL,
          id TEXT NOT NULL,
          payload TEXT NOT NULL,
          PRIMARY KEY(namespace, id)
        );
      ''');
      final commitmentId = 'commitment:${item.id}';
      var title =
          (parsed.billerName != null && parsed.billerName!.trim().isNotEmpty)
          ? parsed.billerName!.trim()
          : 'Subscription / Mandate';

      final Money? amount;
      if (parsed.autopayLimit != null &&
          (parsed.amountDue == null || parsed.amountDue!.isZero)) {
        amount = parsed.autopayLimit!;
      } else if (parsed.amountDue != null && !parsed.amountDue!.isZero) {
        amount = parsed.amountDue!;
      } else {
        amount = parsed.amount ?? parsed.autopayLimit ?? parsed.amountDue;
      }

      try {
        final existingRows = database.db.select(
          'SELECT id, payload FROM local_commitments WHERE namespace = ?',
          [namespace],
        );
        for (final r in existingRows) {
          final existingId = r['id'] as String;
          final payload =
              jsonDecode(r['payload'] as String) as Map<String, dynamic>;
          final old = Commitment.fromJson(payload);
          final oldTitle = old.title.trim();
          final isOldGeneric =
              oldTitle.isEmpty ||
              oldTitle == 'Subscription / Mandate' ||
              oldTitle.toLowerCase() == 'subscription' ||
              oldTitle.toLowerCase() == 'mandate';

          if (existingId == commitmentId ||
              existingId == 'review-${item.id}' ||
              existingId == item.id) {
            if (!isOldGeneric && title == 'Subscription / Mandate') {
              title = oldTitle;
            }
            if (existingId != commitmentId) {
              database.db.execute(
                'DELETE FROM local_commitments WHERE namespace = ? AND id = ?',
                [namespace, existingId],
              );
            }
            continue;
          }

          if (isOldGeneric && title != 'Subscription / Mandate') {
            final oldAmountPaise = old.amount?.paise;
            final oldAnchorDay = old.anchorDay;
            if (oldAmountPaise != null &&
                oldAmountPaise == amount?.paise &&
                oldAnchorDay != null &&
                oldAnchorDay == (parsed.dueDate ?? item.receivedAt).day) {
              final updatedCommitment = old.copyWith(
                title: title,
                category: CommitmentCategory.fromText(title),
              );
              database.db.execute(
                'UPDATE local_commitments SET payload = ? WHERE namespace = ? AND id = ?',
                [jsonEncode(updatedCommitment.toJson()), namespace, existingId],
              );
              _notify(database, namespace, 'commitments');
              return;
            }
          }
        }
      } catch (_) {}

      final commitment = Commitment(
        id: commitmentId,
        title: title,
        category: CommitmentCategory.fromText(title),
        amount: amount,
        dueOn: parsed.dueDate ?? item.receivedAt,
        identifier: parsed.accountLast4 == null
            ? null
            : '••••${parsed.accountLast4}',
        cadence: CommitmentCadence.values.firstWhere(
          (value) => value.name == parsed.cadenceHint,
          orElse: () => LocalSmsParser.isActionableInsuranceRenewal(item.body)
              ? CommitmentCadence.oneTime
              : CommitmentCadence.monthly,
        ),
        anchorDay: (parsed.dueDate ?? item.receivedAt).day,
        status: CommitmentStatus.due,
        source: CommitmentSource.sms,
        isUserConfirmed: false,
      );
      database.db.execute(
        '''
        INSERT OR REPLACE INTO local_commitments VALUES (?, ?, ?)
      ''',
        [namespace, commitment.id, jsonEncode(commitment.toJson())],
      );
      _notify(database, namespace, 'commitments');
    } catch (_) {
      rethrow;
    }
  }

  static bool _matchesUserCardSync(
    AppDatabase? database,
    String namespace,
    String cardLast4,
  ) {
    if (database == null) return false;
    try {
      final rows = database.db.select(
        "SELECT payload FROM financial_entities WHERE namespace = ? AND entity = 'cards'",
        [namespace],
      );
      for (final r in rows) {
        final payload = r['payload'] as String?;
        if (payload == null) continue;
        final data = jsonDecode(payload) as Map<String, dynamic>;
        if (data['last4'] == cardLast4) return true;
      }
    } catch (_) {}
    return false;
  }

  static Map<String, String> _loadCardLast4Sync(
    AppDatabase database,
    String namespace,
  ) {
    try {
      final rows = database.db.select(
        "SELECT id, payload FROM financial_entities WHERE namespace = ? AND entity = 'cards'",
        [namespace],
      );
      final result = <String, String>{};
      for (final row in rows) {
        final payload = jsonDecode(row['payload'] as String);
        if (payload is Map<String, dynamic> && payload['last4'] is String) {
          result[row['id'] as String] = payload['last4'] as String;
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  static Future<List<TransactionEntry>> _loadTransactionSnapshot(
    AppDatabase database,
    String namespace,
    List<TransactionEntry>? initialTransactions,
  ) async {
    final byId = <String, TransactionEntry>{
      for (final transaction in initialTransactions ?? const [])
        transaction.id: transaction,
    };
    try {
      final rows = database.db.select(
        "SELECT payload FROM financial_entities WHERE namespace = ? AND entity = 'transactions'",
        [namespace],
      );
      for (var i = 0; i < rows.length; i++) {
        if (i > 0 && i % 128 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        try {
          final transaction = TransactionEntry.fromJson(
            jsonDecode(rows[i]['payload'] as String) as Map<String, dynamic>,
          );
          // Local edits/tombstones override a caller's older snapshot.
          byId[transaction.id] = transaction;
        } catch (_) {
          // Ignore an invalid local row; valid transactions still participate.
        }
      }
    } catch (_) {
      // A fresh local store may not have transaction tables yet.
    }
    return byId.values.toList(growable: false);
  }
}
