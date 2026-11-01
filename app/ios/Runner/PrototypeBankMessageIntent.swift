// This experiment is intentionally absent from device and release builds.
#if DEBUG && targetEnvironment(simulator)
import AppIntents
import CryptoKit
import Flutter
import Foundation

enum PrototypeCaptureError: LocalizedError {
  case syntheticOnly, sensitive, oversized, queueFull, invalidBatch

  var errorDescription: String? {
    switch self {
    case .syntheticOnly: return "Prototype accepts only messages tagged [PANDAPAY_TEST]."
    case .sensitive: return "Sensitive test message rejected before storage."
    case .oversized: return "Test message exceeds 20,000 characters."
    case .queueFull: return "Prototype inbox is full. Clear the synthetic captures first."
    case .invalidBatch: return "Use a synthetic JSON array with at most 200 messages and original ISO dates."
    }
  }
}

/// A small durable handoff, not a replacement SMS reader or production inbox.
/// It stores synthetic fixtures only and never performs a network request.
enum PrototypeBankMessageInbox {
  private static let lock = NSLock()
  private static let marker = "[PANDAPAY_TEST]"
  private static let formatter: ISO8601DateFormatter = {
    let value = ISO8601DateFormatter()
    value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return value
  }()

  private static var fileURL: URL {
    get throws {
      let directory = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      )
      return directory.appendingPathComponent("ios-shortcuts-prototype.json")
    }
  }

  private static func readUnlocked() throws -> [[String: Any]] {
    let url = try fileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let records = value as? [[String: Any]] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return records
  }

  static func read() throws -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return try readUnlocked()
  }

  static func capture(body: String, sender: String, receivedAt: Date?) throws -> String {
    guard body.contains(marker) else { throw PrototypeCaptureError.syntheticOnly }
    guard body.count <= 20_000 else { throw PrototypeCaptureError.oversized }
    // Never retain even synthetic OTPs. The existing Dart gate is also applied
    // when the fixture reaches the canonical parser.
    if body.range(
      of: #"(?i)\b(?:otp|one[-\s]?time (?:password|code)|verification code|security code|cvv|pin|passcode|secret code)\b|\b(?:do not|don't|never)\s+share\b|\b\d{4,8}\b[\s\S]{0,40}\bvalid\s+(?:for|till|until)\s+\d+\s*(?:minutes?|mins?|seconds?|secs?)\b|\bregistration\s+alert\s*:\s*device\s+name\b"#,
      options: .regularExpression
    ) != nil {
      throw PrototypeCaptureError.sensitive
    }
    lock.lock()
    defer { lock.unlock() }
    let originalDate = receivedAt.map { formatter.string(from: $0) }
    // Body alone is never a replay key: equal-text payments can be distinct.
    let id: String
    if let date = originalDate {
      let identity = Data("\(sender)\n\(date)\n\(body)".utf8)
      id = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    } else {
      id = UUID().uuidString
    }
    var records = try readUnlocked()
    if records.contains(where: { $0["id"] as? String == id }) { return id }
    guard records.count < 200 else { throw PrototypeCaptureError.queueFull }
    var record: [String: Any] = [
      "id": id, "body": body, "sender": sender,
      "source": "ios_shortcut_prototype",
      "capturedAt": formatter.string(from: Date()),
      "originalDateKnown": originalDate != nil,
    ]
    if let date = originalDate { record["receivedAt"] = date }
    records.append(record)
    try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
      .write(to: try fileURL, options: .atomic)
    return id
  }

  static func clear() throws {
    lock.lock()
    defer { lock.unlock() }
    try Data("[]".utf8).write(to: try fileURL, options: .atomic)
  }
}

