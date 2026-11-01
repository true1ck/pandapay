import Foundation

func expect(_ value: @autoclosure () -> Bool, _ label: String) {
  if !value() { fatalError(label) }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let metadata: [String: Any] = ["bundle_id": "app.pandapay.iosimportprobe", "build": "7"]
let report: [String: Any] = ["format": "pandapay.sender_probe_diagnostics", "schema_version": 1,
  "native_app": ["bundle_id": "forged"], "capture_journal": ["records": [
    ["body": "Synthetic ₹25 café\nUnicode 🧾", "sender": "TESTBK-S"]]]]
let json = String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!
let first = try ProbeDiagnosticsExport.write(json, metadata: metadata, directory: directory)
let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as! [String: Any]
expect(first.pathExtension == "json", "single JSON artifact")
expect((decoded["native_app"] as! [String: Any])["build"] as? String == "7", "native build metadata is authoritative")
expect((decoded["native_app"] as! [String: Any])["bundle_id"] as? String == "app.pandapay.iosimportprobe", "cannot spoof app scope")
let record = ((decoded["capture_journal"] as! [String: Any])["records"] as! [[String: Any]]).first!
expect(record["body"] as? String == "Synthetic ₹25 café\nUnicode 🧾", "exact JSON text round-trip")
let second = try ProbeDiagnosticsExport.write(json, metadata: metadata, directory: directory)
expect(first != second, "exports cannot overwrite each other")
ProbeDiagnosticsExport.remove(first)
expect(!FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path), "share completion removes only its own temporary file")
do {
  _ = try ProbeDiagnosticsExport.write(json, metadata: ["bundle_id": "app.pandapay.pandapay"], directory: directory)
  fatalError("main app export was allowed")
} catch ProbeExportError.wrongBundle {}
do {
  _ = try ProbeDiagnosticsExport.write("{}", metadata: metadata, directory: directory)
  fatalError("unrecognized report accepted")
} catch ProbeExportError.invalidReport {}
do {
  _ = try ProbeDiagnosticsExport.write(String(repeating: "x", count: ProbeDiagnosticsExport.maxBytes + 1), metadata: metadata, directory: directory)
  fatalError("unbounded payload accepted")
} catch ProbeExportError.oversized {}
print("PASS: probe JSON file round-trip, real build metadata, isolation, file cleanup, size and schema guards")

// Only an explicitly staged local copy can be consumed; the original source
// and a replacement file with a different fingerprint must remain intact.
let replay = directory.appendingPathComponent("SenderProbeReplay.json")
let original = directory.appendingPathComponent("OriginalDiagnostic.json")
try Data(json.utf8).write(to: original)
let absentReplay = try ProbeDiagnosticsExport.readReplay(directory: directory)
expect(absentReplay == nil, "no replay unless staged")
try FileManager.default.copyItem(at: original, to: replay)
let staged = try ProbeDiagnosticsExport.readReplay(directory: directory)!
expect(staged["json"] == json, "exact local replay text")
expect(staged["fingerprint"]?.count == 64, "SHA256 replay acknowledgement fence")
try Data((json + "\n").utf8).write(to: replay)
do {
  try ProbeDiagnosticsExport.completeReplay(staged["fingerprint"]!, counts: ["input_records": 1], directory: directory)
  fatalError("stale replay acknowledgement consumed a different file")
} catch ProbeExportError.invalidReport {}
expect(FileManager.default.fileExists(atPath: replay.path), "replacement preserved")
let current = try ProbeDiagnosticsExport.readReplay(directory: directory)!
try ProbeDiagnosticsExport.completeReplay(current["fingerprint"]!, counts: ["input_records": 1], directory: directory)
expect(!FileManager.default.fileExists(atPath: replay.path), "only staged copy consumed")
let originalText = try String(contentsOf: original, encoding: .utf8)
expect(originalText == json, "original diagnostic unchanged")
let summaryData = try Data(contentsOf: directory.appendingPathComponent("SenderProbeReplaySummary.json"))
let summary = try JSONSerialization.jsonObject(with: summaryData) as! [String: Any]
expect((summary["counts"] as? [String: Int]) == ["input_records": 1], "aggregate replay summary")
expect(summary["json"] == nil && summary["message_body"] == nil, "summary contains no SMS bodies")
print("PASS: staged replay, fingerprint fencing, aggregate receipt and original-file preservation")
