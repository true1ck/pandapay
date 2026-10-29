import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}
func request(_ id: String = UUID().uuidString) -> String {
  "{\"version\":2,\"run_id\":\"\(id)\",\"start_inclusive\":\"2026-08-31T18:30:00.000Z\",\"end_exclusive\":\"2026-09-30T18:30:00.000Z\"}"
}
let inbox = DeviceHistoryRangeInbox()
let text = request()
try inbox.register(text)
let start = try inbox.boundary(text, end: false).addingTimeInterval(1)
let end = try inbox.boundary(text, end: true)
expect(start == HistoryRangeRequest.isoDate("2026-09-01T00:00:00+05:30")!, "zoned calendar boundary")
func capture(_ body: String, _ date: Date?, _ sender: String = "TEST-BANK") throws -> String {
  try inbox.capture(text, body: body, sender: sender, date: date, evidence: "handle")
}
expect(try! capture("synthetic first", start) == "accepted", "start inclusive")
expect(try! capture("synthetic last", end.addingTimeInterval(-0.001), "") == "accepted", "final millisecond")
expect(try! capture("synthetic next month", end) == "out_of_range", "end exclusive")
expect(try! capture("synthetic before", start.addingTimeInterval(-0.001)) == "out_of_range", "start boundary")
expect(try! capture("synthetic dated body 03-03-2026", nil) == "missing_date", "no fabricated date")
expect(try! capture("OTP 123456 do not share", start) == "sensitive", "sensitive exclusion")
expect(try! capture("", start) == "invalid", "empty body")
expect(try! capture("synthetic first", start) == "duplicates", "same run replay")
let report = try inbox.finish(text, found: 8)
expect(report["status"] as? String == "completed", "explicit finish")
let counts = report["counts"] as! [String: Int]
expect(counts["accepted"] == 2 && counts["missing_sender"] == 1 && counts["missing_date"] == 1, "truthful metadata counters")
let rows = inbox.snapshot()["records"] as! [[String: Any]]
expect(rows[0]["body"] as? String == "synthetic first" && rows[0]["sender"] as? String == "TEST-BANK", "first record association")
expect(rows[1]["body"] as? String == "synthetic last" && rows[1]["sender"] as? String == "", "second record association")
expect(HistoryRangeRequest.isoDate(rows[0]["receivedAt"] as! String) == start, "original date preserved")
let repeatRequest = request()
try inbox.register(repeatRequest); _ = try inbox.boundary(repeatRequest, end: false)
expect(try! inbox.capture(repeatRequest, body: "synthetic first", sender: "TEST-BANK", date: start, evidence: "handle") == "accepted", "new run gets its own matching source")
expect((try! inbox.finish(repeatRequest, found: 1))["status"] as? String == "completed", "repeat run finish")
inbox.acknowledge(rows.map { $0["id"] as! String })
expect((inbox.snapshot()["records"] as! [[String: Any]]).count == 1, "ack only consumed records")
let empty = request(); try inbox.register(empty); _ = try inbox.boundary(empty, end: false)
expect((try! inbox.finish(empty, found: 0))["status"] as? String == "completed", "zero matches completes")
let mismatch = request(); try inbox.register(mismatch); _ = try inbox.boundary(mismatch, end: false)
expect((try! inbox.finish(mismatch, found: 3))["status"] as? String == "incomplete_handoff", "missing actions never claim complete")
let waiting = request(); try inbox.register(waiting)
expect((inbox.snapshot()["runs"] as! [[String: Any]]).last!["status"] as? String == "waiting_for_shortcut", "URL launch is not completion")
let newer = request(); try inbox.register(newer)
do { _ = try inbox.boundary(waiting, end: false); fatalError("stale run accepted") } catch HistoryRangeError.unknownRun {}
let bounded = DeviceHistoryRangeInbox(limit: 1); let small = request(); try bounded.register(small); _ = try bounded.boundary(small, end: false)
_ = try bounded.capture(small, body: "one", sender: "TEST", date: start, evidence: "text")
expect(try! bounded.capture(small, body: "two", sender: "TEST", date: start, evidence: "text") == "limit_reached", "explicit capacity rejection")
expect(HistoryRangeRequest.isoDate("2026-09-30T10:00:00") == nil, "unzoned timestamp not verified")
print("PASS: native range boundaries, record association, metadata, repeats, completion, interruption, capacity, acknowledgement")