/// Explicit test source. This file is not the Apple Messages database.
enum PrototypeMessageHistory {
  private static func file(_ name: String) throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).appendingPathComponent(name)
  }

  static func seed(_ json: String) throws -> Int {
    let rows = try rows(json)
    guard rows.count == 100, rows.allSatisfy({
      ($0["body"] as? String)?.contains("[PANDAPAY_TEST]") == true
    }) else { throw PrototypeCaptureError.invalidBatch }
    try Data(json.utf8).write(to: file("ios-shortcuts-synthetic-history.json"), options: .atomic)
    return rows.count
  }

  static func load() throws -> String {
    try String(contentsOf: file("ios-shortcuts-synthetic-history.json"), encoding: .utf8)
  }

  private static func rows(_ json: String) throws -> [[String: Any]] {
    guard json.utf8.count <= 2_000_000,
          let records = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
          records.count <= 200 else { throw PrototypeCaptureError.invalidBatch }
    return records
  }

  static func ingest(_ json: String) throws -> [String: Int] {
    let records = try rows(json)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    var known = Set(try PrototypeBankMessageInbox.read().compactMap { $0["id"] as? String })
    var report = ["scanned": records.count, "added": 0, "duplicates": 0, "sensitive": 0, "invalid": 0]
    for row in records {
      guard let body = row["body"] as? String,
            let sender = row["sender"] as? String, !sender.isEmpty,
            let original = row["receivedAt"] as? String,
            let receivedAt = fractional.date(from: original) ?? plain.date(from: original) else {
        report["invalid", default: 0] += 1
        continue
      }
      do {
        let id = try PrototypeBankMessageInbox.capture(body: body, sender: sender, receivedAt: receivedAt)
        if known.insert(id).inserted {
          report["added", default: 0] += 1
        } else {
          report["duplicates", default: 0] += 1
        }
      } catch PrototypeCaptureError.sensitive {
        report["sensitive", default: 0] += 1
      } catch PrototypeCaptureError.syntheticOnly {
        report["invalid", default: 0] += 1
      } catch PrototypeCaptureError.oversized {
        report["invalid", default: 0] += 1
      }
    }
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
      .write(to: file("ios-shortcuts-last-batch.json"), options: .atomic)
    return report
  }

  static func status() throws -> [String: Any] {
    var result: [String: Any] = ["historyCount": 0]
    if let json = try? load(), let history = try? rows(json) { result["historyCount"] = history.count }
    if let data = try? Data(contentsOf: file("ios-shortcuts-last-batch.json")),
       let report = try? JSONSerialization.jsonObject(with: data) { result["lastBatch"] = report }
    return result
  }
}

@available(iOS 16.0, *)
struct LoadPrototypeHistoryIntent: AppIntent {
  static var title: LocalizedStringResource = "Load 100 Demo Messages (Prototype)"
  static var description = IntentDescription("Read the explicitly seeded synthetic test inbox. This does not read Apple Messages.")
  static var openAppWhenRun = false

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: try PrototypeMessageHistory.load())
  }
}

@available(iOS 16.0, *)
struct ImportPrototypeMessageBatchIntent: AppIntent {
  static var title: LocalizedStringResource = "Import Message Batch (Prototype)"
  static var description = IntentDescription("Import tagged synthetic JSON messages with sender and original receive date through the same native capture path.")
  static var openAppWhenRun = false

  @Parameter(title: "Messages JSON") var messagesJSON: String

  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let report = try PrototypeMessageHistory.ingest(messagesJSON)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    let value = String(decoding: data, as: UTF8.self)
    let summary = "Scanned \(report["scanned"]!). Added \(report["added"]!), duplicates \(report["duplicates"]!), sensitive rejected \(report["sensitive"]!), invalid \(report["invalid"]!). Open PandaPay to parse the captured messages."
    return .result(value: value, dialog: "\(summary)")
  }
}

@available(iOS 16.0, *)
struct CapturePrototypeBankMessageIntent: AppIntent {
  static var title: LocalizedStringResource = "Capture Bank Message (Prototype)"
  static var description = IntentDescription(
    "Capture a synthetic bank message for the local PandaPay simulator prototype. Requires [PANDAPAY_TEST]."
  )
  static var openAppWhenRun = false

  @Parameter(title: "Message text") var message: String
  @Parameter(title: "Sender", default: "SIM-BANK") var sender: String
  @Parameter(title: "Received at") var receivedAt: Date?

  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let id = try PrototypeBankMessageInbox.capture(
      body: message, sender: sender, receivedAt: receivedAt
    )
    return .result(
      value: id,
      dialog: "Captured synthetic bank message. Open the PandaPay prototype to parse it."
    )
  }
}

