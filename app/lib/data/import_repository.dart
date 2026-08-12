import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'api_exception.dart';

double? _numOrNull(dynamic v) {
  if (v == null) return null;
  return v is num ? v.toDouble() : double.tryParse(v as String);
}

/// Group F (Data Import & Sync) — implementation-plan-group-e-f-g.md §3.
/// One repository for every F-screen's backend calls, same one-repo-per-
/// domain-area shape as UserCardsRepository — these routes are all new
/// this pass (api/src/index.js, Task F-0's scope decision) and don't share
/// enough with wallet/transaction concerns to belong in that file.
class ImportRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  ImportRepository({required this.apiBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  // ---- F3 Email Forwarding -------------------------------------------------

  Future<ForwardingAddress?> fetchForwardingAddress() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/forwarding-addresses/me'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /forwarding-addresses/me failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final row = body['forwardingAddress'];
    return row == null ? null : ForwardingAddress.fromJson(row as Map<String, dynamic>);
  }

  Future<ForwardingAddress> issueForwardingAddress() async {
    final response = await _client.post(Uri.parse('$apiBaseUrl/forwarding-addresses'), headers: _headers);
    if (response.statusCode != 201) {
      throw ApiException('POST /forwarding-addresses failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ForwardingAddress.fromJson(body['forwardingAddress'] as Map<String, dynamic>);
  }

  /// GET /inbound-emails/me — real data as of the email-ingestion webhook
  /// (POST /inbound-emails/webhook, api/src/index.js): once a provider
  /// forwards a real email there, it shows up here. Empty until that's
  /// wired up in a given deployment (DNS/webhook config is an infra step,
  /// not something this app does at runtime) — an honest empty state, not
  /// a fake one.
  Future<List<InboundEmail>> fetchInboundEmails() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/inbound-emails/me'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /inbound-emails/me failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['inboundEmails'] as List).cast<Map<String, dynamic>>().map(InboundEmail.fromJson).toList();
  }

  Future<void> createTransactionFromInboundEmail({
    required String inboundEmailId,
    required String userCardId,
    String? categoryId,
    String? rail,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/inbound-emails/$inboundEmailId/create-transaction'),
      headers: _headers,
      body: jsonEncode({
        'userCardId': userCardId,
        'categoryId': ?categoryId,
        'rail': ?rail,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /inbound-emails/:id/create-transaction failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  // ---- F2 Statement PDF Import ----------------------------------------------

  Future<List<StatementImport>> fetchStatementImports() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/statement-imports'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /statement-imports failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['statementImports'] as List)
        .cast<Map<String, dynamic>>()
        .map(StatementImport.fromJson)
        .toList();
  }

  Future<StatementImport> confirmStatementImport({
    required String userCardId,
    required DateTime statementFrom,
    required DateTime statementTo,
    Money? closingBalance,
    double? pointsPosted,
    required int txnCount,
    required int reconciledCount,
    String? issuerFormatId,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/statement-imports'),
      headers: _headers,
      body: jsonEncode({
        'userCardId': userCardId,
        'statementFrom': _dateOnly(statementFrom),
        'statementTo': _dateOnly(statementTo),
        if (closingBalance != null) 'closingBalanceInr': closingBalance.rupees,
        'pointsPosted': ?pointsPosted,
        'txnCount': txnCount,
        'reconciledCount': reconciledCount,
        'issuerFormatId': ?issuerFormatId,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /statement-imports failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return StatementImport.fromJson(body['statementImport'] as Map<String, dynamic>);
  }

  // ---- F4 SMS backup-file import --------------------------------------------

  Future<List<SmsImportBatch>> fetchSmsImportBatches() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/sms-import-batches'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /sms-import-batches failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['smsImportBatches'] as List)
        .cast<Map<String, dynamic>>()
        .map(SmsImportBatch.fromJson)
        .toList();
  }

  Future<SmsImportBatch> recordSmsImportBatch({
    required int messageCount,
    required int parsedCount,
    required int failedCount,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/sms-import-batches'),
      headers: _headers,
      body: jsonEncode({
        'messageCount': messageCount,
        'parsedCount': parsedCount,
        'failedCount': failedCount,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /sms-import-batches failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return SmsImportBatch.fromJson(body['smsImportBatch'] as Map<String, dynamic>);
  }

  // ---- F5 Sync & Backup (status only — see GET /backup-status doc-comment) --

  Future<BackupStatus> fetchBackupStatus() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/backup-status'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /backup-status failed: ${response.statusCode} ${response.body}');
    }
    return BackupStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Removed, not renamed: there is no longer anything for it to trigger.
  ///
  /// `POST /backup-runs` used to insert a `backup_runs` row claiming success
  /// while running no backup, and this method reported that as a success to
  /// the user. Real backups now run on a schedule as ops infrastructure
  /// (`db/scripts/backup.sh` + `restore_drill.sh`), and the route answers 409
  /// rather than fabricating a run. The screen shows the real last-backup time
  /// from [fetchBackupStatus] instead of offering a button that does nothing.
  @Deprecated(
    'Backups run on a schedule; there is nothing to trigger from the app. '
    'Read the real state from fetchBackupStatus() instead.',
  )
  Future<void> triggerBackupNow() {
    throw UnsupportedError(
      'Manual backups are not supported — see db/scripts/backup.sh',
    );
  }

  // ---- F6 Data Export --------------------------------------------------------

  /// Returns (raw response body, suggested filename, MIME type) — the
  /// screen hands this to the platform share sheet. Positional record type
  /// (Dart doesn't allow naming positional record fields in a type
  /// signature, only via `({...})` named records) — callers destructure it
  /// positionally, e.g. `final (body, filename, mime) = await ...`.
  Future<(String, String, String)> fetchExport({required String scope, required String format}) async {
    final uri = Uri.parse('$apiBaseUrl/export').replace(queryParameters: {'scope': scope, 'format': format});
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /export failed: ${response.statusCode} ${response.body}');
    }
    final mime = format == 'csv' ? 'text/csv' : 'application/json';
    return (response.body, 'pandapay-export-$scope.$format', mime);
  }

  // ---- F7 IMAP Connection -----------------------------------------------------

  Future<ImapConnection?> fetchImapConnection() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/imap-connections/me'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /imap-connections/me failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final row = body['imapConnection'];
    return row == null ? null : ImapConnection.fromJson(row as Map<String, dynamic>);
  }

  Future<ImapConnection> saveImapConnection({
    required String email,
    required String appPassword,
    required String imapHost,
    int imapPort = 993,
    String? senderFilter,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/imap-connections'),
      headers: _headers,
      body: jsonEncode({
        'email': email,
        'appPassword': appPassword,
        'imapHost': imapHost,
        'imapPort': imapPort,
        if (senderFilter != null && senderFilter.isNotEmpty) 'senderFilter': senderFilter,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /imap-connections failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ImapConnection.fromJson(body['imapConnection'] as Map<String, dynamic>);
  }

  Future<ImapTestResult> testImapConnection(String id) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/imap-connections/$id/test'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException('POST /imap-connections/:id/test failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ImapTestResult(
      ok: body['ok'] as bool? ?? false,
      reason: body['reason'] as String?,
      connection: ImapConnection.fromJson(body['connection'] as Map<String, dynamic>),
    );
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// F3. `firstEmailAt`/`emailCount` stay null/0 forever without a real
/// inbound-email receiver wired up server-side (see POST
/// /forwarding-addresses' doc-comment) — the screen must render that as
/// "waiting", never fabricate a "connected" state.
class ForwardingAddress {
  final String id;
  final String localPart;
  final bool isActive;
  final DateTime? verifiedAt;
  final DateTime? firstEmailAt;
  final int emailCount;

  const ForwardingAddress({
    required this.id,
    required this.localPart,
    required this.isActive,
    this.verifiedAt,
    this.firstEmailAt,
    required this.emailCount,
  });

  String get fullAddress => '$localPart@in.pandapay.app';

  factory ForwardingAddress.fromJson(Map<String, dynamic> json) => ForwardingAddress(
    id: json['id'] as String,
    localPart: json['local_part'] as String,
    isActive: json['is_active'] as bool? ?? true,
    verifiedAt: json['verified_at'] == null ? null : DateTime.parse(json['verified_at'] as String),
    firstEmailAt: json['first_email_at'] == null ? null : DateTime.parse(json['first_email_at'] as String),
    emailCount: (json['email_count'] as num?)?.toInt() ?? 0,
  );
}

class InboundEmail {
  final String id;
  final String? sender;
  final String? subject;
  final DateTime receivedAt;
  final bool isKnownBankSender;
  final bool? parsedOk;
  final String? producedTxnId;

  const InboundEmail({
    required this.id,
    this.sender,
    this.subject,
    required this.receivedAt,
    required this.isKnownBankSender,
    this.parsedOk,
    this.producedTxnId,
  });

  factory InboundEmail.fromJson(Map<String, dynamic> json) => InboundEmail(
    id: json['id'] as String,
    sender: json['sender'] as String?,
    subject: json['subject'] as String?,
    receivedAt: DateTime.parse(json['received_at'] as String),
    isKnownBankSender: json['is_known_bank_sender'] as bool? ?? false,
    parsedOk: json['parsed_ok'] as bool?,
    producedTxnId: json['produced_txn_id'] as String?,
  );
}

/// F2.
class StatementImport {
  final String id;
  final String userCardId;
  final DateTime statementFrom;
  final DateTime statementTo;
  final Money? closingBalance;
  final double? pointsPosted;
  final int txnCount;
  final int reconciledCount;
  final DateTime importedAt;

  const StatementImport({
    required this.id,
    required this.userCardId,
    required this.statementFrom,
    required this.statementTo,
    this.closingBalance,
    this.pointsPosted,
    required this.txnCount,
    required this.reconciledCount,
    required this.importedAt,
  });

  factory StatementImport.fromJson(Map<String, dynamic> json) => StatementImport(
    id: json['id'] as String,
    userCardId: json['user_card_id'] as String,
    statementFrom: DateTime.parse(json['statement_from'] as String),
    statementTo: DateTime.parse(json['statement_to'] as String),
    closingBalance: _numOrNull(json['closing_balance_inr']) == null
        ? null
        : Money.fromRupees(_numOrNull(json['closing_balance_inr'])!),
    pointsPosted: _numOrNull(json['points_posted']),
    txnCount: (json['txn_count'] as num?)?.toInt() ?? 0,
    reconciledCount: (json['reconciled_count'] as num?)?.toInt() ?? 0,
    importedAt: DateTime.parse(json['imported_at'] as String),
  );
}

/// F4 backup-file import summary.
class SmsImportBatch {
  final String id;
  final int messageCount;
  final int parsedCount;
  final int failedCount;
  final DateTime importedAt;

  const SmsImportBatch({
    required this.id,
    required this.messageCount,
    required this.parsedCount,
    required this.failedCount,
    required this.importedAt,
  });

  factory SmsImportBatch.fromJson(Map<String, dynamic> json) => SmsImportBatch(
    id: json['id'] as String,
    messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
    parsedCount: (json['parsed_count'] as num?)?.toInt() ?? 0,
    failedCount: (json['failed_count'] as num?)?.toInt() ?? 0,
    importedAt: DateTime.parse(json['imported_at'] as String),
  );
}

/// F5 — see GET /backup-status' doc-comment for why this is ops-wide
/// backup/restore status + a per-user conflict LOG, not a live sync engine.
class BackupStatus {
  final DateTime? latestBackupRanAt;
  final String? latestBackupStatus;
  final DateTime? latestRestoreDrillRanAt;
  final bool? latestRestoreDrillOk;
  final List<SyncConflict> conflicts;

  const BackupStatus({
    this.latestBackupRanAt,
    this.latestBackupStatus,
    this.latestRestoreDrillRanAt,
    this.latestRestoreDrillOk,
    this.conflicts = const [],
  });

  factory BackupStatus.fromJson(Map<String, dynamic> json) {
    final backup = json['latestBackup'] as Map<String, dynamic>?;
    final drill = json['latestRestoreDrill'] as Map<String, dynamic>?;
    return BackupStatus(
      latestBackupRanAt: backup?['ran_at'] == null ? null : DateTime.parse(backup!['ran_at'] as String),
      latestBackupStatus: backup?['status'] as String?,
      latestRestoreDrillRanAt: drill?['ran_at'] == null ? null : DateTime.parse(drill!['ran_at'] as String),
      latestRestoreDrillOk: drill?['restored_ok'] as bool?,
      conflicts: (json['conflicts'] as List? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(SyncConflict.fromJson)
          .toList(),
    );
  }
}

class SyncConflict {
  final String id;
  final String entity;
  final String field;
  final String strategy;
  final bool userAcknowledged;
  final DateTime createdAt;

  /// The values, added for plan Phase 4. The model previously dropped them,
  /// so the conflict log could only ever say "transactions.merchant_name —
  /// resolved via last_write_wins", which tells a user nothing they can act
  /// on. The whole reason `sync_conflicts` records a losing value instead of
  /// discarding it is so it can be shown; without these fields it couldn't be.
  final Object? localValue;
  final Object? serverValue;
  final Object? chosenValue;

  const SyncConflict({
    required this.id,
    required this.entity,
    required this.field,
    required this.strategy,
    required this.userAcknowledged,
    required this.createdAt,
    this.localValue,
    this.serverValue,
    this.chosenValue,
  });

  factory SyncConflict.fromJson(Map<String, dynamic> json) => SyncConflict(
    id: json['id'] as String,
    entity: json['entity'] as String,
    field: json['field'] as String,
    strategy: json['strategy'] as String,
    userAcknowledged: json['user_acknowledged'] as bool? ?? false,
    createdAt: DateTime.parse(json['created_at'] as String),
    localValue: json['local_value'],
    serverValue: json['server_value'],
    chosenValue: json['chosen_value'],
  );

  /// The value that was discarded, or null when nothing was lost.
  Object? get discardedValue {
    final chosen = jsonEncode(chosenValue);
    if (jsonEncode(localValue) != chosen) return localValue;
    if (jsonEncode(serverValue) != chosen) return serverValue;
    return null;
  }
}

/// F7. Never carries the app password (server never returns it — see GET
/// /imap-connections/me's doc-comment).
class ImapConnection {
  final String id;
  final String email;
  final String imapHost;
  final int imapPort;
  final String? senderFilter;
  final bool isActive;
  final DateTime? verifiedAt;
  final DateTime? lastPollAt;
  final String? lastPollStatus;

  const ImapConnection({
    required this.id,
    required this.email,
    required this.imapHost,
    required this.imapPort,
    this.senderFilter,
    required this.isActive,
    this.verifiedAt,
    this.lastPollAt,
    this.lastPollStatus,
  });

  factory ImapConnection.fromJson(Map<String, dynamic> json) => ImapConnection(
    id: json['id'] as String,
    email: json['email'] as String,
    imapHost: json['imap_host'] as String,
    imapPort: (json['imap_port'] as num?)?.toInt() ?? 993,
    senderFilter: json['sender_filter'] as String?,
    isActive: json['is_active'] as bool? ?? true,
    verifiedAt: json['verified_at'] == null ? null : DateTime.parse(json['verified_at'] as String),
    lastPollAt: json['last_poll_at'] == null ? null : DateTime.parse(json['last_poll_at'] as String),
    lastPollStatus: json['last_poll_status'] as String?,
  );
}

class ImapTestResult {
  final bool ok;
  final String? reason;
  final ImapConnection connection;
  const ImapTestResult({required this.ok, this.reason, required this.connection});
}
