import Foundation
// The app links SQLCipher, whose headers shadow the system SQLite3 module and
// stop it compiling. The spool is a plain (unkeyed) database, which SQLCipher
// opens like ordinary SQLite, so the iOS app uses SQLCipher's module and the Mac test harness uses SQLite3.
#if os(iOS)
import SQLCipher
#else
import SQLite3
#endif
import CryptoKit

/// Private acquisition storage, separate from the shared financial database.
/// SQLite transactions arbitrate cold App Intent invocations and Flutter drains.
/// Nothing in this store uploads content or decides whether an SMS is financial.
enum IncomingSmsError: Error, LocalizedError {
  case storage, inactive, stale, invalid, full, cipher, keyUnavailable
  var errorDescription: String? {
    switch self {
    case .storage: return "Message storage is unavailable. Retry from PandaPay."
    case .inactive: return "Enable SMS Shortcuts in PandaPay while signed in first."
    case .stale: return "This import is no longer current. Continue from PandaPay."
    case .invalid: return "The message import request is incomplete. Check its Shortcut mappings."
    case .full: return "Message processing is pending. Open PandaPay before importing more."
    case .cipher: return "A saved message could not be read."
    case .keyUnavailable: return "Saved messages are locked. Unlock your phone and try again."
    }
  }
}

enum SmsHistoryStage: String {
  case windowStart = "window_start", windowEnd = "window_end", capture, finish
}

enum SmsHandoffStage: String {
  case launchRequested = "launch_requested", resumeRequested = "resume_shortcuts"
  case resumeStalled = "resume_stalled", appReturnRequested = "app_return_requested", appReturnUnavailable = "app_return_unavailable"
  case returnedSuccess = "returned_success", returnedCancel = "returned_cancel", returnedError = "returned_error"
}

final class IncomingSmsSpool {
  static let shared = IncomingSmsSpool()
  private let directory: URL
  private let maxPending: Int
  private let lock = NSLock()
  private let now: () -> Date
  private let receiverBuild: String?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  /// Set by `purge`; the key is destroyed right after the emptying transaction
  /// commits, still under `lock`, so a rollback never strands readable rows.
  private var destroyKeyAfterCommit = false

  init(directory: URL? = nil, maxPending: Int = 10_000, now: @escaping () -> Date = Date.init,
       receiverBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
    self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PandaPaySmsIntake", isDirectory: true)
    self.maxPending = maxPending
    self.now = now
    self.receiverBuild = receiverBuild.flatMap {
      !$0.isEmpty && $0.utf8.count <= 32 && $0.unicodeScalars.allSatisfy { "0123456789.".unicodeScalars.contains($0) } ? $0 : nil
    }
  }

  private func execute(_ db: OpaquePointer, _ sql: String, _ values: [Any?] = []) throws {
    _ = try query(db, sql, values)
  }

  private func query(_ db: OpaquePointer, _ sql: String, _ values: [Any?] = []) throws -> [[String: Any]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw IncomingSmsError.storage }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      if value == nil || value is NSNull { result = sqlite3_bind_null(statement, index) }
      else if let text = value as? String { result = sqlite3_bind_text(statement, index, text, -1, transient) }
      else if let number = value as? Int { result = sqlite3_bind_int64(statement, index, Int64(number)) }
      else { throw IncomingSmsError.invalid }
      guard result == SQLITE_OK else { throw IncomingSmsError.storage }
    }
    var rows: [[String: Any]] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return rows }
      guard result == SQLITE_ROW else { throw IncomingSmsError.storage }
      var row: [String: Any] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, column))
        case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
        default: break
        }
      }
      rows.append(row)
    }
  }

  private func transaction<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
    lock.lock(); defer { lock.unlock() }
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var protectedDirectory = directory
    var resource = URLResourceValues(); resource.isExcludedFromBackup = true
    try protectedDirectory.setResourceValues(resource)
#if os(iOS)
    try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