@available(iOS 16.0, *)
struct PrototypeBankMessageShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CapturePrototypeBankMessageIntent(),
      phrases: ["Capture a test bank message with \(.applicationName)"],
      shortTitle: "Capture Bank Message",
      systemImageName: "text.bubble"
    )
  }
}

enum PrototypeBankMessageBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "pandapay/ios_import_prototype", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "readCaptures": result(try PrototypeBankMessageInbox.read())
        case "seedHistory":
          guard let json = call.arguments as? String else { throw PrototypeCaptureError.invalidBatch }
          result(try PrototypeMessageHistory.seed(json))
        case "readPrototypeStatus": result(try PrototypeMessageHistory.status())
        case "clearCaptures":
          try PrototypeBankMessageInbox.clear()
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "prototype_inbox_error", message: error.localizedDescription, details: nil))
      }
    }
  }
}
#endif

// Physical-device research is a separate, explicitly opted-in build. It has a
// distinct bundle ID, no App Group, no network calls and no message file store.
#if PANDAPAY_DEVICE_IMPORT_PROBE
import AppIntents
import CryptoKit
import Flutter
import Foundation

enum DeviceHistoryProbeInbox {
  private static let lock = NSLock()
  private static var pending: [[String: Any]] = []
  private static var identities = Set<String>()
  private static var received = 0
  private static var sensitive = 0
  private static var duplicate = 0
  private static var invalid = 0
  private static let formatter: ISO8601DateFormatter = {
    let value = ISO8601DateFormatter()
    value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return value
  }()

  static func parseDateString(_ string: String) -> Date? {
    let str = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if str.isEmpty { return nil }
    if let d = formatter.date(from: str) { return d }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: str) { return d }
    let formats = [
      "yyyy-MM-dd HH:mm:ss",
      "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd",
      "dd/MM/yyyy, h:mm:ss a",
      "dd/MM/yyyy, h:mm a",
      "dd/MM/yyyy h:mm a",
      "dd/MM/yyyy",
      "MM/dd/yyyy, h:mm:ss a",
      "MM/dd/yyyy, h:mm a",
      "MM/dd/yyyy",
      "d MMM yyyy 'at' h:mm:ss a",
      "d MMM yyyy, h:mm a",
      "d MMM yyyy",
      "MMM d, yyyy 'at' h:mm:ss a",
      "MMM d, yyyy, h:mm a",
      "MMM d, yyyy",
      "d MMMM yyyy 'at' h:mm:ss a",
      "d MMMM yyyy, h:mm a",
      "MMMM d, yyyy 'at' h:mm:ss a",
      "MMMM d, yyyy, h:mm a",
    ]
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    for fmt in formats {
      df.dateFormat = fmt
      if let d = df.date(from: str) { return d }
    }
    let localizedDf = DateFormatter()
    localizedDf.dateStyle = .short
    localizedDf.timeStyle = .short
    if let d = localizedDf.date(from: str) { return d }
    localizedDf.dateStyle = .medium
    localizedDf.timeStyle = .medium
    if let d = localizedDf.date(from: str) { return d }
    return nil
  }

  static func capture(body: String, sender: String, receivedAt: Date?, senderEvidence: String = "text") -> String {
    lock.lock()
    defer { lock.unlock() }
    guard Bundle.main.bundleIdentifier == "app.pandapay.iosimportprobe" else {
      return "wrong_probe_bundle"
    }
    received += 1
    guard !body.isEmpty, body.count <= 20_000 else {
      invalid += 1
      return "skipped_invalid"
    }
    if SmsSecurityPolicy.sensitive(body) {
      sensitive += 1
      return "skipped_sensitive"
    }
    let original = receivedAt.map { formatter.string(from: $0) }
    let id = original.map {
      SHA256.hash(data: Data("\(sender)\n\($0)\n\(body)".utf8))
        .map { String(format: "%02x", $0) }.joined()
    } ?? UUID().uuidString
    guard !identities.contains(id) else {
      duplicate += 1
      return "duplicate"
    }
    guard identities.count < 2500 else {
      invalid += 1
      return "probe_limit_reached"
    }
    identities.insert(id)
    var row: [String: Any] = [
      "id": id, "body": body, "sender": sender, "senderEvidence": senderEvidence,
      "bodyCharacters": body.utf16.count,
      "capturedAt": formatter.string(from: Date()),
    ]
    if let original { row["receivedAt"] = original }
    pending.append(row)
    return "captured"
  }

  static func drain() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let rows = pending
    pending.removeAll()
    return ["records": rows, "received": received, "sensitive": sensitive,
            "duplicates": duplicate, "invalid": invalid]
  }

  static func readPending() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return ["records": pending, "received": received, "sensitive": sensitive,
            "duplicates": duplicate, "invalid": invalid]
  }

  static func acknowledge(_ ids: [String]) {
    lock.lock()
    defer { lock.unlock() }
    let confirmed = Set(ids)
    pending.removeAll { row in (row["id"] as? String).map(confirmed.contains) ?? false }
  }

  static func clear() {
    lock.lock()
    defer { lock.unlock() }
    pending.removeAll()
    identities.removeAll()
    received = 0
    sensitive = 0
    duplicate = 0
    invalid = 0
  }
}

