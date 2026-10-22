import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'commitments_repository.dart';
import 'local/app_database.dart';
import 'local_sms_parser.dart';
import 'user_cards_repository.dart';

enum NeedsReviewKind {
  transaction,
  commitment,
  securityOrServiceAlert,
  investmentSettlement,
  mandate,
}

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
/// it, the AI fallback may send a redacted copy to the configured Gemini
/// provider; local review remains available when AI is disabled or fails.
/// ui-spec D4 explicitly wants "raw text shown for context," which a
/// digit-stripped admin record structurally cannot provide. Rather than
/// requesting a schema change to a table designed for anonymized telemetry
/// (a real, separate decision â€” flagged, not made unilaterally here), this
/// keeps the raw SMS exactly where it already lives today: the device that
/// received it. The separate, explicit AI fallback uploads only after the
/// normal financial-message filter and removes sensitive identifiers on the
/// server before calling Gemini.
class NeedsReviewItem {
  final String id;
  final String sender;
  final String body;
  final String? reason;
  final DateTime receivedAt;
  final NeedsReviewKind kind;
  final List<Map<String, dynamic>>? aiSuggestions;

  const NeedsReviewItem({
    required this.id,
    required this.sender,
    required this.body,
    this.reason,
    required this.receivedAt,
    this.kind = NeedsReviewKind.transaction,
    this.aiSuggestions,
  });

  NeedsReviewItem copyWith({
    NeedsReviewKind? kind,
    List<Map<String, dynamic>>? aiSuggestions,
  }) =>
      NeedsReviewItem(
        id: id,
        sender: sender,
        body: body,
        reason: reason,
        receivedAt: receivedAt,
        kind: kind ?? this.kind,
        aiSuggestions: aiSuggestions ?? this.aiSuggestions,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender': sender,
    'body': body,
    'reason': reason,
    'receivedAt': receivedAt.toIso8601String(),
    'kind': kind.name,
    if (aiSuggestions != null) 'aiSuggestions': aiSuggestions,
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
    );
  }
}

const _needsReviewKey = 'pandapay_app.needs_review_queue_v1';

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
  if (NeedsReviewRepository.isMerchantReceiptOrEbill(item.body) &&
      NeedsReviewRepository.hasMatchingSpendTransactionSync(
        database,
        namespace,
        item,
        transactions: existingTransactions,
      )) {
    return;
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
}

