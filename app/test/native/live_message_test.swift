import Foundation
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let imported = Date(timeIntervalSince1970: 1_793_246_400)
let received = imported.addingTimeInterval(-3600)
let inbox = DeviceLiveMessageInbox(now: { imported })
func capture(_ body: String?, _ date: Date? = received, _ handler: String = "person_sender", _ sender: String = "") -> String {
  inbox.capture(body: body, sender: sender, receivedAt: date, evidence: sender.isEmpty ? "missing_person" : "text", handler: handler, allowedBundle: true)
}
func counts() -> [String: Int] { inbox.snapshot()["counts"] as! [String: Int] }
expect(counts()["calls"] == nil, "idle has no observed handoff")
// History acquisition cannot reach this receiver.
let range = DeviceHistoryRangeInbox()
let request = "{\"version\":2,\"run_id\":\"\(UUID().uuidString)\",\"start_inclusive\":\"2026-09-01T00:00:00Z\",\"end_exclusive\":\"2026-10-01T00:00:00Z\"}"
try range.register(request); let date = try range.boundary(request, end: false).addingTimeInterval(1)
_ = try range.capture(request, body: "synthetic history", sender: "TEST", date: date, evidence: "text")
expect(counts()["calls"] == nil, "history does not inflate live counters")
expect(capture(nil, nil) == "invalid", "missing body attempt recorded")
expect(capture(" ") == "invalid", "blank invalid")
expect(capture(String(repeating: "x", count: 20001)) == "invalid", "oversized invalid")
expect(capture("OTP 123456. Do not share.") == "sensitive", "security body excluded")
expect(capture("synthetic body with date 03-03-2026", nil) == "missing_date_rejected", "no body date substitution")
expect(capture("synthetic financial text") == "pending", "person single handler pending")
expect(capture("synthetic text handler", received, "text_sender", "TEST-BANK") == "pending", "text single handler pending")
expect(capture("synthetic financial text") == "native_duplicate", "same native record dedup")
expect(counts()["calls"] == 8 && counts()["records_received"] == 7, "all attempts counted before rejection")
expect(counts()["pending"] == 2 && counts()["processed"] == nil, "pending is not success")
let rows = inbox.snapshot()["records"] as! [[String: Any]]
expect(rows.count == 2 && rows[0]["origin"] as? String == "live", "live traffic labelled")
expect(rows[0]["receivedAt"] as? String != rows[0]["capturedAt"] as? String, "receive/import times distinct")
let report = inbox.snapshot()["events"] as! [[String: Any]]
expect(report.contains { $0["inputBody"] as? String == "OTP 123456. Do not share." && $0["state"] as? String == "sensitive" }, "sensitive input visible in process-local diagnostic")
expect(!String(describing: rows).contains("OTP 123456"), "sensitive input never enters processing queue")
let id = rows[0]["id"] as! String
inbox.complete([["id": id, "outcome": "processing_error"]])
expect(counts()["pending"] == 2 && counts()["processed"] == nil && counts()["processing_errors"] == 1, "failure retains pending")
expect((inbox.snapshot()["events"] as! [[String: Any]]).first(where: { $0["id"] as? String == id })!["state"] as? String == "processing_error", "failure state visible")
inbox.complete([["id": id, "outcome": "retained_new", "senderInferred": true, "triageKind": "financialCandidate", "triageReason": "financial", "parserOutput": "synthetic result"]])
let completedEvent = (inbox.snapshot()["events"] as! [[String: Any]]).first(where: { $0["id"] as? String == id })!
expect(completedEvent["triageKind"] as? String == "financialCandidate" && completedEvent["parserOutput"] as? String == "synthetic result", "processing details are visible with the original event")
inbox.complete([["id": id, "outcome": "retained_new", "senderInferred": true]])
expect(counts()["pending"] == 1 && counts()["processed"] == 1 && counts()["retained_new"] == 1 && counts()["sender_inferred"] == 1, "retry acknowledgement idempotent")
let id2 = rows[1]["id"] as! String
inbox.complete([["id": id2, "outcome": "unrecognized"], ["id": "wrong-id", "outcome": "retained_new"]])
expect(counts()["pending"] == 1, "unknown outcomes do not acknowledge")
inbox.complete([["id": id2, "outcome": "ignored"]])
expect(counts()["pending"] == 0 && counts()["processed"] == 2 && counts()["ignored"] == 1, "ignored tracked separately")
let limited = DeviceLiveMessageInbox(limit: 1, eventLimit: 2)
expect(limited.capture(body: "a", sender: "TEST", receivedAt: received, evidence: "text", handler: "text_sender", allowedBundle: false) == "wrong_probe_bundle", "bundle gate")
expect((limited.snapshot()["events"] as! [[String: Any]])[0]["inputBody"] == nil, "other bundles do not expose diagnostic input")
_ = limited.capture(body: "a", sender: "TEST", receivedAt: received, evidence: "text", handler: "text_sender", allowedBundle: true)
expect(limited.capture(body: "b", sender: "TEST", receivedAt: received, evidence: "text", handler: "text_sender", allowedBundle: true) == "capacity_rejected", "capacity explicit")
expect((limited.snapshot()["events"] as! [[String: Any]]).count == 2, "recent list bounded")
limited.clear()
expect((limited.snapshot()["counts"] as! [String: Int])["calls"] == nil && (limited.snapshot()["records"] as! [[String: Any]]).isEmpty, "explicit session reset")
let senderInbox = DeviceLiveMessageInbox()
for sender in ["VM-UBINBK", "AD-SLICE-S", "123456", "+919000000001", "", "  "] {
  let state = senderInbox.capture(body: "Synthetic sender test", sender: sender, receivedAt: received,
    evidence: sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "missing_text" : "text",
    handler: "person_sender", allowedBundle: true)
  expect(state == "pending", "plain text and missing senders do not require contacts")
  let event = (senderInbox.snapshot()["events"] as! [[String: Any]])[0]
  expect(event["inputSender"] as? String == sender, "sender input preserved without conversion or invention")
  expect(event["missingSender"] as? Bool == sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "missing sender explicit")
}
print("PASS: native live attempts, both handlers, privacy, date/size rejection, history separation, retry, completion, bounded metadata")