@available(iOS 16.0, *)
struct InspectDeviceFinancialMessageIntent: AppIntent {
  static var title: LocalizedStringResource = "Inspect Financial Message on iPhone"
  static var description = IntentDescription("Record a live single-message handoff in the isolated diagnostic. Missing metadata and rejection outcomes are reported. Non-sensitive retained input stays in process memory; no account or backend is used.")
  static var openAppWhenRun = false

  @Parameter(title: "Message body") var body: String?
  @Parameter(title: "Sender", default: "", resolvers: { ProbeSenderTextResolver() }) var sender: String
  @Parameter(title: "Original receive date") var receivedAt: Date?

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let input = ProbeSenderValue.decode(sender)
    let result = DeviceLiveMessageInbox.shared.capture(body: body, sender: input.sender, receivedAt: receivedAt, evidence: input.evidence, handler: "text_sender", allowedBundle: Bundle.main.bundleIdentifier == "app.pandapay.iosimportprobe", senderDiagnostics: input.diagnostics(action: "existing_text_message", parameter: "sender"))
    DeviceHistoryProbeBridge.notifyReady()
    return .result(value: result)
  }
}

/// Keep the published action and parameter identifiers for saved Shortcuts.
/// Sender is text: bank headers are not necessarily contacts, phone numbers or
/// email addresses. A person parameter made Shortcuts fail before perform().
@available(iOS 16.0, *)
struct InspectDeviceFinancialMessagePersonIntent: AppIntent {
  static var title: LocalizedStringResource = "Inspect Financial Message With Sender"
  static var description = IntentDescription("Record a live single-message handoff with optional sender text and original date. Select the incoming Message's Sender property; bank sender IDs do not need to be contacts. Missing input and rejection outcomes are reported locally; no account or backend is used.")
  static var openAppWhenRun = false

  @Parameter(title: "Message body") var body: String?
  @Parameter(title: "Sender (text)", resolvers: { ProbeSenderTextResolver() }) var senderPerson: String?
  @Parameter(title: "Original receive date") var receivedAt: Date?

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let input = ProbeSenderValue.decode(senderPerson)
    let result = DeviceLiveMessageInbox.shared.capture(body: body, sender: input.sender, receivedAt: receivedAt, evidence: input.evidence, handler: "person_sender", allowedBundle: Bundle.main.bundleIdentifier == "app.pandapay.iosimportprobe", senderDiagnostics: input.diagnostics(action: "existing_single_message", parameter: "senderPerson"))
    DeviceHistoryProbeBridge.notifyReady()
    let counts: [String: Any] = [
      "outcome": result,
      "sender_present": !input.sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "sender_kind": input.evidence,
      "sender_conversion": input.conversion,
      "date_present": receivedAt != nil,
      "body_present": !(body ?? "").isEmpty,
    ]
    let data = try JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])
    return .result(value: String(decoding: data, as: UTF8.self))
  }
}

@available(iOS 16.0, *)
struct InspectDeviceFinancialHistoryIntent: AppIntent {
  static var title: LocalizedStringResource = "Inspect Financial History on iPhone"
  static var description = IntentDescription("Inspect up to 2000 selected historical message bodies locally. Optional sender/date lists must correspond to the body list. No message file, account or network is used.")
  static var openAppWhenRun = false

