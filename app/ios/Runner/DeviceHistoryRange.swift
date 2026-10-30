// Isolated diagnostic range protocol. Foundation-only so synthetic tests run on Mac.
import Foundation
import CryptoKit

struct HistoryRangeRequest: Equatable {
  let id: String
  let start: Date
  let end: Date

  static func parse(_ text: String) throws -> HistoryRangeRequest {
    guard text.utf8.count < 4096,
          let data = text.data(using: .utf8),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["version"] as? Int == 2,
          let id = json["run_id"] as? String, UUID(uuidString: id) != nil,
          let startText = json["start_inclusive"] as? String,
          let endText = json["end_exclusive"] as? String,
          let start = isoDate(startText), let end = isoDate(endText), start < end else {
      throw HistoryRangeError.invalidRequest
    }
    return HistoryRangeRequest(id: id, start: start, end: end)
  }

  static func isoDate(_ value: String) -> Date? {
    guard value.range(of: #"(?:Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

enum HistoryRangeError: Error, LocalizedError {
  case invalidRequest, unknownRun, finishedRun
  var errorDescription: String? {
    switch self {
    case .invalidRequest: return "Invalid PandaPay range request. Start this shortcut from the updated app."
    case .unknownRun: return "This range is no longer active. Return to PandaPay and fetch again."
    case .finishedRun: return "This import has already finished. Start a new fetch in PandaPay."
    }
  }
}

final class DeviceHistoryRangeInbox {
  static let shared = DeviceHistoryRangeInbox()
  private let lock = NSLock()
  private struct Run {
    let request: HistoryRangeRequest
    var status = "waiting_for_shortcut"
    var counts: [String: Int] = [:]
    var identities = Set<String>()
    var report: [String: Any] {
      ["run_id": request.id, "status": status, "counts": counts]
    }
  }
  private var runs: [Run] = []
  private var pending: [[String: Any]] = []
  private let limit: Int
  init(limit: Int = 2000) { self.limit = limit }

  private func index(_ text: String) throws -> Int {
    let request = try HistoryRangeRequest.parse(text)
    guard let i = runs.firstIndex(where: { $0.request == request }),
          i == runs.indices.last else { throw HistoryRangeError.unknownRun }
    return i
  }

  func register(_ text: String) throws {
    let request = try HistoryRangeRequest.parse(text)
    lock.lock(); defer { lock.unlock() }
    guard !runs.contains(where: { $0.request.id == request.id }) else { throw HistoryRangeError.invalidRequest }
    if let i = runs.indices.last, ["waiting_for_shortcut", "running"].contains(runs[i].status) {
      runs[i].status = "interrupted"
    }
    runs.append(Run(request: request))
    if runs.count > 20 { runs.removeFirst() }
  }

  func boundary(_ text: String, end: Bool) throws -> Date {
    lock.lock(); defer { lock.unlock() }
    let i = try index(text)
    guard ["waiting_for_shortcut", "running"].contains(runs[i].status) else { throw HistoryRangeError.finishedRun }
    runs[i].status = "running"
    // Find Message's Between operator can include either endpoint. Query a
    // one-second superset; capture enforces the exact half-open interval.
    return end ? runs[i].request.end : runs[i].request.start.addingTimeInterval(-1)
  }

  func capture(_ text: String, body: String, sender: String, date: Date?, evidence: String) throws -> String {
    lock.lock(); defer { lock.unlock() }
    let i = try index(text)
    guard runs[i].status == "running" else { throw HistoryRangeError.finishedRun }
    runs[i].counts["received", default: 0] += 1
    func reject(_ outcome: String) -> String {
      runs[i].counts[outcome, default: 0] += 1
      return outcome
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf16.count <= 20_000 else { return reject("invalid") }
    if SmsSecurityPolicy.sensitive(body) { return reject("sensitive") }
    if sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runs[i].counts["missing_sender", default: 0] += 1 }
    guard let date else { return reject("missing_date") }
    guard date >= runs[i].request.start, date < runs[i].request.end else { return reject("out_of_range") }
    let stamp = ISO8601DateFormatter(); stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let original = stamp.string(from: date)
    let identity = SHA256.hash(data: Data("\(sender)\n\(original)\n\(body)".utf8)).map { String(format: "%02x", $0) }.joined()
    guard !runs[i].identities.contains(identity) else { return reject("duplicates") }
    guard runs[i].identities.count < limit, pending.count < 2500 else { return reject("limit_reached") }
    runs[i].identities.insert(identity)
    pending.append([
      "id": "\(runs[i].request.id):\(identity)", "runId": runs[i].request.id,
      "body": body, "sender": sender, "senderEvidence": evidence,
      "receivedAt": original, "capturedAt": stamp.string(from: Date()), "bodyCharacters": body.utf16.count,
    ])
    runs[i].counts["accepted", default: 0] += 1
    return "accepted"
  }

  func finish(_ text: String, found: Int) throws -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    let i = try index(text)
    guard runs[i].status == "running", found >= 0 else { throw HistoryRangeError.finishedRun }
    runs[i].counts["found"] = found
    runs[i].status = found == runs[i].counts["received", default: 0] ? "completed" : "incomplete_handoff"
    return runs[i].report
  }

  func launchFailed(_ id: String) {
    lock.lock(); defer { lock.unlock() }
    if let i = runs.firstIndex(where: { $0.request.id == id }), runs[i].status == "waiting_for_shortcut" { runs[i].status = "launch_failed" }
  }
  func snapshot() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return ["records": pending, "runs": runs.map(\.report)]
  }
  func acknowledge(_ ids: [String]) {
    lock.lock(); defer { lock.unlock() }
    let ids = Set(ids); pending.removeAll { ids.contains($0["id"] as? String ?? "") }
  }
  func clear() {
    lock.lock(); defer { lock.unlock() }
    pending.removeAll(); runs.removeAll()
  }
}
