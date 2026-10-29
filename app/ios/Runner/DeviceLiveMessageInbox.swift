// Live single-message diagnostics only. Recent inputs remain in memory only.
import Foundation
import CryptoKit

final class DeviceLiveMessageInbox {
  static let shared = DeviceLiveMessageInbox()
  private let lock = NSLock()
  private var events: [[String: Any]] = []
  private var pending: [[String: Any]] = []
  private var identities = Set<String>()
  private var counts: [String: Int] = [:]
  private var lastInvokedAt: String?
  private let limit: Int
  private let eventLimit: Int
  private let now: () -> Date
  init(limit: Int = 2500, eventLimit: Int = 30, now: @escaping () -> Date = Date.init) {
    self.limit = limit; self.eventLimit = eventLimit; self.now = now
  }
  private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  /// Called by BOTH single-message perform() implementations. Invocation is
  /// recorded even when an optional input is absent. Conversion failures before
  /// perform() remain unobservable. Recent events are process-local diagnostics.
  func capture(body: String?, sender: String, receivedAt: Date?, evidence: String,
               handler: String, allowedBundle: Bool) -> String {
    lock.lock(); defer { lock.unlock() }
    let id = "live:\(UUID().uuidString)"
    let invoked = stamp(now())
    lastInvokedAt = invoked
    counts["calls", default: 0] += 1
    if body != nil { counts["records_received", default: 0] += 1 }
    let missingSender = sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if missingSender { counts["missing_sender", default: 0] += 1 }
    if receivedAt == nil { counts["missing_date", default: 0] += 1 }
    var event: [String: Any] = [
      "id": id, "invokedAt": invoked, "handler": handler,
      "missingSender": missingSender, "missingDate": receivedAt == nil,
      "bodyPresent": body != nil, "bodyCharacters": body?.utf16.count ?? 0,
      "senderEvidence": evidence,
    ]
    if allowedBundle {
      if let body { event["inputBody"] = body }
      event["inputSender"] = sender
      if let receivedAt { event["inputDate"] = stamp(receivedAt) }
    }
    func finish(_ state: String) -> String {
      counts[state, default: 0] += 1
      event["state"] = state
      events.append(event)
      if events.count > eventLimit { events.removeFirst(events.count - eventLimit) }
      return state
    }
    guard allowedBundle else { return finish("wrong_probe_bundle") }
    guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          body.utf16.count <= 20_000 else { return finish("invalid") }
    if SmsSecurityPolicy.sensitive(body) {
      return finish("sensitive")
    }
    guard let receivedAt else { return finish("missing_date_rejected") }
    let original = stamp(receivedAt)
    let identity = SHA256.hash(data: Data("\(sender)\n\(original)\n\(body)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    guard !identities.contains(identity) else { return finish("native_duplicate") }
    guard identities.count < limit, pending.count < limit else { return finish("capacity_rejected") }
    identities.insert(identity)
    event["receivedAt"] = original
    pending.append([
      "id": id, "origin": "live", "runId": "live", "body": body,
      "sender": sender, "senderEvidence": evidence, "receivedAt": original,
      "capturedAt": invoked, "bodyCharacters": body.utf16.count,
    ])
    return finish("pending")
  }

  /// Acknowledge only safe, explicit shared-intake outcomes. Failure remains
  /// pending and can retry; repeated confirmations cannot double-count success.
  func complete(_ outcomes: [[String: Any]]) {
    lock.lock(); defer { lock.unlock() }
    let terminal = Set(["retained_new", "retained_existing", "ignored", "rejected_sensitive", "rejected_invalid", "rejected_missing_date"])
    for outcome in outcomes {
      guard let id = outcome["id"] as? String,
            pending.contains(where: { $0["id"] as? String == id }),
            let state = outcome["outcome"] as? String,
            terminal.contains(state) || state == "processing_error" else { continue }
      if state == "processing_error" {
        counts["processing_errors", default: 0] += 1
      } else {
        pending.removeAll { $0["id"] as? String == id }
        counts["processed", default: 0] += 1
        counts[state, default: 0] += 1
        if outcome["senderInferred"] as? Bool == true && (state == "retained_new" || state == "retained_existing") { counts["sender_inferred", default: 0] += 1 }
      }
      if let i = events.firstIndex(where: { $0["id"] as? String == id }) {
        events[i]["state"] = state
        events[i]["senderInferred"] = outcome["senderInferred"] as? Bool ?? false
        for key in ["effectiveSender", "triageKind", "triageReason", "intakeDecision", "intakeReason", "transactionsAdded", "parserOutput"] {
          if let value = outcome[key] { events[i][key] = value }
        }
        if terminal.contains(state) { events[i]["processedAt"] = stamp(now()) }
      }
    }
  }

  func snapshot() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    var totals = counts
    totals["pending"] = pending.count
    var result: [String: Any] = ["records": pending, "counts": totals, "events": Array(events.reversed())]
    if let lastInvokedAt { result["lastInvokedAt"] = lastInvokedAt }
    return result
  }
  func clear() {
    lock.lock(); defer { lock.unlock() }
    events.removeAll(); pending.removeAll(); identities.removeAll(); counts.removeAll(); lastInvokedAt = nil
  }
}