  @Parameter(title: "Message bodies") var bodies: [String]
  @Parameter(title: "Senders") var senders: [String]?
  @Parameter(title: "Original receive dates") var dates: [String]?

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard bodies.count <= 2000,
          senders == nil || senders!.count == bodies.count,
          dates == nil || dates!.count == bodies.count else {
      return .result(value: "invalid_batch: list lengths differ or exceed 2000; no messages imported")
    }
    var counts: [String: Int] = [:]
    counts["body_count"] = bodies.count
    counts["sender_count"] = senders?.count ?? 0
    counts["date_count"] = dates?.count ?? 0
    counts["nonempty_senders"] = senders?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count ?? 0
    var parsedDatesCount = 0
    for (index, body) in bodies.prefix(2000).enumerated() {
      let sender = (senders?.count == bodies.count) ? senders![index] : ""
      let dateString = (dates?.count == bodies.count) ? dates![index] : nil
      let parsedDate = dateString.flatMap { HistoryRangeRequest.isoDate($0) }
      if parsedDate != nil { parsedDatesCount += 1 }
      let outcome = DeviceHistoryProbeInbox.capture(body: body, sender: sender, receivedAt: parsedDate)
      counts[outcome, default: 0] += 1
    }
    counts["parsed_date_count"] = parsedDatesCount
    DeviceHistoryProbeBridge.notifyReady()
    let data = try JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])
    return .result(value: String(decoding: data, as: UTF8.self))
  }
}

// V2 uses a typed Date and person from the SAME Repeat Item. No parallel lists.
@available(iOS 16.0, *)
struct PrepareDeviceHistoryRangeIntent: AppIntent {
  static var title: LocalizedStringResource = "Prepare PandaPay Selected Range"
  static var description = IntentDescription("Validate the range requested by the isolated app and return its search start. Run only from PandaPay History Probe.")
  static var openAppWhenRun = false
  @Parameter(title: "Range request") var request: String
  func perform() async throws -> some IntentResult & ReturnsValue<Date> {
    .result(value: try DeviceHistoryRangeInbox.shared.boundary(request, end: false))
  }
}

@available(iOS 16.0, *)
struct DeviceHistoryRangeEndIntent: AppIntent {
  static var title: LocalizedStringResource = "PandaPay Selected Range End"
  static var openAppWhenRun = false
  @Parameter(title: "Range request") var request: String
  func perform() async throws -> some IntentResult & ReturnsValue<Date> {
    .result(value: try DeviceHistoryRangeInbox.shared.boundary(request, end: true))
  }
}

@available(iOS 16.0, *)
struct CaptureDeviceHistoryRangeMessageIntent: AppIntent {
  static var title: LocalizedStringResource = "Import PandaPay Range Message"
  static var description = IntentDescription("Import one message with its own original receive date. Missing dates and out-of-range messages are rejected; missing senders are reported.")
  static var openAppWhenRun = false
  @Parameter(title: "Range request") var request: String
  @Parameter(title: "Message body") var body: String
  @Parameter(title: "Sender as person", mode: .emailOrPhone) var senderPerson: IntentPerson?
  @Parameter(title: "Sender as text (diagnostic)", inputConnectionBehavior: .never) var senderText: String?
  @Parameter(title: "Sender type (diagnostic)", inputConnectionBehavior: .never) var senderType: String?
  @Parameter(title: "Original receive date") var receivedAt: Date?
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let sender: String
    let evidence: String
    if let handle = senderPerson?.handle {
      switch handle.value {
      case .phoneNumber(let value), .emailAddress(let value), .applicationDefined(let value): sender = value
      }
      evidence = "handle"
    } else if let text = senderText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sender = text; evidence = "text"
    } else if let person = senderPerson {
      switch person.name {
      case .displayName(let value): sender = value
      case .components(let value): sender = PersonNameComponentsFormatter.localizedString(from: value, style: .default)
      case .unknown: sender = ""
      }
      evidence = sender.isEmpty ? "missing_person" : "name"
    } else { sender = ""; evidence = "missing_person" }
    var person: [String: Any] = ["present": senderPerson != nil, "alias_count": senderPerson?.aliases.count ?? 0,
      "handle": NSNull(), "handle_type": NSNull(), "name": NSNull(), "name_type": NSNull()]
    if let value = senderPerson {
      switch value.name {
      case .displayName(let name): person["name"] = name; person["name_type"] = "display_name"
      case .components(let name): person["name"] = PersonNameComponentsFormatter.localizedString(from: name, style: .default); person["name_type"] = "components"
      case .unknown: person["name_type"] = "unknown"
      @unknown default: person["name_type"] = "unsupported"
      }
      if let handle = value.handle {
        switch handle.value {
        case .phoneNumber(let text): person["handle"] = text; person["handle_type"] = "phone_number"
        case .emailAddress(let text): person["handle"] = text; person["handle_type"] = "email_address"
        case .applicationDefined(let text): person["handle"] = text; person["handle_type"] = "application_defined"
        @unknown default: person["handle_type"] = "unsupported"
        }
      }
    }
    let diagnostics: [String: Any] = ["action": "person_and_text", "text": senderText.map { $0 as Any } ?? NSNull(), "person": person,
      "shortcuts_type": senderType.map { $0 as Any } ?? NSNull()]
    let result = try DeviceHistoryRangeInbox.shared.capture(request, body: body, sender: sender, date: receivedAt, evidence: evidence, senderDiagnostics: diagnostics)
    DeviceHistoryProbeBridge.notifyReady()
    return .result(value: result)
  }
}

