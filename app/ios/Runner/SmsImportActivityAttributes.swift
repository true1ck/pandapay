import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared by the app (which starts and updates it) and the widget extension
/// (which draws it on the Lock Screen and Dynamic Island).
@available(iOS 16.1, *)
struct SmsImportActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// importing, processing, paused, complete or stopped
    var status: String
    var done: Int
    var total: Int
    /// The range being imported, e.g. "1 Jan – 31 Jan 2026".
    var range: String
    var received: Int? = nil
    var processed: Int? = nil
  }
}
#endif