#endif
    var connection: OpaquePointer?
    guard sqlite3_open_v2(directory.appendingPathComponent("handoff.sqlite").path, &connection,
                         SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          let db = connection else {
      if let connection { sqlite3_close(connection) }
      throw IncomingSmsError.storage
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 1500)
    let schemaVersion = try query(db, "PRAGMA user_version").first?["user_version"] as? Int ?? 0
    guard schemaVersion <= 2 else { throw IncomingSmsError.storage }
    // FULL durability and DELETE journal keep raw input out of a persistent WAL.
    guard sqlite3_exec(db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;", nil, nil, nil) == SQLITE_OK else { throw IncomingSmsError.storage }
    try execute(db, "CREATE TABLE IF NOT EXISTS owner (id INTEGER PRIMARY KEY CHECK(id=1), namespace TEXT NOT NULL, generation TEXT NOT NULL, enabled INTEGER NOT NULL)")
    try execute(db, "CREATE TABLE IF NOT EXISTS captures (id TEXT PRIMARY KEY, generation TEXT NOT NULL, occurrence TEXT UNIQUE, body TEXT, sender TEXT, received_at TEXT, captured_at TEXT NOT NULL, date_provenance TEXT, state TEXT NOT NULL, outcome TEXT, source_key TEXT, parser_version INTEGER)")
    try execute(db, "CREATE INDEX IF NOT EXISTS pending_sms ON captures(generation,state,captured_at)")
    try execute(db, "CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, generation TEXT NOT NULL, kind TEXT NOT NULL, state TEXT NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL, zone TEXT NOT NULL)")
    try execute(db, "CREATE TABLE IF NOT EXISTS windows (id TEXT PRIMARY KEY, job_id TEXT NOT NULL, ordinal INTEGER NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL, state TEXT NOT NULL, attempt TEXT UNIQUE, found INTEGER, limit_off INTEGER, warning INTEGER NOT NULL DEFAULT 0)")
    try execute(db, "CREATE TABLE IF NOT EXISTS receipts (attempt TEXT NOT NULL, item_id TEXT NOT NULL, capture_id TEXT, outcome TEXT NOT NULL, PRIMARY KEY(attempt,item_id))")
    try execute(db, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    try execute(db, "BEGIN IMMEDIATE")
    do {
      // Migrations run under the same writer lock as acquisition, including
      // simultaneous first calls from separate App Intent processes.
      let receiptColumns = try query(db, "PRAGMA table_info(receipts)")
      if !receiptColumns.contains(where: { $0["name"] as? String == "binding" }) {
        try execute(db, "ALTER TABLE receipts ADD COLUMN binding TEXT")
      }
      let windowColumns = try query(db, "PRAGMA table_info(windows)")
      if !windowColumns.contains(where: { $0["name"] as? String == "logical_id" }) {
        try execute(db, "ALTER TABLE windows ADD COLUMN logical_id TEXT")
        try execute(db, "ALTER TABLE windows ADD COLUMN month_label TEXT")
        try execute(db, "UPDATE windows SET logical_id=id,month_label=substr(start,1,7)")
      }
      if !windowColumns.contains(where: { $0["name"] as? String == "issued_end" }) {
        // A capped window's coverage can shrink after its request was issued;
        // keep the issued end so that request still validates.
        try execute(db, "ALTER TABLE windows ADD COLUMN issued_end TEXT")
      }
      try execute(db, "PRAGMA user_version=2")
      let value = try operation(db)
      try execute(db, "COMMIT")
      if destroyKeyAfterCommit {
        destroyKeyAfterCommit = false
        SpoolCipher.destroyKey()
      }
      return value
    } catch {
      destroyKeyAfterCommit = false
      try? execute(db, "ROLLBACK")
      throw error
    }
  }

  private func owner(_ db: OpaquePointer, generation: String? = nil) throws -> [String: Any] {
    guard let row = try query(db, "SELECT * FROM owner WHERE id=1 AND enabled=1").first else { throw IncomingSmsError.inactive }
    if let generation, row["generation"] as? String != generation { throw IncomingSmsError.stale }
    return row
  }

  private func purge(_ db: OpaquePointer) throws {
    for table in ["receipts", "windows", "jobs", "captures", "settings", "owner"] { try execute(db, "DELETE FROM \(table)") }
    destroyKeyAfterCommit = true
  }

  /// Account switches revoke all issued attempts. Enable requires explicit UI consent.
  /// A cold launch must not send a transient signed-out value here.
  func configure(namespace: String, enabled: Bool? = nil, reset: Bool = false, parserVersion: Int = 0) throws -> [String: Any] {
    try transaction { db in
      let old = try query(db, "SELECT * FROM owner WHERE id=1").first
      let valid = namespace.hasPrefix("user:") && namespace.utf8.count < 256
      if old?["namespace"] as? String != namespace || reset || !valid {
        try purge(db)
        if valid {
          try execute(db, "INSERT INTO owner VALUES(1,?,?,?)", [namespace, UUID().uuidString, enabled == true ? 1 : 0])
        }
      } else if let enabled {
        if !enabled {
          try purge(db)
          try execute(db, "INSERT INTO owner VALUES(1,?,?,0)", [namespace, UUID().uuidString])
        } else { try execute(db, "UPDATE owner SET enabled=1 WHERE id=1") }
      }
      if valid {
        try execute(db, "INSERT INTO settings VALUES('parserVersion',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [String(parserVersion)])
        if enabled == true {
          try execute(db, "INSERT OR IGNORE INTO settings VALUES('enabledAt',?)", [stamp(now())])
        }
      }
      return try snapshot(db)
    }
  }

  private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func requireCapacity(_ db: OpaquePointer, body: String) throws {
    let count = try query(db, "SELECT COUNT(*) AS count,COALESCE(SUM(length(CAST(body AS BLOB))),0) AS bytes FROM captures WHERE state='pending'").first!
    guard (count["count"] as! Int) < maxPending, (count["bytes"] as! Int) + body.utf8.count <= 24_000_000 else { throw IncomingSmsError.full }
  }

  static func date(_ value: String) -> Date? {
    guard value.range(of: #"(?:Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil else { return nil }
    let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  /// Persisted request contains no SMS or credentials. Equality with issued bounds,
  /// generation and attempt is checked on every action; a callback is never proof.
  private func window(_ db: OpaquePointer, request: String) throws -> [String: Any] {
    guard request.utf8.count < 4096, let data = request.data(using: .utf8),
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["version"] as? Int == 3,
          let token = value["attempt"] as? String, let generation = value["generation"] as? String,
          let row = try query(db, "SELECT w.*,j.generation,j.kind,j.state AS job_state FROM windows w JOIN jobs j ON j.id=w.job_id WHERE w.attempt=?", [token]).first,
          row["generation"] as? String == generation,
          row["start"] as? String == value["start_inclusive"] as? String,
          (row["end"] as? String == value["end_exclusive"] as? String ||
           (row["issued_end"] as? String != nil && row["issued_end"] as? String == value["end_exclusive"] as? String)),
          (row["job_state"] as? String == "active" ||
           (row["job_state"] as? String == "complete" && row["state"] as? String == "complete")),
          ["waiting", "running", "finished", "complete", "partial"].contains(row["state"] as? String ?? "") else { throw IncomingSmsError.stale }
    _ = try owner(db, generation: generation)
    return row
  }

  private func recordStage(_ db: OpaquePointer, window: [String: Any], stage: SmsHistoryStage) throws {
    guard let attempt = window["attempt"] as? String else { return }
    if stage == .capture, let receiverBuild {
      // Build evidence is safe metadata, scoped to the handler's actual
      // attempt. A launch/queued window must not inherit an old build stamp.
      try execute(db, "INSERT INTO settings VALUES('last_receiver_attempt',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [attempt])
      try execute(db, "INSERT INTO settings VALUES('last_receiver_build',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [receiverBuild])
    }
    let previous = try query(db, "SELECT key,value FROM settings WHERE key IN ('last_intent_attempt','last_intent_stage')")
    if previous.contains(where: { $0["key"] as? String == "last_intent_attempt" && $0["value"] as? String == attempt }),
       previous.contains(where: { $0["key"] as? String == "last_intent_stage" && $0["value"] as? String == stage.rawValue }) { return }
    try execute(db, "INSERT INTO settings VALUES('last_intent_attempt',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [attempt])
    try execute(db, "INSERT INTO settings VALUES('last_intent_stage',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [stage.rawValue])
  }

  func boundary(request: String, end: Bool, observingIntent: Bool = false) throws -> Date {
    try transaction { db in
      let row = try window(db, request: request)
      guard let text = row[end ? "end" : "start"] as? String, let date = Self.date(text) else { throw IncomingSmsError.invalid }
      // App-side launch validation also reads this boundary. Only an actual
      // Start/End App Intent opts into this observation; validation is not proof
      // that Shortcuts ran. No body, sender or date is logged by the trace.
      if observingIntent { try recordStage(db, window: row, stage: end ? .windowEnd : .windowStart) }
      // Query a one-second superset for Shortcuts' strict/inclusive date
      // operators. Capture still enforces the exact issued half-open range.
      return end ? date : date.addingTimeInterval(-1)
    }
  }

  /// Safe acquisition metadata only. Returning to Shortcuts is admitted only
  /// after every receipt and shared processing acknowledgement has committed.
  @discardableResult
  /// Whether two issued requests belong to the same active import.
  func sameImport(_ first: String, _ second: String) -> Bool {
    (try? transaction { db in
      let a = try window(db, request: first), b = try window(db, request: second)
      return a["job_id"] as? String == b["job_id"] as? String
    }) ?? false
  }

  func observeHandoff(request: String, stage: SmsHandoffStage, expectedReceived: Int? = nil) throws -> Bool {
    try transaction { db in
      let row = try window(db, request: request)
      if stage == .resumeRequested && row["state"] as? String != "complete" { return false }
      if stage == .resumeStalled {
        // A looping run moves on to later ranges, so judge the whole import:
        // it must still have a range in progress and no new message since
        // PandaPay last looked.
        guard let expectedReceived, expectedReceived >= 0,
              try query(db, "SELECT 1 FROM windows WHERE job_id=? AND state IN ('waiting','running','finished') LIMIT 1", [row["job_id"]]).first != nil,
              try query(db, "SELECT COUNT(*) AS count FROM receipts r JOIN windows w ON w.attempt=r.attempt WHERE w.job_id=?", [row["job_id"]]).first?["count"] as? Int == expectedReceived else { return false }
      }
      if stage == .appReturnRequested || stage == .appReturnUnavailable {
        guard ["waiting", "running", "finished"].contains(row["state"] as? String ?? "") else { return false }
      }
      try execute(db, "INSERT INTO settings VALUES('last_handoff_attempt',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [row["attempt"]])
      try execute(db, "INSERT INTO settings VALUES('last_handoff_stage',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [stage.rawValue])
      return true
    }
  }

  func capture(body: String?, sender: String?, receivedAt: Date?, provenance: String,
               request: String? = nil, itemID: String? = nil, useMessageReceipt: Bool = false,
               senderInput: String? = nil) throws -> String {
    try transaction { db in
      let account = try owner(db)
      let generation = account["generation"] as! String
      var issued: [String: Any]?
      var receiptID = itemID
      if let request {
        issued = try window(db, request: request)
        if useMessageReceipt {
          guard itemID == nil else { throw IncomingSmsError.invalid }
        } else {
          guard let itemID, !itemID.isEmpty, itemID.utf8.count <= 80 else { throw IncomingSmsError.invalid }
        }
      } else if useMessageReceipt {
        throw IncomingSmsError.invalid
      } else {
        // Proof the live automation fires, whatever the message turns out
        // to be (OTPs and personal texts count too).
        try execute(db, "INSERT INTO settings VALUES('last_live_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [stamp(now())])
      }
      // Missing metadata is not a reason to discard a valid message body.
      // Keep an unknown sender explicit; shared intake routes financial
      // candidates to review instead of manufacturing a trusted bank header.
      let senderText = (sender?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? "" : sender!
      if let issued {
        try recordStage(db, window: issued, stage: .capture)
        let input = senderInput ?? (senderText.isEmpty ? "missing" : "text")
        guard ["missing", "text", "person_handle", "person_without_handle"].contains(input) else { throw IncomingSmsError.invalid }
        try execute(db, "INSERT INTO settings VALUES('last_sender_attempt',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [issued["attempt"]])
        try execute(db, "INSERT INTO settings VALUES('last_sender_input',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [input])
      }
      let rejection: String? = {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf16.count <= 20_000 else { return "invalid_body" }
        if SmsSecurityPolicy.sensitive(body) { return "excluded_security" }
        guard senderText.utf8.count <= 512 else { return "missing_sender" }
        guard let receivedAt, ["original", "estimated"].contains(provenance), receivedAt.timeIntervalSince1970 > 0,
              receivedAt <= now().addingTimeInterval(300) else { return "missing_date" }
        if let issued {
          guard provenance == "original" else { return "missing_date" }
          if receivedAt < Self.date(issued["start"] as! String)! || receivedAt >= Self.date(issued["end"] as! String)! { return "outside_window" }
        }
        return nil
      }()
      var binding: String?
      if rejection == nil || rejection == "outside_window" {
        let data = try JSONSerialization.data(withJSONObject: [senderText, body!, stamp(receivedAt!), provenance], options: [.withoutEscapingSlashes])
        binding = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }
      if useMessageReceipt {
        // Only validated, nonsensitive fields are hashed. Security/invalid
        // input gets an opaque receipt: never persist an OTP/body digest.
        // Equal original sender/body/date identities share one receipt. If
        // Find reports more rows, Finish conservatively remains partial.
        receiptID = binding.map { "message:" + $0 } ?? "redacted:" + UUID().uuidString
      }
      if let issued, let receiptID {
        if let previous = try query(db, "SELECT outcome,binding FROM receipts WHERE attempt=? AND item_id=?", [issued["attempt"], receiptID]).first {
          // Find results can reorder between retries. Repeat Index alone must
          // never acknowledge a different SMS under the old item's receipt.
          let sameAcceptedInput = binding != nil && previous["binding"] as? String == binding
          let sameRejectedKind = binding == nil && rejection != nil && previous["outcome"] as? String == rejection
          guard sameAcceptedInput || sameRejectedKind else { throw IncomingSmsError.stale }
          return previous["outcome"] as! String
        }
        guard ["waiting", "running"].contains(issued["state"] as? String ?? "") else { throw IncomingSmsError.stale }
      }
      func receipt(_ outcome: String, capture: String? = nil) throws -> String {
        if let issued, let receiptID {
          try execute(db, "INSERT INTO receipts(attempt,item_id,capture_id,outcome,binding) VALUES(?,?,?,?,?)", [issued["attempt"], receiptID, capture, outcome, binding])
          try execute(db, "UPDATE windows SET state='running' WHERE id=?", [issued["id"]])
        }
        try execute(db, "INSERT INTO settings VALUES('last_capture_outcome',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [outcome])
        return outcome
      }
      if let rejection { return try receipt(rejection) }
      let body = body!, sender = senderText, receivedAt = receivedAt!
      let original = stamp(receivedAt)
      var fingerprint: String?
      if provenance == "original" && !sender.isEmpty {
        let tuple = ["v1-ms", account["namespace"] as! String, generation, sender, body, original]
        let data = try JSONSerialization.data(withJSONObject: tuple, options: [.sortedKeys, .withoutEscapingSlashes])
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }
      if let fingerprint, let previous = try query(db, "SELECT id,state,parser_version FROM captures WHERE occurrence=?", [fingerprint]).first {
        let currentVersion = Int(try query(db, "SELECT value FROM settings WHERE key='parserVersion'").first?["value"] as? String ?? "0") ?? 0
        // A transport ledger must not permanently suppress a shared parser upgrade.
        if previous["state"] as? String == "committed", (previous["parser_version"] as? Int ?? 0) < currentVersion {
          try requireCapacity(db, body: body)
          try execute(db, "UPDATE captures SET state='pending',body=?,sender=?,received_at=?,date_provenance=?,captured_at=? WHERE id=?", [try SpoolCipher.seal(body), try sealedSender(sender), original, provenance, stamp(now()), previous["id"]])
        }
        return try receipt("already_saved", capture: previous["id"] as? String)
      }
      try requireCapacity(db, body: body)
      let id = UUID().uuidString
      try execute(db, "INSERT INTO captures(id,generation,occurrence,body,sender,received_at,captured_at,date_provenance,state) VALUES(?,?,?,?,?,?,?,?,'pending')",
                  [id, generation, fingerprint, try SpoolCipher.seal(body), try sealedSender(sender), original, stamp(now()), provenance])
      return try receipt(sender.isEmpty ? "saved_without_sender" : "saved_for_processing", capture: id)
    }
  }

  /// Sender text is sealed when present; an empty sender carries no content.
  private func sealedSender(_ sender: String) throws -> String {
    sender.isEmpty ? "" : try SpoolCipher.seal(sender)
  }

  func pending(generation: String, limit: Int = 50) throws -> [[String: Any]] {
    try transaction { db in
      let account = try owner(db, generation: generation)
      var result: [[String: Any]] = []
      for row in try query(db, "SELECT id,body,sender,received_at AS receivedAt,captured_at AS capturedAt,date_provenance AS dateProvenance FROM captures WHERE generation=? AND state='pending' ORDER BY captured_at,id LIMIT ?", [generation, min(50, max(1, limit))]) {
        var value = row
        do {
          let body = try SpoolCipher.openStored(row["body"] as? String ?? "")
          let sender = try SpoolCipher.openStored(row["sender"] as? String ?? "")
          value["body"] = body; value["sender"] = sender
          value["bodyCharacters"] = body.utf16.count
          value["senderEvidence"] = sender.isEmpty ? "missing" : "text"
        } catch IncomingSmsError.cipher {
          // The key for this row is gone for good (corrupt text or a key that
          // was destroyed). Retire it so it cannot block the queue; a locked
          // key (`keyUnavailable`) is thrown instead and retried later.
          try execute(db, "UPDATE captures SET state='committed',body=NULL,sender=NULL,occurrence=NULL,outcome='ignored',source_key=NULL,parser_version=0 WHERE id=?", [row["id"]])
          continue
        }
        value["namespace"] = account["namespace"]; value["generation"] = generation
        result.append(value)
      }
      return result
    }
  }

  func acknowledge(generation: String, outcomes: [[String: Any]]) throws {
    try transaction { db in
      _ = try owner(db, generation: generation)
      guard outcomes.count <= 50 else { throw IncomingSmsError.invalid }
      for row in outcomes {
        if let id = row["id"] as? String, row["outcome"] as? String == "excluded_security",
           let version = row["parserVersion"] as? Int {
          // Validate against the original saved input: an arbitrary caller
          // cannot discard a financial message using a security receipt.
          if let capture = try query(db, "SELECT body FROM captures WHERE id=? AND generation=? AND state='pending'", [id, generation]).first {
            guard let stored = capture["body"] as? String, let body = try? SpoolCipher.openStored(stored),
                  SmsSecurityPolicy.sensitive(body) else { throw IncomingSmsError.invalid }
            try execute(db, "UPDATE receipts SET outcome='excluded_security',binding=NULL WHERE capture_id=?", [id])
            try execute(db, "UPDATE captures SET state='committed',body=NULL,sender=NULL,occurrence=NULL,outcome='ignored',source_key=NULL,parser_version=? WHERE id=? AND generation=?", [version, id, generation])
          }
          continue
        }
        guard let id = row["id"] as? String, let outcome = row["outcome"] as? String,
              ["captured", "ignored", "review", "existing"].contains(outcome),
              let key = row["sourceKey"] as? String, key.count == 64,
              let version = row["parserVersion"] as? Int else { throw IncomingSmsError.invalid }
        try execute(db, "UPDATE captures SET state='committed',body=NULL,sender=NULL,outcome=?,source_key=?,parser_version=? WHERE id=? AND generation=? AND state='pending'", [outcome, key, version, id, generation])
        if row["occurrenceAmbiguous"] as? Bool == true {
          try execute(db, "INSERT INTO settings VALUES('repeatedTextWarning','true') ON CONFLICT(key) DO NOTHING")
        }
      }
      try reconcile(db)
    }
  }

  private func snapshot(_ db: OpaquePointer) throws -> [String: Any] {
    let account = try query(db, "SELECT * FROM owner WHERE id=1").first ?? [:]
    var result: [String: Any] = ["enabled": account["enabled"] as? Int == 1]
    result["namespace"] = account["namespace"]; result["generation"] = account["generation"]
    result["pending"] = try query(db, "SELECT COUNT(*) AS count FROM captures WHERE state='pending'").first?["count"] ?? 0
    result["jobs"] = try query(db, "SELECT * FROM jobs ORDER BY rowid DESC LIMIT 20")
    result["windows"] = try query(db, """
      SELECT w.*,
        (SELECT COUNT(*) FROM receipts r WHERE r.attempt=w.attempt) AS enumerated,
        (SELECT COUNT(*) FROM receipts r WHERE r.attempt=w.attempt AND r.outcome='already_saved') AS duplicates,
        (SELECT COUNT(*) FROM receipts r WHERE r.attempt=w.attempt AND r.outcome IN ('invalid_body','missing_sender','missing_date')) AS incomplete,
        (SELECT COUNT(*) FROM receipts r WHERE r.attempt=w.attempt AND r.outcome='missing_sender') AS missing_sender,
        (SELECT COUNT(*) FROM receipts r WHERE r.attempt=w.attempt AND r.outcome IN ('saved_for_processing','already_saved')) AS sender_received,
        (SELECT COUNT(*) FROM receipts r WHERE r.attempt=w.attempt AND r.outcome='saved_without_sender') AS sender_unavailable,
        (SELECT COUNT(*) FROM receipts r WHERE r.attempt=w.attempt AND r.outcome='excluded_security') AS security_excluded,
        (SELECT COUNT(*) FROM receipts r WHERE r.attempt=w.attempt AND r.outcome='outside_window') AS outside_window,
        (SELECT COUNT(*) FROM receipts r JOIN captures c ON c.id=r.capture_id WHERE r.attempt=w.attempt AND c.state='committed') AS processed,
        (SELECT COUNT(*) FROM receipts r JOIN captures c ON c.id=r.capture_id WHERE r.attempt=w.attempt AND c.state='committed' AND c.outcome='review') AS needs_review,
        (SELECT COUNT(*) FROM receipts r JOIN captures c ON c.id=r.capture_id WHERE r.attempt=w.attempt AND c.state='committed' AND c.outcome='ignored') AS ignored,
        CASE WHEN w.attempt=(SELECT value FROM settings WHERE key='last_intent_attempt') THEN
          (SELECT value FROM settings WHERE key='last_intent_stage') END AS last_stage,
        CASE WHEN w.attempt=(SELECT value FROM settings WHERE key='last_handoff_attempt') THEN
          (SELECT value FROM settings WHERE key='last_handoff_stage') END AS handoff_stage,
        CASE WHEN w.attempt=(SELECT value FROM settings WHERE key='last_receiver_attempt') THEN
          (SELECT value FROM settings WHERE key='last_receiver_build') END AS receiver_build,
        CASE WHEN w.attempt=(SELECT value FROM settings WHERE key='last_sender_attempt') THEN
          (SELECT value FROM settings WHERE key='last_sender_input') END AS sender_input
      FROM windows w WHERE w.job_id IN (SELECT id FROM jobs ORDER BY rowid DESC LIMIT 20) ORDER BY w.ordinal
      """)
    for row in try query(db, "SELECT * FROM settings WHERE key NOT IN ('last_intent_attempt','last_handoff_attempt','last_receiver_attempt','last_sender_attempt')") { result[row["key"] as! String] = row["value"] }
    if let generation = account["generation"] as? String,
       let job = try query(db, "SELECT id FROM jobs WHERE state IN ('active','paused','partial') ORDER BY rowid DESC LIMIT 1").first {
      var counts: [String: Any] = try periodCounts(db, generation: generation, job: job["id"])
      counts["job"] = job["id"]
      result["active_counts"] = counts
    }
    if result["last_live_at"] == nil {
      // Live captures saved before last_live_at existed.
      result["last_live_at"] = try query(db, "SELECT MAX(captured_at) AS at FROM captures WHERE generation=? AND date_provenance='estimated'", [account["generation"]]).first?["at"]
    }
    if let generation = account["generation"] as? String {
      // Everything ever imported for this account, for the month overview.
      result["coverage"] = try coveredRanges(db, generation: generation).map { ["start": stamp($0.0), "end": stamp($0.1)] }
    }
    return result
  }

  func snapshot() throws -> [String: Any] { try transaction { try snapshot($0) } }

  func createJob(generation: String, id: String, kind: String, zone: String, windows: [[String: String]], replacingJobID: String? = nil, skipImported: Bool = true) throws {
    try transaction { db in
      _ = try owner(db, generation: generation)
      guard UUID(uuidString: id) != nil, ["history", "catchup"].contains(kind), !zone.isEmpty,
            !windows.isEmpty, windows.count <= 2400 else { throw IncomingSmsError.invalid }
      let current = try query(db, "SELECT id FROM jobs WHERE state IN ('active','paused','partial')")
      if let replacingJobID {
        // An explicit new-period choice may replace only the job the UI saw.
        // All validation/inserts and the stop commit together; failure leaves
        // the old check resumable, and previously captured rows are retained.
        guard kind == "history", current.count == 1,
              current[0]["id"] as? String == replacingJobID else { throw IncomingSmsError.stale }
        try execute(db, "UPDATE jobs SET state='stopped' WHERE id=?", [replacingJobID])
      } else if !current.isEmpty { throw IncomingSmsError.invalid }
      var previousEnd: Date?
      let monthFormatter = DateFormatter(); monthFormatter.dateFormat = "yyyy-MM"
      monthFormatter.calendar = Calendar(identifier: .gregorian)
      monthFormatter.locale = Locale(identifier: "en_US_POSIX")
      monthFormatter.timeZone = TimeZone(identifier: zone) ?? TimeZone.current
      for (index, row) in windows.enumerated() {
        guard let start = row["start"], let end = row["end"], let s = Self.date(start), let e = Self.date(end), s < e,
              previousEnd == nil || previousEnd == s, e <= now().addingTimeInterval(1) else { throw IncomingSmsError.invalid }
        previousEnd = e
        let logicalID = UUID().uuidString
        try execute(db, "INSERT INTO windows(id,job_id,ordinal,start,end,state,logical_id,month_label) VALUES(?,?,?,?,?,'queued',?,?)", [logicalID, id, index, start, end, logicalID, monthFormatter.string(from: s)])
      }
      try execute(db, "INSERT INTO jobs VALUES(?, ?, ?, 'active', ?, ?, ?)", [id, generation, kind, windows.first!["start"], windows.last!["end"], zone])
      if kind == "history" && skipImported { try skipImportedRanges(db, generation: generation, jobID: id) }
      try reconcile(db)
    }
  }

  /// A new history import skips date ranges this account already imported
  /// completely (earlier imports or daily catch-up). Fully covered windows are
  /// done at once; partly covered ones shrink to the missing dates. Messages
  /// in overlaps would only be found again as already saved.
  /// Date ranges this account has fully imported (merged), from any history
  /// import or daily catch-up. A range whose messages arrived without senders
  /// (older builds) is not counted: importing it again brings real senders.
  private func coveredRanges(_ db: OpaquePointer, generation: String, excludingJob: String? = nil) throws -> [(Date, Date)] {
    var covered: [(Date, Date)] = []
    for row in try query(db, "SELECT w.start, w.end FROM windows w JOIN jobs j ON j.id=w.job_id WHERE j.generation=? AND j.id<>? AND w.state='complete' AND NOT EXISTS (SELECT 1 FROM receipts r WHERE r.attempt=w.attempt AND r.outcome IN ('saved_without_sender','missing_sender')) ORDER BY w.start", [generation, excludingJob ?? ""]) {
      guard let s = Self.date(row["start"] as? String ?? ""), let e = Self.date(row["end"] as? String ?? ""), s < e else { continue }
      if let last = covered.last, s <= last.1 { covered[covered.count - 1].1 = max(last.1, e) } else { covered.append((s, e)) }
    }
    return covered
  }

  private func skipImportedRanges(_ db: OpaquePointer, generation: String, jobID: String) throws {
    let covered = try coveredRanges(db, generation: generation, excludingJob: jobID)
    guard !covered.isEmpty else { return }
    for row in try query(db, "SELECT id, start, end FROM windows WHERE job_id=? ORDER BY ordinal", [jobID]) {
      guard var s = Self.date(row["start"] as! String), var e = Self.date(row["end"] as! String) else { continue }
      for (cs, ce) in covered where cs <= s && ce > s { s = ce }
      for (cs, ce) in covered.reversed() where cs < e && ce >= e { e = cs }
      if s >= e {
        try execute(db, "UPDATE windows SET state='complete',found=0,limit_off=1 WHERE id=?", [row["id"]])
      } else if stamp(s) != row["start"] as? String || stamp(e) != row["end"] as? String {
        try execute(db, "UPDATE windows SET start=?,end=? WHERE id=?", [stamp(s), stamp(e), row["id"]])
      }
    }
  }

  /// Find Messages stops at this many results even with Limit off.
  static let findMessagesCap = 500

  func issue(generation: String) throws -> String? {
    try transaction { db in
      _ = try owner(db, generation: generation)
      // A range already searched and only waiting for PandaPay to process it
      // is not searched again; the next one is offered instead.
      guard let row = try query(db, "SELECT w.* FROM windows w JOIN jobs j ON j.id=w.job_id WHERE j.state='active' AND w.state NOT IN ('complete','finished') ORDER BY w.ordinal LIMIT 1").first else { return nil }
      var token = row["attempt"] as? String
      if row["state"] as? String == "queued" {
        token = UUID().uuidString
        try execute(db, "UPDATE windows SET state='waiting',attempt=? WHERE id=?", [token, row["id"]])
      }
      guard ["queued", "waiting", "running"].contains(row["state"] as? String ?? ""), let token else { return nil }
      let value: [String: Any] = ["version": 3, "attempt": token, "generation": generation,
                                "start_inclusive": row["start"]!, "end_exclusive": row["end"]!]
      return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
  }

  /// For a history Shortcut that loops through every range in one run: the
  /// next range not yet searched, or nil when none is left. Ranges already
  /// searched but still waiting for PandaPay to process them are skipped, so
  /// the loop carries on while PandaPay itself is closed. Stopped ranges are
  /// left for PandaPay to retry.
  func issueNextRange() throws -> String? {
    try transaction { db in
      guard let account = try? owner(db), let generation = account["generation"] as? String else { return nil }
      if let job = try query(db, "SELECT id FROM jobs WHERE state='active' AND kind='history' AND generation=? ORDER BY rowid DESC LIMIT 1", [generation]).first {
        // Tells PandaPay this import runs as one looping Shortcut run.
        try execute(db, "INSERT INTO settings VALUES('loop_job',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [job["id"]])
      }
      guard let row = try query(db, "SELECT w.* FROM windows w JOIN jobs j ON j.id=w.job_id WHERE j.state='active' AND j.kind='history' AND j.generation=? AND w.state IN ('queued','waiting','running') ORDER BY w.ordinal LIMIT 1", [generation]).first else { return nil }
      var token = row["attempt"] as? String
      if row["state"] as? String == "queued" {
        token = UUID().uuidString
        try execute(db, "UPDATE windows SET state='waiting',attempt=? WHERE id=?", [token, row["id"]])
      }
      guard let token else { return nil }
      let value: [String: Any] = ["version": 3, "attempt": token, "generation": generation,
                                  "start_inclusive": row["start"]!, "end_exclusive": row["end"]!]
      return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
  }

  /// Progress of the latest history import, for the Lock Screen activity:
  /// Delivery and local processing share the same completion contract.
  func importProgress() throws -> [String: Any] {
    try transaction { db in
      guard let account = try? owner(db), let generation = account["generation"] as? String,
            let job = try query(db, "SELECT * FROM jobs WHERE kind='history' AND generation=? ORDER BY rowid DESC LIMIT 1", [generation]).first else {
        return ["state": "none"]
      }
      let windows = try query(db, "SELECT start,end,state,attempt,COALESCE(logical_id,id) AS month FROM windows WHERE job_id=? ORDER BY ordinal", [job["id"]])
      var months: [String] = [], open = Set<String>()
      for row in windows {
        let month = row["month"] as! String
        if !months.contains(month) { months.append(month) }
        if row["state"] as? String != "complete" { open.insert(month) }
      }
      let current = windows.first { $0["state"] as? String != "complete" }
      let receiving = windows.contains { ["queued", "waiting", "running", "partial"].contains($0["state"] as? String ?? "") }
      let state: String
      switch job["state"] as? String {
      case "complete": state = "complete"
      case "paused": state = "paused"
      case "stopped": state = "stopped"
      default: state = current == nil ? "complete" : (current?["state"] as? String == "partial" ? "paused" : (receiving ? "importing" : "processing"))
      }
      var result: [String: Any] = ["state": state, "done": months.count - open.count, "total": months.count]
      let counts = try periodCounts(db, generation: generation, job: job["id"])
      result["received"] = counts["saved"]
      result["processed"] = counts["processed"]
      if let current {
        result["start"] = current["start"]; result["end"] = current["end"]
        // Moves with every message, so a long month still shows progress.
        result["current_received"] = try query(db, "SELECT COUNT(*) AS n FROM receipts WHERE attempt=?", [current["attempt"]]).first?["n"] as? Int ?? 0
      }
      return result
    }
  }

  /// Messages from this import's period that PandaPay holds. Unlike receipts
  /// (one set per attempt), this never drops when a range is read again
  /// after Resume: a message read twice is still one saved message.
  private func periodCounts(_ db: OpaquePointer, generation: String, job: Any?) throws -> [String: Int] {
    let row = try query(db, """
      SELECT COUNT(*) AS saved,
        COALESCE(SUM(CASE WHEN c.state='committed' THEN 1 ELSE 0 END),0) AS processed,
        COALESCE(SUM(CASE WHEN c.state='committed' AND c.outcome='review' THEN 1 ELSE 0 END),0) AS review
      FROM captures c, (SELECT julianday(MIN(start)) AS s, julianday(MAX(end)) AS e FROM windows WHERE job_id=?) p
      WHERE c.generation=? AND c.date_provenance='original'
        AND julianday(c.received_at) >= p.s AND julianday(c.received_at) < p.e
      """, [job, generation]).first
    return ["saved": row?["saved"] as? Int ?? 0, "processed": row?["processed"] as? Int ?? 0, "review": row?["review"] as? Int ?? 0]
  }

  func finish(request: String, found: Int, limitOff: Bool, warning: Bool) throws -> String {
    try transaction { db in
      let row = try window(db, request: request)
      guard found >= 0 else { throw IncomingSmsError.invalid }
      try recordStage(db, window: row, stage: .finish)
      if ["finished", "complete", "partial"].contains(row["state"] as? String ?? "") { return row["state"] as! String }
      try execute(db, "UPDATE windows SET found=?,limit_off=?,warning=?,state='finished' WHERE id=?", [found, limitOff ? 1 : 0, warning ? 1 : 0, row["id"]])
      try reconcile(db)
      return try query(db, "SELECT state FROM windows WHERE id=?", [row["id"]]).first!["state"] as! String
    }
  }

  private func reconcile(_ db: OpaquePointer) throws {
    for row in try query(db, "SELECT * FROM windows WHERE state='finished'") {
      let receipts = try query(db, "SELECT r.outcome,c.state AS capture_state FROM receipts r LEFT JOIN captures c ON c.id=r.capture_id WHERE r.attempt=?", [row["attempt"]])
      // A message with no text (photo/MMS, empty) or no usable date can never
      // be imported, so retrying the range cannot help: a few such messages
      // are counted and skipped. Many of them usually means the Shortcut's
      // fields are mapped wrongly, which must stop the range instead of
      // silently dropping real messages.
      let unusable = receipts.filter { ["missing_sender", "missing_date", "invalid_body"].contains($0["outcome"] as? String ?? "") }.count
      let invalid = unusable > 2 && unusable * 20 > receipts.count
      let found = row["found"] as? Int ?? 0
      // Find Messages returns at most 500 whatever its Limit setting, so the
      // count alone tells a complete range (under 500) from a capped one; the
      // "limit is off" toggle is no longer needed.
      let consistent = found == receipts.count && row["warning"] as? Int == 0 && !invalid
      // A window that already queued its continuation has issued_end set.
      var capped = found >= Self.findMessagesCap && row["issued_end"] as? String == nil
      // Find Messages returns at most 500, oldest first. When a window hits
      // that cap, cover only up to the newest message it returned and queue
      // the rest of the window from that instant. Messages at the boundary
      // are found again and recorded as already saved.
      if capped, consistent,
         let last = try query(db, "SELECT MAX(c.received_at) AS last FROM receipts r JOIN captures c ON c.id=r.capture_id WHERE r.attempt=?", [row["attempt"]]).first?["last"] as? String,
         let lastDate = Self.date(last), let start = Self.date(row["start"] as! String), let end = Self.date(row["end"] as! String),
         lastDate > start, lastDate < end {
        let boundary = stamp(lastDate)
        let ordinal = row["ordinal"] as! Int
        try execute(db, "UPDATE windows SET ordinal=ordinal+1 WHERE job_id=? AND ordinal>?", [row["job_id"], ordinal])
        try execute(db, "INSERT INTO windows(id,job_id,ordinal,start,end,state,logical_id,month_label) VALUES(?,?,?,?,?,'queued',?,?)", [UUID().uuidString, row["job_id"], ordinal + 1, boundary, row["end"], row["logical_id"], row["month_label"]])
        try execute(db, "UPDATE windows SET issued_end=COALESCE(issued_end,end),end=? WHERE id=?", [boundary, row["id"]])
        capped = false
      }
      let partial = !consistent || capped
      let pending = receipts.contains { $0["capture_state"] as? String == "pending" }
      if partial { try execute(db, "UPDATE windows SET state='partial' WHERE id=?", [row["id"]]) }
      else if !pending { try execute(db, "UPDATE windows SET state='complete' WHERE id=?", [row["id"]]) }
    }
    for job in try query(db, "SELECT * FROM jobs WHERE state IN ('active','paused')") {
      let rows = try query(db, "SELECT state,end FROM windows WHERE job_id=? ORDER BY ordinal", [job["id"]])
      // Only catch-up jobs establish ongoing coverage; older history is separate.
      if job["kind"] as? String == "catchup" {
        var through: String?
        for row in rows {
          guard row["state"] as? String == "complete" else { break }
          through = row["end"] as? String
        }
        if let through {
          let old = try query(db, "SELECT value FROM settings WHERE key='reconciledThrough'").first?["value"] as? String
          if old == nil || Self.date(through)! > Self.date(old!)! {
            try execute(db, "INSERT INTO settings VALUES('reconciledThrough',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [through])
          }
        }
      }
      if !rows.isEmpty && rows.allSatisfy({ $0["state"] as? String == "complete" }) {
        try execute(db, "UPDATE jobs SET state='complete' WHERE id=?", [job["id"]])
      }
    }
  }

  func control(generation: String, command: String) throws {
    try transaction { db in
      _ = try owner(db, generation: generation)
      guard let job = try query(db, "SELECT * FROM jobs WHERE state IN ('active','paused','partial') ORDER BY rowid LIMIT 1").first else { return }
      switch command {
      case "pause": try execute(db, "UPDATE jobs SET state='paused' WHERE id=?", [job["id"]])
      case "resume": try execute(db, "UPDATE jobs SET state='active' WHERE id=?", [job["id"]]); try reconcile(db)
      case "stop": try execute(db, "UPDATE jobs SET state='stopped' WHERE id=?", [job["id"]])
      case "retry":
        // New token fences all delayed callbacks; old captured rows still drain.
        try execute(db, "UPDATE windows SET state='queued',attempt=NULL,found=NULL,limit_off=NULL,warning=0 WHERE job_id=? AND state IN ('waiting','running','partial')", [job["id"]])
        try execute(db, "UPDATE jobs SET state='active' WHERE id=?", [job["id"]])
      case "split":
        guard let row = try query(db, "SELECT * FROM windows WHERE job_id=? AND state='partial' ORDER BY ordinal LIMIT 1", [job["id"]]).first,
              let start = Self.date(row["start"] as! String), let end = Self.date(row["end"] as! String),
              end.timeIntervalSince(start) >= 0.004 else { throw IncomingSmsError.invalid }
        let midpoint = stamp(Date(timeIntervalSince1970: floor((start.timeIntervalSince1970 + end.timeIntervalSince1970) * 500) / 1000))
        let ordinal = row["ordinal"] as! Int
        try execute(db, "UPDATE windows SET ordinal=ordinal+1 WHERE job_id=? AND ordinal>?", [job["id"], ordinal])
        try execute(db, "INSERT INTO windows(id,job_id,ordinal,start,end,state,logical_id,month_label) VALUES(?,?,?,?,?,'queued',?,?)", [UUID().uuidString, job["id"], ordinal + 1, midpoint, row["end"], row["logical_id"], row["month_label"]])
        try execute(db, "UPDATE windows SET end=?,state='queued',attempt=NULL,found=NULL,limit_off=NULL,warning=0 WHERE id=?", [midpoint, row["id"]])
      default: throw IncomingSmsError.invalid
      }
    }
  }

  /// Cold daily automation enters this same coordinator; it never reads Messages.
  func prepareCatchup() throws -> String? {
    let state = try snapshot()
    guard state["enabled"] as? Bool == true, let generation = state["generation"] as? String else { throw IncomingSmsError.inactive }
    let jobs = state["jobs"] as? [[String: Any]] ?? []
    if !jobs.contains(where: { ["active", "paused", "partial"].contains($0["state"] as? String ?? "") }) {
      // Native ready/resume notifications may arrive in a burst. Do not create
      // an endless new overlapping job immediately after the last one finishes.
      if let checked = Self.date(state["lastCatchupRequestedAt"] as? String ?? "") {
        let age = now().timeIntervalSince(checked)
        if age >= 0 && age < 300 { return nil }
      }
      let anchor = Self.date(state["reconciledThrough"] as? String ?? state["enabledAt"] as? String ?? "") ?? now()
      let calendar = Calendar.current
      var start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: anchor))!
      let cutoff = now()
      var windows: [[String: String]] = []
      while start < cutoff {
        let end = min(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!, cutoff)
        windows.append(["start": stamp(start), "end": stamp(end)])
        start = end
      }
      if !windows.isEmpty {
        do {
          try createJob(generation: generation, id: UUID().uuidString, kind: "catchup", zone: calendar.timeZone.identifier, windows: windows)
          try transaction { db in
            _ = try owner(db, generation: generation)
            try execute(db, "INSERT INTO settings VALUES('lastCatchupRequestedAt',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [stamp(now())])
          }
        } catch {
          let latest = try snapshot()
          guard latest["generation"] as? String == generation,
                (latest["jobs"] as? [[String: Any]] ?? []).contains(where: { ["active", "paused"].contains($0["state"] as? String ?? "") }) else { throw error }
        }
      }
    }
    return try issue(generation: generation)
  }
}