/// Separate identity avoids the old optional Person's pre-perform conversion.
/// Do not change that published field's type on already-saved shortcuts.
@available(iOS 16.0, *)
struct CaptureDeviceHistoryRangeTextMessageIntent: AppIntent {
  static var title: LocalizedStringResource = "Import PandaPay Range Message as Text"
  static var description = IntentDescription("Inspect the Message Sender as text without any Contact, Phone Number or Email Address input. Uses the same selected range and local comparison screen.")
  static var openAppWhenRun = false
  @Parameter(title: "Range request", inputConnectionBehavior: .never) var request: String
  @Parameter(title: "Message body", inputConnectionBehavior: .never) var body: String
  @Parameter(title: "Sender as text", inputConnectionBehavior: .never, resolvers: { ProbeSenderTextResolver() }) var senderText: String?
  @Parameter(title: "Sender type (diagnostic)", inputConnectionBehavior: .never) var senderType: String?
  @Parameter(title: "Original receive date", inputConnectionBehavior: .never) var receivedAt: Date?

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let input = ProbeSenderValue.decode(senderText)
    var diagnostics = input.diagnostics(action: "text_only", parameter: "senderText")
    diagnostics["shortcuts_type"] = senderType.map { $0 as Any } ?? NSNull()
    let result = try DeviceHistoryRangeInbox.shared.capture(request, body: body, sender: input.sender,
        date: receivedAt, evidence: input.evidence, senderDiagnostics: diagnostics)
    DeviceHistoryProbeBridge.notifyReady()
    return .result(value: result)
  }
}

@available(iOS 16.0, *)
struct ProbeMainAppHistoryInputIntent: AppIntent {
  static var title: LocalizedStringResource = "Probe Main-App History Input"
  static var description = IntentDescription("Sender lab only: the same four parameter IDs, types and explicit connections as main PandaPay history capture. Compare against Inspect Financial Message With Sender using the same Message properties. Does not call or change the main app.")
  static var openAppWhenRun = false
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  @Parameter(title: "Message body", inputConnectionBehavior: .never) var body: String?
  @Parameter(title: "Sender (text)", inputConnectionBehavior: .never, resolvers: { ProbeSenderTextResolver() }) var sender: String?
  @Parameter(title: "Original Message Date", inputConnectionBehavior: .never) var receivedAt: Date?
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let input = ProbeSenderValue.decode(sender)
    let diagnostics = input.diagnostics(action: "main_app_contract", parameter: "sender")
    let result = try DeviceHistoryRangeInbox.shared.capture(request, body: body ?? "", sender: input.sender,
        date: receivedAt, evidence: input.evidence, senderDiagnostics: diagnostics)
    DeviceHistoryProbeBridge.notifyReady()
    return .result(value: result)
  }
}

