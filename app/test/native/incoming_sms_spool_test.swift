import Foundation
import SQLite3

func require(_ condition: Bool, _ message: String) {
  if !condition { fatalError(message) }
}
func fails(_ block: () throws -> Void) {
  do { try block(); fatalError("Expected rejection") } catch {}
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--cold-read" {
  let cold = IncomingSmsSpool(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
  print(try cold.snapshot()["pending"] as! Int)
  exit(0)
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("pandapay-spool-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let time = IncomingSmsSpool.date("2026-10-30T10:00:00Z")!
let receive = time.addingTimeInterval(-60)
let body = "INR 250 spent on ICICI Card XX1234 at SYNTHETIC CAFE. Ref TEST-01\n₹🙂"
let sender = "VM-ICICIB"
let spool = IncomingSmsSpool(directory: root, maxPending: 2, now: { time })
fails { _ = try spool.capture(body: body, sender: sender, receivedAt: receive, provenance: "original") }
let owner = try spool.configure(namespace: "user:synthetic-a", enabled: true, parserVersion: 22)
let generation = owner["generation"] as! String
require(try spool.capture(body: body, sender: sender, receivedAt: receive, provenance: "original") == "saved_for_processing", "save")
let restarted = IncomingSmsSpool(directory: root, maxPending: 2, now: { time })
var rows = try restarted.pending(generation: generation)
require(rows.count == 1, "survives fresh store/process")
let process = Process(), pipe = Pipe()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
process.arguments = ["--cold-read", root.path]; process.standardOutput = pipe
try process.run(); process.waitUntilExit()
let coldResult = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
require(process.terminationStatus == 0 && coldResult.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "durable save survives an independent cold process")
require(rows[0]["body"] as? String == body && rows[0]["sender"] as? String == sender, "exact input")
require(rows[0]["bodyCharacters"] as? Int == body.utf16.count, "UTF16 length")
require(try restarted.capture(body: body, sender: sender, receivedAt: receive, provenance: "original") == "already_saved", "occurrence replay")
require(try restarted.pending(generation: generation).count == 1, "no second raw copy")
let secret = "OTP 987654 valid for 5 minutes"
require(try spool.capture(body: secret, sender: sender, receivedAt: receive, provenance: "original") == "excluded_security", "security")
require(try spool.capture(body: secret, sender: nil, receivedAt: receive, provenance: "original") == "excluded_security", "security still applies without a sender")
try spool.acknowledge(generation: generation, outcomes: [["id": rows[0]["id"]!, "sourceKey": String(repeating: "a", count: 64), "parserVersion": 22, "outcome": "captured"]])
require(try restarted.pending(generation: generation).isEmpty, "ack after local receipt")
let bytes = try Data(contentsOf: root.appendingPathComponent("handoff.sqlite"))
require(bytes.range(of: Data(secret.utf8)) == nil, "security body never stored")
require(bytes.range(of: Data(body.utf8)) == nil, "raw input removed on ack")
_ = try spool.configure(namespace: "user:synthetic-a", parserVersion: 23)
_ = try spool.capture(body: body, sender: sender, receivedAt: receive, provenance: "original")
require(try restarted.pending(generation: generation).count == 1, "parser upgrade may re-evaluate")
_ = try spool.capture(body: body, sender: sender, receivedAt: receive, provenance: "estimated")
require(try restarted.pending(generation: generation).count == 2, "estimate not original occurrence identity")
fails { _ = try spool.capture(body: body, sender: sender, receivedAt: time, provenance: "original") }
require(try restarted.pending(generation: generation).count == 2, "capacity cannot drop old input")
_ = try spool.configure(namespace: "user:synthetic-a", enabled: false)
fails { _ = try restarted.pending(generation: generation) }
_ = try spool.configure(namespace: "user:synthetic-a", enabled: true, parserVersion: 23)
let next = try spool.snapshot()["generation"] as! String
require(next != generation, "re-enable fences old account generation")

let start = time.addingTimeInterval(-86_400), middle = time.addingTimeInterval(-43_200)
func iso(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
func observedStage(_ request: String, store: IncomingSmsSpool) throws -> String? {
  let attempt = (try JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any])["attempt"] as! String
  return (try store.snapshot()["windows"] as! [[String: Any]]).first { $0["attempt"] as? String == attempt }?["last_stage"] as? String
}
try spool.createJob(generation: next, id: UUID().uuidString, kind: "catchup", zone: "UTC", windows: [
  ["start": iso(start), "end": iso(middle)], ["start": iso(middle), "end": iso(time)]
])
let first = try spool.issue(generation: next)!
require(try spool.observeHandoff(request: first, stage: .launchRequested), "launch trace belongs to issued attempt")
require(try spool.observeHandoff(request: first, stage: .resumeRequested) == false, "no return to Shortcuts before committed completion")
require(try spool.observeHandoff(request: first, stage: .resumeStalled, expectedReceived: 0), "stalled waiting runner may resume without pretending the month is complete")
require(try spool.boundary(request: first, end: false) == start.addingTimeInterval(-1), "query includes start boundary")
require(try observedStage(first, store: spool) == nil, "launch validation must not claim a Shortcut action executed")
_ = try spool.boundary(request: first, end: false, observingIntent: true)
require(try observedStage(first, store: spool) == "window_start", "real Start handler can mark its invocation")
_ = try spool.boundary(request: first, end: true, observingIntent: true)
require(try observedStage(first, store: spool) == "window_end", "real End handler can mark its invocation")
require(try spool.finish(request: first, found: 0, limitOff: true, warning: false) == "complete", "empty window counts")
require(try spool.observeHandoff(request: first, stage: .resumeRequested), "completed receipt admits the existing runner handoff")
require(try spool.observeHandoff(request: first, stage: .returnedSuccess), "real callback trace remains distinct from completion")
require(try spool.snapshot()["last_handoff_attempt"] == nil, "handoff trace cannot expose attempt token")
require(try observedStage(first, store: spool) == "finish", "Finish stage stays separate from capture counts")
require(try spool.snapshot()["reconciledThrough"] as? String == iso(middle), "contiguous checkpoint")
let second = try spool.issue(generation: next)!
let secondAttempt = (try JSONSerialization.jsonObject(with: Data(second.utf8)) as! [String: Any])["attempt"] as! String
let secondHandoff = (try spool.snapshot()["windows"] as! [[String: Any]]).first { $0["attempt"] as? String == secondAttempt }
require(secondHandoff?["handoff_stage"] == nil, "new attempt cannot inherit another handoff trace")
require(try observedStage(second, store: spool) == nil, "a new attempt cannot inherit an earlier action trace")
_ = try spool.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: second, itemID: "1")
require(try spool.observeHandoff(request: second, stage: .resumeStalled, expectedReceived: 0) == false, "new arrival invalidates stale inactivity count")
require(try spool.observeHandoff(request: second, stage: .resumeStalled, expectedReceived: 1), "unchanged running count admits only runner resumption")
require(try spool.observeHandoff(request: second, stage: .appReturnRequested), "foreground return is scoped to the active request")
require(try observedStage(second, store: spool) == "capture", "Capture records arrival without raw diagnostic content")
require(try spool.snapshot()["last_intent_attempt"] == nil, "diagnostic trace cannot add an exposed request token")
_ = try spool.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: second, itemID: "1")
fails { _ = try spool.capture(body: body + " reordered source", sender: sender, receivedAt: receive, provenance: "original", request: second, itemID: "1") }
require(try spool.pending(generation: next).count == 1, "a reused Repeat Index cannot silently accept a different message")
require(try spool.finish(request: second, found: 1, limitOff: true, warning: false) == "finished", "finish must wait for shared processing")
require(try spool.snapshot()["reconciledThrough"] as? String == iso(middle), "pending is not checked coverage")
rows = try spool.pending(generation: next)
try spool.acknowledge(generation: next, outcomes: [["id": rows[0]["id"]!, "sourceKey": String(repeating: "b", count: 64), "parserVersion": 23, "outcome": "ignored"]])
require(try spool.snapshot()["reconciledThrough"] as? String == iso(time), "intentional ignore completes handoff")
require(try spool.finish(request: second, found: 1, limitOff: true, warning: false) == "complete", "idempotent finish")

try spool.createJob(generation: next, id: UUID().uuidString, kind: "history", zone: "UTC", windows: [["start": iso(start), "end": iso(time)]])
let history = try spool.issue(generation: next)!
_ = try spool.capture(body: body, sender: sender, receivedAt: time, provenance: "original", request: history, itemID: "1")
require(try spool.finish(request: history, found: 2, limitOff: true, warning: false) == "partial", "mismatched count never complete")
try spool.control(generation: next, command: "split")
fails { _ = try spool.boundary(request: history, end: false) }
let child = try spool.issue(generation: next)!
require(try spool.boundary(request: child, end: true) == middle, "dense window split has adjacent exact halves")
let splitSnapshot = try spool.snapshot()
let latestJob = (splitSnapshot["jobs"] as! [[String: Any]])[0]["id"] as! String
let splitWindows = (splitSnapshot["windows"] as! [[String: Any]]).filter { $0["job_id"] as? String == latestJob }
require(splitWindows.count == 2 && Set(splitWindows.map { $0["logical_id"] as! String }).count == 1, "split children retain one logical month")
try spool.control(generation: next, command: "pause")
fails { _ = try spool.observeHandoff(request: child, stage: .resumeStalled, expectedReceived: 0) }
fails { _ = try spool.capture(body: body, sender: sender, receivedAt: start, provenance: "original", request: child, itemID: "1") }
try spool.control(generation: next, command: "resume")
_ = try spool.configure(namespace: "user:synthetic-b", enabled: true)
fails { _ = try spool.boundary(request: child, end: false) }
require(try spool.snapshot()["reconciledThrough"] == nil, "coverage cannot cross accounts")
require(try spool.snapshot()["pending"] as? Int == 0, "account switch clears private pending input")
let concurrentErrors = NSLock()
var errors = 0
DispatchQueue.concurrentPerform(iterations: 16) { _ in
  do {
    let writer = IncomingSmsSpool(directory: root, now: { time })
    _ = try writer.capture(body: body, sender: sender, receivedAt: receive, provenance: "original")
  } catch { concurrentErrors.lock(); errors += 1; concurrentErrors.unlock() }
}
require(errors == 0, "concurrent writers must arbitrate through SQLite")
require(try spool.snapshot()["pending"] as? Int == 1, "concurrent duplicates create one pending source occurrence")
print("PASS: durable native SMS handoff, exact fields, no inference, security, replay, parser upgrade, capacity, accounts, ranges, receipts and restart")

// A pending/partial catch-up must not trap the user outside history import.
// Replacement is atomic and account/job scoped; capture/coverage data survives.
do {
  let store = IncomingSmsSpool(directory: root.appendingPathComponent("replace-period"), now: { time })
  let account = try store.configure(namespace: "user:replace-period", enabled: true, parserVersion: 23)
  let g = account["generation"] as! String, oldID = UUID().uuidString, newID = UUID().uuidString
  let range = [["start": iso(start), "end": iso(time)]]
  try store.createJob(generation: g, id: oldID, kind: "catchup", zone: "UTC", windows: range)
  let oldRequest = try store.issue(generation: g)!
  _ = try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: oldRequest, itemID: "1")
  _ = try store.capture(body: body, sender: sender, receivedAt: nil, provenance: "original", request: oldRequest, itemID: "2")
  require(try store.finish(request: oldRequest, found: 2, limitOff: true, warning: false) == "partial", "missing metadata leaves the old check partial")
  require((try store.snapshot()["windows"] as! [[String: Any]])[0]["incomplete"] as? Int == 1, "partial status exposes missing required metadata without message contents")
  fails { try store.createJob(generation: g, id: newID, kind: "history", zone: "UTC", windows: range) }
  fails { try store.createJob(generation: g, id: newID, kind: "history", zone: "UTC", windows: range, replacingJobID: UUID().uuidString) }
  // Fail after the first insert to exercise the whole transaction rollback.
  fails { try store.createJob(generation: g, id: newID, kind: "history", zone: "UTC", windows: [
    ["start": iso(start), "end": iso(middle)], ["start": iso(middle.addingTimeInterval(1)), "end": iso(time)]
  ], replacingJobID: oldID) }
  var jobs = try store.snapshot()["jobs"] as! [[String: Any]]
  require(jobs.count == 1 && jobs[0]["state"] as? String == "active", "failed replacement leaves the previous job available")
  try store.createJob(generation: g, id: newID, kind: "history", zone: "UTC", windows: range, replacingJobID: oldID)
  jobs = try store.snapshot()["jobs"] as! [[String: Any]]
  require(jobs.first { $0["id"] as? String == oldID }?["state"] as? String == "stopped", "only the explicitly replaced job stops")
  require(jobs.first { $0["id"] as? String == newID }?["state"] as? String == "active", "selected history becomes active")
  require(try store.pending(generation: g).count == 1, "changing the period preserves pending input")
  require(try store.snapshot()["reconciledThrough"] == nil, "replacing a partial check cannot fabricate checked coverage")
  fails { _ = try store.boundary(request: oldRequest, end: false) }
  fails { _ = try store.finish(request: oldRequest, found: 2, limitOff: true, warning: false) }
  let newRequest = try store.issue(generation: g)!
  require(try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: newRequest, useMessageReceipt: true) == "already_saved", "new history keeps existing duplicate protection")
  let pending = try store.pending(generation: g)
  try store.acknowledge(generation: g, outcomes: pending.map { ["id": $0["id"]!, "sourceKey": String(repeating: "e", count: 64), "parserVersion": 23, "outcome": "captured"] })
  require(try store.snapshot()["reconciledThrough"] == nil, "draining saved input alone does not complete the replacement")
  let cold = IncomingSmsSpool(directory: root.appendingPathComponent("replace-period"), now: { time })
  require(try cold.pending(generation: g).isEmpty, "committed processing survives replacement/restart")
  require(try cold.finish(request: newRequest, found: 1, limitOff: true, warning: false) == "complete", "new history still requires matching committed receipts")
}
print("PASS: atomic history-period replacement, retained input, rollback, stale callbacks and duplicate protection")

