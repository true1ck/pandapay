// Explicit exports from the disposable probe, never the main application.
import Foundation
import CryptoKit

enum ProbeExportError: Error, Equatable { case invalidReport, oversized, wrongBundle }

enum ProbeDiagnosticsExport {
  static let maxBytes = 32 * 1024 * 1024

  static func write(_ json: String, metadata: [String: Any],
                    directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("PandaPayProbeExports"),
                    now: Date = Date()) throws -> URL {
    guard metadata["bundle_id"] as? String == "app.pandapay.iosimportprobe" else {
      throw ProbeExportError.wrongBundle
    }
    guard let input = json.data(using: .utf8), input.count <= maxBytes else {
      throw ProbeExportError.oversized
    }
    guard var report = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          report["format"] as? String == "pandapay.sender_probe_diagnostics",
          report["schema_version"] as? Int == 1 else { throw ProbeExportError.invalidReport }
    report["native_app"] = metadata
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    guard data.count <= maxBytes else { throw ProbeExportError.oversized }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Clean abandoned share files from prior sessions, but not active exports.
    for file in (try? FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      if file.lastPathComponent.hasPrefix("PandaPay-Sender-Probe-"),
         let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
         now.timeIntervalSince(modified) > 86400 { try? FileManager.default.removeItem(at: file) }
    }
    let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
    let file = directory.appendingPathComponent("PandaPay-Sender-Probe-\(stamp)-\(UUID().uuidString.prefix(8)).json")
    try data.write(to: file, options: .atomic)
    return file
  }

  static func remove(_ file: URL) { try? FileManager.default.removeItem(at: file) }

  private static var replayDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }
  static func readReplay(directory: URL? = nil) throws -> [String: String]? {
    let file = (directory ?? replayDirectory).appendingPathComponent("SenderProbeReplay.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maxBytes else { throw ProbeExportError.oversized }
    let data = try Data(contentsOf: file)
    guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { throw ProbeExportError.invalidReport }
    return ["json": text, "fingerprint": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
  }
  static func completeReplay(_ fingerprint: String, counts: [String: Int], directory: URL? = nil) throws {
    let directory = directory ?? replayDirectory
    guard try readReplay(directory: directory)?["fingerprint"] == fingerprint else { throw ProbeExportError.invalidReport }
    let summary: [String: Any] = ["counts": counts, "source_fingerprint": fingerprint,
      "completed_at": ISO8601DateFormatter().string(from: Date())]
    try JSONSerialization.data(withJSONObject: summary).write(
      to: directory.appendingPathComponent("SenderProbeReplaySummary.json"), options: .atomic)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("SenderProbeReplay.json"))
  }
  static func clearReplay() {
    remove(replayDirectory.appendingPathComponent("SenderProbeReplay.json"))
    remove(replayDirectory.appendingPathComponent("SenderProbeReplaySummary.json"))
  }
}