/// Plain on-device store, same SharedPreferences mechanism
/// dueDateRemindersProvider (providers.dart) already uses for a similar
/// "no server round-trip needed, this is purely local" case.
class NeedsReviewRepository {
  final String namespace;
  final Future<AppDatabase> Function()? loadDatabase;
  final List<TransactionEntry>? existingTransactions;
  NeedsReviewRepository({
    this.namespace = 'legacy',
    this.loadDatabase,
    this.existingTransactions,
  });
  Future<AppDatabase> _database() async {
    final db = await loadDatabase!();
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getStringList(_needsReviewKey);
    if (old != null && old.isNotEmpty) {
      final corrupt = <String>[];
      db.db.execute('SAVEPOINT migrate_review');
      try {
        for (final raw in old) {
          NeedsReviewItem item;
          try {
            item = NeedsReviewItem.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
          } catch (_) {
            corrupt.add(raw);
            continue;
          }
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
    return db;
  }

  Future<List<NeedsReviewItem>> fetchAll({
    List<TransactionEntry>? transactions,
  }) async {
    final txns = transactions ?? existingTransactions;
    if (loadDatabase != null) {
      final db = await _database();
      final rows = db.db.select(
        'SELECT id, payload FROM local_needs_review WHERE namespace=?',
        [namespace],
      );
      final items = <NeedsReviewItem>[];
      final toUpdate = <NeedsReviewItem>[];
      final corruptIds = <String>[];
      for (final r in rows) {
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
        } catch (_) {
          db.db.execute('ROLLBACK TO SAVEPOINT update_resolved_kinds');
          db.db.execute('RELEASE SAVEPOINT update_resolved_kinds');
        }
      }
      final noise = items.where(_isNoise).map((item) => item.id).toList();
      if (noise.isNotEmpty) await removeAll(noise);
      final nonNoise = items.where((item) => !_isNoise(item)).toList();
      final kept = <NeedsReviewItem>[];
      final toRemove = <String>[];
      for (final item in nonNoise) {
        if (item.aiSuggestions != null && item.aiSuggestions!.isNotEmpty) {
          kept.add(item);
          continue;
        }
        if (item.kind != NeedsReviewKind.transaction) {
          kept.add(item);
          continue;
        }
        if (isMerchantReceiptOrEbill(item.body) &&
            _hasMatchingSpendTransaction(
              item,
              database: db,
              transactions: txns,
            )) {
          toRemove.add(item.id);
          continue;
        }

        final parsed = LocalSmsParser.parse(
          body: item.body,
          sender: item.sender,
          receivedAt: item.receivedAt,
          namespace: namespace,
        );

        if (parsed != null) {
          if (parsed.disposition == LocalSmsDisposition.localIgnore ||
              LocalSmsParser.isNonTransactionNoise(item.sender, item.body) ||
              isSecurityOrServiceAlert(item.body)) {
            toRemove.add(item.id);
            continue;
          }

          if (parsed.disposition == LocalSmsDisposition.sync &&
              parsed.transaction != null &&
              parsed.transaction!.entryKind == TxnEntryKind.spend) {
            final isWallet = parsed.transaction!.instrument == TxnInstrument.wallet;
            final cardMatches = parsed.cardLast4 != null &&
                _matchesUserCardSync(db, namespace, parsed.cardLast4!);
            if (isWallet || cardMatches) {
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

          if (parsed.disposition == LocalSmsDisposition.localCommitment ||
              parsed.reasonCodes.contains('mandate_notice') ||
              parsed.reasonCodes.contains('commitment_detected')) {
            _persistResolvedCommitmentSync(db, namespace, parsed, item);
            toRemove.add(item.id);
            continue;
          }

          if (parsed.eventType == LocalSmsEventType.bill && parsed.dueDate != null) {
            _persistResolvedBillObservationSync(db, namespace, parsed, item);
            toRemove.add(item.id);
            continue;
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
    final noise = items.where(_isNoise).map((item) => item.id).toList();
    if (noise.isNotEmpty) await removeAll(noise);
    final nonNoise = items.where((item) => !_isNoise(item)).toList();
    final kept = <NeedsReviewItem>[];
    final toRemove = <String>[];
    for (final item in nonNoise) {
      if (item.aiSuggestions != null && item.aiSuggestions!.isNotEmpty) {
        kept.add(item);
        continue;
      }
      if (item.kind != NeedsReviewKind.transaction) {
        kept.add(item);
        continue;
      }
      if (isMerchantReceiptOrEbill(item.body) &&
          _hasMatchingSpendTransaction(
            item,
            transactions: txns,
          )) {
        toRemove.add(item.id);
        continue;
      }
      final parsed = LocalSmsParser.parse(
        body: item.body,
        sender: item.sender,
        receivedAt: item.receivedAt,
        namespace: namespace,
      );
      if (parsed != null) {
        if (parsed.disposition == LocalSmsDisposition.localIgnore ||
            LocalSmsParser.isNonTransactionNoise(item.sender, item.body) ||
            isSecurityOrServiceAlert(item.body)) {
          toRemove.add(item.id);
          continue;
        }
        if (parsed.disposition == LocalSmsDisposition.sync &&
            parsed.transaction != null &&
            parsed.transaction!.entryKind == TxnEntryKind.spend) {
          final isWallet = parsed.transaction!.instrument == TxnInstrument.wallet;
          if (isWallet) {
            toRemove.add(item.id);
            continue;
          }
        }
        if (parsed.disposition == LocalSmsDisposition.localCommitment ||
            parsed.reasonCodes.contains('mandate_notice') ||
            parsed.reasonCodes.contains('commitment_detected')) {
          toRemove.add(item.id);
          continue;
        }
        if (parsed.eventType == LocalSmsEventType.bill && parsed.dueDate != null) {
          toRemove.add(item.id);
          continue;
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
    final text = body.toLowerCase();
    return RegExp(
      r'\b(?:transaction\s+check\s+alert|check\s+alert|confirm\s+(?:the\s+)?(?:following\s+)?txn|call\s+forwarding\b|sim\s+swap|service\s+alert|fraud\s+alert|suspicious\s+activity|'
      r'modification\s+success!?|card\s+usage\s+settings?|card\s+(?:usage\s+)?settings?\s+(?:for|modified|updated)|card\s+controls?\s+(?:modified|updated)|card\s+usage\s+(?:limits?|controls?|preferences?)|usage\s+(?:&|and)\s+transaction\s+limit|transaction\s+limits?\s+options?|limits?\s+(?:have|has)\s+been\s+updated|usage\s+options?\s+(?:have|has)\s+been\s+updated)\b|'
      r'\b(?:will\s+remain\s+open\s+and\s+fully\s+operational|available\s+at\s+our\s+branches\s+during\s+normal\s+working\s+hours|submission\s+of\s+positive\s+pay\s+details\s+is\s+mandatory)\b|'
      r'\bdone\s+\d+\s+out\s+of\s+\d+\s+free\s+transactions\s+at\s+[\w\s]+atms\b|'
      r'\b(?:cdsl|nsdl)\s*:\s*(?:debit|credit)\s+in\s+a/c\b[\s\S]{0,40}\b(?:etf|bees|shares?|units?|mf)\b|'
      r"\b(?:track\s+it\s+using\s+this\s+ticket\s+id|ticket\s+id\s*:\s*\d+\s+on\s+the\s+help\s+section|we're\s+on\s+it\s+and\s+will\s+get\s+back\s+to\s+you\s+in\s+\d+[-–]\d+\s+hours)\b|"
      r'\benable\s+online,\s+international\s+(?:and|&)\s+contactless\s+transactions\b|'
      r'\byour\s+ekyc\s+has\s+been\s+successfully\s+completed\b|'
      r'\bdue\s+to\s+scheduled\s+maintenance\b[\s\S]{0,60}\bwill\s+be\s+paused\b|'
      r'\b(?:bse\s+trade\s+confirmation|welcome\s+to\s+nse,\s+you\s+have\s+been\s+registered\b|registered\s+with\s+[\w\s]+in\s+segment(?:\(s\))?|registered\s+with\s+[\w\s]+in\s+segment\(s\))\b|'
      r'\b(?:puc\s+certificate\s+for\s+vehicle\b|your\s+itr\s+for\s+ay\b[\s\S]{0,30}\bawaits\s+at\s+the\s+e[- ]?filing\s+portal)\b|'
      r'\b(?:(?:last\s+chance\s*:?\s*)?renew\s+(?:your\s+)?expired\b|(?:(?:car|motor|two[ -]?wheeler|vehicle|bike|health)\s+)?insurance\s+will\s+expire\s+on\b|will\s+expire\s+on\b[\s\S]{0,80}\b(?:premium|insurance|renew|policy|visit|starts?\s+(?:just\s+)?(?:at\s+)?(?:rs\.?|inr)|instant\s+renewal)\b|\+\s*taxes\*?)\b|'
      r'\b(?:claim\s+your\s+[\w\s]+(?:insta\s+)?emi\s+card|avail\s+(?:credit\s+)?card\s+with\s+limit|eligible\s+for\s+(?:a\s+)?(?:[\w\s]{0,20}\s+)?loan\b|use\s+card\s+loan\s+limit\s+of\b|complete\s+your\s+[\w\s]+emi\s+card\s+application|pre[-\s]?approved\s+loan)\b|'
      r'\b(?:is\s+still\s+not\s+renewed|renew\s+to\s+avoid\s+unexpected\s+expenses|renew\s+before\s+expiry\s+on|registration\s+for\s+(?:fingerprint|face\s+id|biometric)|your\s+request\s+for\s+renewal\s+has\s+been\s+received\s+&\s+processed)\b',
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
    return RegExp(
      r'\b(?:auto[-\s]?pay|e[-\s]?mandate|standing\s+instruction)\b',
    ).hasMatch(text);
  }

  static NeedsReviewItem resolveItemKind(NeedsReviewItem item) {
    if (item.kind != NeedsReviewKind.transaction) return item;
    if (isSecurityOrServiceAlert(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.securityOrServiceAlert);
    }
    if (isInvestmentSettlement(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.investmentSettlement);
    }
    if (isMandateReview(item.body)) {
      return item.copyWith(kind: NeedsReviewKind.mandate);
    }
    return item;
  }

  static bool isMerchantReceiptOrEbill(String body) =>
      LocalSmsParser.isMerchantReceiptOrEbill(body);

  static bool hasMatchingSpendTransactionSync(
    AppDatabase database,
    String namespace,
    NeedsReviewItem item, {
    List<TransactionEntry>? transactions,
  }) {
    final extracted = LocalSmsParser.extractReceiptAmount(item.body);
    if (extracted == null || extracted.paise <= 0) return false;

    if (transactions != null && transactions.isNotEmpty) {
      for (final txn in transactions) {
        if (txn.entryKind != TxnEntryKind.spend) continue;
        if (txn.amount.paise != extracted.paise) continue;
        if (txn.occurredAt.difference(item.receivedAt).abs() <=
            const Duration(hours: 24)) {
          return true;
        }
      }
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

        final entryKind = data['entry_kind'] as String?;
        if (entryKind != null && entryKind.toLowerCase() != 'spend') continue;

        final paiseCol = row['amount_paise'] as int?;
        final amountInr = data['amount_inr'] as num?;
        var amountMatched = false;
        if (paiseCol != null) {
          amountMatched = paiseCol == extracted.paise;
        } else if (amountInr != null) {
          amountMatched = (amountInr * 100).round() == extracted.paise;
        } else if (data['amount'] is Map && (data['amount'] as Map)['paise'] is int) {
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
            const Duration(hours: 24)) {
          return true;
        }
      }
    } catch (_) {}

    return false;
  }

  bool _hasMatchingSpendTransaction(
    NeedsReviewItem item, {
    AppDatabase? database,
    List<TransactionEntry>? transactions,
  }) {
    final txns = transactions ?? existingTransactions;
    if (database != null) {
      return hasMatchingSpendTransactionSync(
        database,
        namespace,
        item,
        transactions: txns,
      );
    }
    final extracted = LocalSmsParser.extractReceiptAmount(item.body);
    if (extracted == null || extracted.paise <= 0) return false;
    if (txns != null) {
      for (final txn in txns) {
        if (txn.entryKind != TxnEntryKind.spend) continue;
        if (txn.amount.paise != extracted.paise) continue;
        if (txn.occurredAt.difference(item.receivedAt).abs() <=
            const Duration(hours: 24)) {
          return true;
        }
      }
    }
    return false;
  }

  static bool isNoiseItem(NeedsReviewItem item) {
    if (isSecurityOrServiceAlert(item.body)) {
      return true;
    }
    final resolved = resolveItemKind(item);
    if (resolved.kind == NeedsReviewKind.securityOrServiceAlert) {
      return true;
    }
    if (resolved.kind == NeedsReviewKind.investmentSettlement ||
        resolved.kind == NeedsReviewKind.mandate) {
      return false;
    }
    if (isMerchantReceiptOrEbill(resolved.body)) {
      return false;
    }
    return LocalSmsParser.isNonTransactionNoise(resolved.sender, resolved.body);
  }

  bool _isNoise(NeedsReviewItem item) => isNoiseItem(item);

  Future<void> add(
    NeedsReviewItem item, {
    List<TransactionEntry>? transactions,
  }) async {
    if (isNoiseItem(item)) return;
    final txns = transactions ?? existingTransactions;
    if (isMerchantReceiptOrEbill(item.body)) {
      if (loadDatabase != null) {
        final db = await _database();
        if (_hasMatchingSpendTransaction(item, database: db, transactions: txns)) {
          return;
        }
      } else if (_hasMatchingSpendTransaction(item, transactions: txns)) {
        return;
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

  /// Persists owner-scoped, validated Gemini facts onto an existing local
  /// review row. It deliberately never recreates a row that the user already
  /// dismissed or resolved while the network request was in flight.
  Future<bool> updateAiSuggestions(
    String id,
    List<Map<String, dynamic>> suggestions,
  ) async {
    final items = await fetchAll();
    final current = items.where((item) => item.id == id).firstOrNull;
    if (current == null ||
        jsonEncode(current.aiSuggestions ?? const []) ==
            jsonEncode(suggestions)) {
      return false;
    }
    final updated = jsonEncode(
      current.copyWith(aiSuggestions: suggestions).toJson(),
    );
    if (loadDatabase != null) {
      (await _database()).db.execute(
        'UPDATE local_needs_review SET payload=? WHERE namespace=? AND id=?',
        [updated, namespace, id],
      );
      return true;
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
      (await _database()).db.execute(
        'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
        [namespace, id],
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_needsReviewKey) ?? const [];
    final kept = raw
        .where((s) => (jsonDecode(s) as Map<String, dynamic>)['id'] != id)
        .toList();
    await prefs.setStringList(_needsReviewKey, kept);
  }

  Future<void> removeAll(Iterable<String> ids) async {
    final idList = ids.toList();
    if (idList.isEmpty) return;
    if (loadDatabase != null) {
      final db = await _database();
      db.db.execute('SAVEPOINT remove_all_needs_review');
      try {
        for (final id in idList) {
          db.db.execute(
            'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
            [namespace, id],
          );
        }
        db.db.execute('RELEASE SAVEPOINT remove_all_needs_review');
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
      database.db.execute('''
        INSERT INTO financial_entities(
          namespace, entity, id, payload, observed_at, pending, source_key, occurred_at, amount_paise
        ) VALUES (?, 'transactions', ?, ?, ?, 1, ?, ?, ?)
        ON CONFLICT(namespace, entity, id) DO UPDATE SET
          payload=excluded.payload, observed_at=excluded.observed_at,
          source_key=excluded.source_key, occurred_at=excluded.occurred_at,
          amount_paise=excluded.amount_paise
      ''', [
        namespace,
        txn.id,
        jsonEncode(txn.toJson()),
        txn.occurredAt.millisecondsSinceEpoch,
        sourceKey,
        txn.occurredAt.millisecondsSinceEpoch,
        txn.amount.paise,
      ]);
    } catch (_) {}
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
      };
      database.db.execute('''
        INSERT INTO financial_entities(
          namespace, entity, id, payload, observed_at, pending, source_key
        ) VALUES (?, 'sms_observations', ?, ?, ?, 0, ?)
        ON CONFLICT(namespace, entity, id) DO UPDATE SET
          payload=excluded.payload, observed_at=excluded.observed_at
      ''', [
        namespace,
        item.id,
        jsonEncode(obsPayload),
        item.receivedAt.millisecondsSinceEpoch,
        item.id,
      ]);
    } catch (_) {}
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
      final title = parsed.billerName ?? 'Subscription / Mandate';
      final commitment = Commitment(
        id: 'commitment:${item.id}',
        title: title,
        category: CommitmentCategory.fromText(title),
        amount: parsed.amountDue ?? parsed.autopayLimit ?? const Money.zero(),
        dueOn: parsed.dueDate ?? item.receivedAt,
        anchorDay: (parsed.dueDate ?? item.receivedAt).day,
        status: CommitmentStatus.due,
        source: CommitmentSource.sms,
        isUserConfirmed: false,
      );
      database.db.execute('''
        INSERT OR REPLACE INTO local_commitments VALUES (?, ?, ?)
      ''', [
        namespace,
        commitment.id,
        jsonEncode(commitment.toJson()),
      ]);
    } catch (_) {}
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
}