do {
  let store = IncomingSmsSpool(directory: root.appendingPathComponent("unknown-sender"), now: { time })
  let g = try store.configure(namespace: "user:unknown-sender", enabled: true)["generation"] as! String
  try store.createJob(generation: g, id: UUID().uuidString, kind: "history", zone: "UTC", windows: [["start": iso(start), "end": iso(time)]])
  let request = try store.issue(generation: g)!
  require(try store.capture(body: body, sender: nil, receivedAt: receive, provenance: "original", request: request, useMessageReceipt: true) == "saved_without_sender", "missing sender retains input for shared classification")
  require(try store.capture(body: body, sender: "  ", receivedAt: receive, provenance: "original", request: request, useMessageReceipt: true) == "saved_without_sender", "same-attempt replay cannot duplicate unknown input")
  let pending = try store.pending(generation: g)
  require(pending.count == 1 && pending[0]["body"] as? String == body, "full unknown-sender input survives until shared receipt")
  require(pending[0]["sender"] as? String == "" && pending[0]["senderEvidence"] as? String == "missing", "never invent a bank sender")
  require(try store.finish(request: request, found: 1, limitOff: true, warning: false) == "finished", "unknown sender waits for committed review, not silent rejection")
  try store.acknowledge(generation: g, outcomes: [["id": pending[0]["id"]!, "sourceKey": String(repeating: "f", count: 64), "parserVersion": 23, "outcome": "review"]])
  require(try store.finish(request: request, found: 1, limitOff: true, warning: false) == "complete", "committed review counts as successful acquisition")
  let resultWindow = (try store.snapshot()["windows"] as! [[String: Any]])[0]
  require(resultWindow["enumerated"] as? Int == 1 && resultWindow["processed"] as? Int == 1 && resultWindow["needs_review"] as? Int == 1, "UI counters distinguish arrival, processing and review")
  require(try store.pending(generation: g).isEmpty, "raw input clears only after durable shared review")
  require(try store.capture(body: secret, sender: nil, receivedAt: receive, provenance: "original") == "excluded_security", "security input never enters missing-sender review")
}
print("PASS: unknown sender input retained without inference, committed review completion and security exclusion")

