import 'app_database.dart';

/// One stored merchant/category rule, in confidence-then-recency order.
typedef SmsMerchantCategoryRuleRow = ({
  String pattern,
  String categorySlug,
  double confidence,
  String source,
  int updatedAt,
  bool synced,
});

/// Closed-loop, local-first learning for SMS category corrections.
///
/// A correction is written to `user_merchant_category_rules` synchronously so
/// the very next capture can use it — no network hop, no AI round trip. The
/// local rule is authoritative until it is synced.
///
/// Server sync caveat: the existing POST /merchant-category-rules requires a
/// `sourceTransactionId` (see MerchantCategoryRulesRepository.create), which
/// only exists after the transaction has reached the server. A device-local
/// correction taken on an auto-resolved SMS therefore has no server id yet, so
/// this class exposes [pendingSync]/[markSynced] instead of inventing one.
/// Once the transaction is acknowledged by the server, the caller can create
/// the server rule through that repository and then call [markSynced].
class SmsLearningFeedback {
  final AppDatabase database;
  final String namespace;

  SmsLearningFeedback(this.database, {required this.namespace});

  void recordFalseTransactionRule({
    required String sender,
    required String body,
  }) {
    final pattern = contextPattern('IGNORE', sender, body);
    if (sender.trim().isEmpty || body.trim().isEmpty) return;
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS user_sms_ignore_rules (
        namespace TEXT NOT NULL,
        context_pattern TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY(namespace, context_pattern)
      )
    ''');
    database.db.execute(
      'INSERT OR REPLACE INTO user_sms_ignore_rules(namespace,context_pattern,created_at) VALUES (?,?,?)',
      [namespace, pattern, DateTime.now().millisecondsSinceEpoch],
    );
  }

  bool matchesFalseTransactionRuleSync({
    required String sender,
    required String body,
  }) {
    if (sender.trim().isEmpty || body.trim().isEmpty) return false;
    final tableExists = database.db.select(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='user_sms_ignore_rules' LIMIT 1",
    );
    if (tableExists.isEmpty) return false;
    final pattern = contextPattern('IGNORE', sender, body);
    return database.db.select(
      'SELECT 1 FROM user_sms_ignore_rules WHERE namespace=? AND context_pattern=? LIMIT 1',
      [namespace, pattern],
    ).isNotEmpty;
  }

  /// Deterministic so the same merchant always lands on the same primary key:
  /// trimmed, whitespace-collapsed, upper-cased. Never locale-aware, so a
  /// background isolate and the UI normalise identically.
  static String normalizePattern(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();

  /// A personal correction applies to the same message layout, not every
  /// payment at the merchant. Amounts, dates and reference digits vary across
  /// otherwise identical alerts; the remaining wording distinguishes, for
  /// example, a booking from a subscription renewal.
  static String contextPattern(
    String merchant,
    String sender,
    String body,
  ) {
    final template = normalizePattern(body)
        .replaceAll(RegExp(r'(?:RS\.?|INR|₹)\s*[\d,.]+'), ' AMOUNT ')
        .replaceAll(RegExp(r'\d+'), '#')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return 'CTX|${normalizePattern(merchant)}|${normalizePattern(sender)}|$template';
  }

  /// Upserts a user correction at full confidence. A later correction for the
  /// same pattern wins; `synced` resets to false because the server copy is
  /// now stale.
  void recordCategoryCorrection({
    required String merchantOrPattern,
    required String categorySlug,
    String? sender,
    String? sampleBody,
    String source = 'user',
    bool synced = false,
  }) {
    final pattern = sender != null && sampleBody != null && sampleBody.trim().isNotEmpty
        ? contextPattern(merchantOrPattern, sender, sampleBody)
        : normalizePattern(merchantOrPattern);
    final slug = categorySlug.trim().toLowerCase();
    if (pattern.isEmpty || slug.isEmpty) return;
    database.db.execute(
      '''INSERT INTO user_merchant_category_rules
           (namespace, pattern, category_slug, confidence, source, updated_at, synced)
         VALUES (?, ?, ?, 1.0, ?, ?, ?)
         ON CONFLICT(namespace, pattern) DO UPDATE SET
           category_slug = excluded.category_slug,
           confidence = excluded.confidence,
           source = excluded.source,
           updated_at = excluded.updated_at,
           synced = excluded.synced''',
      [
        namespace,
        pattern,
        slug,
        source,
        DateTime.now().millisecondsSinceEpoch,
        synced ? 1 : 0,
      ],
    );
  }

  /// Highest-confidence rule per pattern. Passed once per capture batch into
  /// [LocalSmsParser.parse], never looked up per message.
  Map<String, String> loadRulesSync() {
    final rows = database.db.select(
      'SELECT pattern, category_slug FROM user_merchant_category_rules '
      'WHERE namespace=? ORDER BY confidence DESC, updated_at DESC, pattern',
      [namespace],
    );
    return {
      for (final row in rows)
        row['pattern'] as String: row['category_slug'] as String,
    };
  }

  List<SmsMerchantCategoryRuleRow> loadRuleRowsSync() {
    final rows = database.db.select(
      'SELECT pattern, category_slug, confidence, source, updated_at, synced '
      'FROM user_merchant_category_rules WHERE namespace=? '
      'ORDER BY confidence DESC, updated_at DESC, pattern',
      [namespace],
    );
    return rows
        .map(
          (row) => (
            pattern: row['pattern'] as String,
            categorySlug: row['category_slug'] as String,
            confidence: (row['confidence'] as num?)?.toDouble() ?? 1.0,
            source: row['source'] as String? ?? 'user',
            updatedAt: (row['updated_at'] as num?)?.toInt() ?? 0,
            synced: (row['synced'] as num?)?.toInt() == 1,
          ),
        )
        .toList(growable: false);
  }

  /// Rules the server has not learned yet. Empty is the common case.
  List<({String pattern, String categorySlug})> pendingSync() {
    final rows = database.db.select(
      'SELECT pattern, category_slug FROM user_merchant_category_rules '
      'WHERE namespace=? AND synced=0 ORDER BY updated_at',
      [namespace],
    );
    return [
      for (final row in rows)
        (
          pattern: row['pattern'] as String,
          categorySlug: row['category_slug'] as String,
        ),
    ];
  }

  void markSynced(String pattern) {
    final normalized = normalizePattern(pattern);
    if (normalized.isEmpty) return;
    database.db.execute(
      'UPDATE user_merchant_category_rules SET synced=1 '
      'WHERE namespace=? AND pattern=?',
      [namespace, normalized],
    );
  }
}
