import Foundation
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
let received = HistoryRangeRequest.isoDate("2026-10-29T08:11:23Z")!
for row in rows {
  let body = row["body"] as! String; let secret = row["sensitive"] as! Bool; let id = row["id"] as! String
  expect(SmsSecurityPolicy.sensitive(body) == secret, "native policy mismatch: \(id)")
  let inbox = DeviceLiveMessageInbox()
  let result = inbox.capture(body: body, sender: "", receivedAt: received, evidence: "missing_person", handler: "text_sender", allowedBundle: true)
  expect(result == (secret ? "sensitive" : "pending"), "native live gate mismatch: \(id)")
  let retained = inbox.snapshot()["records"] as! [[String:Any]]
  expect(retained.count == (secret ? 0 : 1), "native retention mismatch: \(id)")
  if !secret { expect(retained[0]["body"] as? String == body, "original body unchanged") }
  let noDate = DeviceLiveMessageInbox()
  let missing = noDate.capture(body: body, sender: "", receivedAt: nil, evidence: "missing_person", handler: "person_sender", allowedBundle: true)
  expect(missing == (secret ? "sensitive" : "missing_date_rejected"), "date policy mismatch: \(id)")
  expect((noDate.snapshot()["records"] as! [[String:Any]]).isEmpty, "no fabricated date")
  let range = DeviceHistoryRangeInbox()
  let request = "{\"version\":2,\"run_id\":\"\(UUID().uuidString)\",\"start_inclusive\":\"2026-10-01T00:00:00Z\",\"end_exclusive\":\"2026-11-01T00:00:00Z\"}"
  try range.register(request); _ = try range.boundary(request,end:false)
  let captured = try range.capture(request,body:body,sender:"TEST",date:received,evidence:"text")
  expect(captured == (secret ? "sensitive" : "accepted"), "range gate mismatch: \(id)")
}
print("PASS: common synthetic security corpus (\(rows.count) cases), live and range privacy gates, original bodies, missing-date blocking")