/// Historical Message.Sender is a MessagePerson wrapper. A separate property
/// extraction provides its Person value to this typed input without String
/// coercion or an email/phone-only selection mode. Existing actions stay intact.
@available(iOS 16.0, *)
struct ProbeDirectMessagePersonIntent: AppIntent {
  static var title: LocalizedStringResource = "Probe Message Sender Person"
  static var description = IntentDescription("Isolated sender lab: receive the Person property extracted from a historical Message's Sender entity. Records the actual supplied Person and primary handle without inventing an address. Does not change the main PandaPay app.")
  static var openAppWhenRun = false
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  @Parameter(title: "Message body", inputConnectionBehavior: .never) var body: String?
  @Parameter(title: "Sender Person", inputConnectionBehavior: .never) var sender: IntentPerson?
  @Parameter(title: "Original Message Date", inputConnectionBehavior: .never) var receivedAt: Date?

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let input = try ProbeSenderValue.direct(person: sender)
    let diagnostics = input.diagnostics(action: "direct_message_person", parameter: "sender")
    let result = try DeviceHistoryRangeInbox.shared.capture(request, body: body ?? "", sender: input.sender,
        date: receivedAt, evidence: input.evidence, senderDiagnostics: diagnostics)
    DeviceHistoryProbeBridge.notifyReady()
    return .result(value: result)
  }
}

@available(iOS 16.0, *)
struct FinishDeviceHistoryRangeIntent: AppIntent {
  static var title: LocalizedStringResource = "Finish PandaPay Range Import"
  static var openAppWhenRun = true
  @Parameter(title: "Range request") var request: String
  @Parameter(title: "Messages found") var found: Int
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let report = try DeviceHistoryRangeInbox.shared.finish(request, found: found)
    DeviceHistoryProbeBridge.notifyReady()
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    return .result(value: String(decoding: data, as: UTF8.self))
  }
}

enum DeviceHistoryProbeBridge {
  private static var channel: FlutterMethodChannel?