// The probe-compatible receiver has no Repeat Index. Native input-bound
// receipts must stay idempotent while preserving the independent Find count.
do {
  let contentRoot = root.appendingPathComponent("message-receipts")
  let store = IncomingSmsSpool(directory: contentRoot, maxPending: 20, now: { time })
  let account = try store.configure(namespace: "user:content-receipts", enabled: true, parserVersion: 23)
  let g = account["generation"] as! String
  func request() throws -> String {
    try store.control(generation: g, command: "stop")
    try store.createJob(generation: g, id: UUID().uuidString, kind: "history", zone: "UTC", windows: [["start": iso(start), "end": iso(time)]])
    return try store.issue(generation: g)!
  }
  func window(_ request: String) throws -> [String: Any] {
    let attempt = (try JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any])["attempt"] as! String
    return (try store.snapshot()["windows"] as! [[String: Any]]).first { $0["attempt"] as? String == attempt }!
  }
  fails { _ = try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", useMessageReceipt: true) }
  let r = try request(), secondBody = body + " OTHER REFERENCE"
  fails { _ = try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: r, itemID: "1", useMessageReceipt: true) }
  _ = try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: r, useMessageReceipt: true)
  _ = try store.capture(body: secondBody, sender: sender, receivedAt: receive, provenance: "original", request: r, useMessageReceipt: true)
  // Reordered retries resolve the original receipts, not new enumerations.
  _ = try store.capture(body: secondBody, sender: sender, receivedAt: receive, provenance: "original", request: r, useMessageReceipt: true)
  _ = try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: r, useMessageReceipt: true)
  require(try window(r)["enumerated"] as? Int == 2, "content receipt replay cannot inflate source counts")
  require(try store.pending(generation: g).count == 2, "content receipts retain each distinct body once")
  require(try store.finish(request: r, found: 2, limitOff: true, warning: false) == "finished", "content receipts still wait for committed processing")
  let pending = try store.pending(generation: g)
  try store.acknowledge(generation: g, outcomes: pending.map { ["id": $0["id"]!, "sourceKey": String(repeating: "c", count: 64), "parserVersion": 23, "outcome": "captured"] })
  require(try window(r)["state"] as? String == "complete", "matching committed content receipts complete the window")

  let duplicateRange = try request()
  _ = try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: duplicateRange, useMessageReceipt: true)
  _ = try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: duplicateRange, useMessageReceipt: true)
  require(try store.pending(generation: g).isEmpty, "reacquisition cannot duplicate a committed occurrence")
  require(try store.finish(request: duplicateRange, found: 2, limitOff: true, warning: false) == "partial", "indistinguishable Find rows cannot claim complete coverage")

  let distinct = try request()
  _ = try store.capture(body: body, sender: sender, receivedAt: receive.addingTimeInterval(1), provenance: "original", request: distinct, useMessageReceipt: true)
  _ = try store.capture(body: body, sender: "VM-OTHER", receivedAt: receive, provenance: "original", request: distinct, useMessageReceipt: true)
  require(try window(distinct)["enumerated"] as? Int == 2, "different original dates and senders remain distinct")

  let rejected = try request()
  let countBefore = try store.pending(generation: g).count
  require(try store.capture(body: secret, sender: sender, receivedAt: receive, provenance: "original", request: rejected, useMessageReceipt: true) == "excluded_security", "sensitive message uses a redacted receipt")
  require(try store.pending(generation: g).count == countBefore, "sensitive message cannot enter pending input")
  do {
    var database: OpaquePointer?, statement: OpaquePointer?
    require(sqlite3_open_v2(contentRoot.appendingPathComponent("handoff.sqlite").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "open synthetic receipt audit")
    defer { sqlite3_finalize(statement); sqlite3_close(database) }
    require(sqlite3_prepare_v2(database, "SELECT item_id,binding FROM receipts WHERE outcome='excluded_security'", -1, &statement, nil) == SQLITE_OK, "inspect synthetic redaction metadata")
    require(sqlite3_step(statement) == SQLITE_ROW, "redacted receipt exists")
    require(String(cString: sqlite3_column_text(statement, 0)).hasPrefix("redacted:"), "sensitive receipt has an opaque identifier")
    require(sqlite3_column_type(statement, 1) == SQLITE_NULL, "sensitive receipt cannot store a body hash")
  }
  require(try Data(contentsOf: contentRoot.appendingPathComponent("handoff.sqlite")).range(of: Data(secret.utf8)) == nil, "sensitive raw body never enters the store")
  _ = try store.configure(namespace: "user:other-content-account", enabled: true)
  fails { _ = try store.capture(body: body, sender: sender, receivedAt: receive, provenance: "original", request: rejected, useMessageReceipt: true) }
}
print("PASS: native message receipts, reordered replay, independent counts, duplicate safety, original-date identity, account fencing and sensitive redaction")
let launch = try SmsShortcutLaunch(name: "PANDAPAY SMS HISTORY & test", request: history)
let launchParts = URLComponents(url: launch.url, resolvingAgainstBaseURL: false)!
require(launchParts.host == "x-callback-url" && launchParts.path == "/run-shortcut", "documented callback launch")
require(launch.resumeURL.absoluteString == "shortcuts://", "resume opens the existing runner without request data or a second run-shortcut")
var presentation = SmsShortcutForegroundReturn(request: history)
require(!presentation.claim(request: "unrelated", appIsActive: false), "unrelated Shortcut cannot consume a foreground return")
require(!presentation.claim(request: history, appIsActive: true), "already-active app does not consume foreground budget")
require(presentation.claim(request: history, appIsActive: false), "interactive run returns after first capture")
require(!presentation.claim(request: history, appIsActive: false), "each subsequent SMS cannot repeatedly foreground the app")
presentation.resumedRunner()
require(presentation.claim(request: history, appIsActive: false), "an admitted runner-resume burst can return once again")
let success = URL(string: launchParts.queryItems!.first(where: { $0.name == "x-success" })!.value!)!
require(launch.result(success)?["status"] == "success", "matching callback accepted")
require(launch.result(URL(string: "pandapay://sms-import/success?token=wrong")!) == nil, "foreign callback rejected")
let extra = URL(string: success.absoluteString + "&errorMessage=private&result=private")!
require(launch.result(extra)?.count == 2, "callback input is never forwarded to diagnostics")
print("PASS: callback escaping, scoped nonce and no raw result forwarding")