  static func register(messenger: FlutterBinaryMessenger) {
    let value = FlutterMethodChannel(name: "pandapay/ios_history_device_probe", binaryMessenger: messenger)
    channel = value
    value.setMethodCallHandler { call, result in
      if call.method == "drain" {
        result(DeviceHistoryProbeInbox.drain())
      } else if call.method == "readPending" {
        var snapshot = DeviceHistoryProbeInbox.readPending()
        let range = DeviceHistoryRangeInbox.shared.snapshot()
        snapshot["records"] = (snapshot["records"] as? [[String: Any]] ?? []) + (range["records"] as? [[String: Any]] ?? [])
        snapshot["runs"] = range["runs"]
        snapshot["live"] = DeviceLiveMessageInbox.shared.snapshot()
        result(snapshot)
      } else if call.method == "acknowledge" {
        guard let ids = call.arguments as? [String] else {
          result(FlutterError(code: "invalid_ack", message: "Expected capture identifiers", details: nil))
          return
        }
        DeviceHistoryProbeInbox.acknowledge(ids)
        DeviceHistoryRangeInbox.shared.acknowledge(ids)
        result(nil)
      } else if call.method == "completeLive" {
        guard let outcomes = call.arguments as? [[String: Any]] else {
          result(FlutterError(code: "invalid_live_ack", message: "Expected live outcomes", details: nil))
          return
        }
        DeviceLiveMessageInbox.shared.complete(outcomes)
        result(DeviceLiveMessageInbox.shared.snapshot())
      } else if call.method == "clear" {
        DeviceLiveMessageInbox.shared.clear()
        DeviceHistoryProbeInbox.clear()
        DeviceHistoryRangeInbox.shared.clear()
        ProbeDiagnosticsExport.clearReplay()
        result(true)
      } else if call.method == "readDiagnosticReplay" || call.method == "completeDiagnosticReplay" {
        guard Bundle.main.bundleIdentifier == "app.pandapay.iosimportprobe" else {
          result(FlutterError(code: "wrong_probe_bundle", message: "Replay is probe-only.", details: nil)); return
        }
        DispatchQueue.global(qos: .utility).async {
          do {
            let value: Any?
            if call.method == "readDiagnosticReplay" {
              value = try ProbeDiagnosticsExport.readReplay()
            } else {
              guard let args = call.arguments as? [String: Any], let fingerprint = args["fingerprint"] as? String,
                    let counts = args["counts"] as? [String: Int] else { throw ProbeExportError.invalidReport }
              try ProbeDiagnosticsExport.completeReplay(fingerprint, counts: counts)
              value = true
            }
            DispatchQueue.main.async { result(value) }
          } catch {
            DispatchQueue.main.async { result(FlutterError(code: "replay_failed", message: "The probe replay file could not be read.", details: nil)) }
          }
        }
      } else if call.method == "shareDiagnostics" {
        guard let json = call.arguments as? String else {
          result(FlutterError(code: "invalid_export", message: "Diagnostic report is missing.", details: nil))
          return
        }
        shareDiagnostics(json, result: result)
      } else if call.method == "runShortcut" {
        let name: String
        let input: String?
        if let dict = call.arguments as? [String: Any] {
          name = dict["name"] as? String ?? ""
          input = dict["input"] as? String
        } else if let str = call.arguments as? String {
          name = str
          input = nil
        } else {
          result(FlutterError(code: "invalid_args", message: "Expected shortcut name or configuration dictionary", details: nil))
          return
        }
        do {
          if let input {
            guard Bundle.main.bundleIdentifier == "app.pandapay.iosimportprobe" else { throw HistoryRangeError.invalidRequest }
            try DeviceHistoryRangeInbox.shared.registerForShortcut(name, request: input)
          }
        } catch {
          result(FlutterError(code: "invalid_range", message: error.localizedDescription, details: nil))
          return
        }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let input {
          components.queryItems! += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)]
        }
        guard !name.isEmpty, let url = components.url else {
          result(FlutterError(code: "invalid_url", message: "Malformed shortcut URL", details: nil))
          return
        }
        DispatchQueue.main.async {
          UIApplication.shared.open(url, options: [:]) { success in
            if !success, let input, let request = try? HistoryRangeRequest.parse(input) {
              DeviceHistoryRangeInbox.shared.launchFailed(request.id)
            }
            result(success)
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func notifyReady() {
    DispatchQueue.main.async { channel?.invokeMethod("ready", arguments: nil) }
  }

  private static var sharingDiagnostics = false
  private static func shareDiagnostics(_ json: String, result: @escaping FlutterResult) {
    guard Bundle.main.bundleIdentifier == "app.pandapay.iosimportprobe", !sharingDiagnostics else {
      result(FlutterError(code: "export_unavailable", message: "Diagnostic sharing is unavailable.", details: nil))
      return
    }
    sharingDiagnostics = true
    let metadata: [String: Any] = [
      "bundle_id": Bundle.main.bundleIdentifier ?? "",
      "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
      "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
      "system": UIDevice.current.systemName, "system_version": UIDevice.current.systemVersion,
      "device_family": UIDevice.current.model, "time_zone": TimeZone.current.identifier,
    ]
    DispatchQueue.global(qos: .utility).async {
      do {
        let file = try ProbeDiagnosticsExport.write(json, metadata: metadata)
        DispatchQueue.main.async {
          guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            ProbeDiagnosticsExport.remove(file); sharingDiagnostics = false
            result(FlutterError(code: "export_inactive", message: "Open the probe and try exporting again.", details: nil))
            return
          }
          while let next = presenter.presentedViewController { presenter = next }
          let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
          if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
          }
          sheet.completionWithItemsHandler = { _, completed, _, error in
            ProbeDiagnosticsExport.remove(file); sharingDiagnostics = false
            if error != nil {
              result(FlutterError(code: "share_failed", message: "The diagnostic file could not be shared. Try again.", details: nil))
            } else { result(completed ? "shared" : "cancelled") }
          }
          presenter.present(sheet, animated: true)
        }
      } catch {
        DispatchQueue.main.async {
          sharingDiagnostics = false
          let oversized = (error as? ProbeExportError) == .oversized
          result(FlutterError(code: oversized ? "export_too_large" : "export_failed",
            message: "The diagnostic file could not be created. Try a smaller test range.", details: nil))
        }
      }
    }
  }
}
#endif
