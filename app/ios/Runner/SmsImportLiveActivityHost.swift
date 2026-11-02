#if !PANDAPAY_DEVICE_IMPORT_PROBE
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Lock Screen and Dynamic Island progress for a history import. It starts
/// when PandaPay launches an import (iOS only allows starting one from the
/// foreground) and is updated by the Shortcut actions as each range finishes,
/// even while PandaPay is closed. It ends when the import completes or stops.
enum SmsImportLiveActivityHost {
  private static let queue = DispatchQueue(label: "app.pandapay.sms-live-activity", qos: .utility)
  /// Without an update for this long, iOS greys the activity out and the
  /// view asks the person to open PandaPay.
  private static let staleAfter: TimeInterval = 10 * 60

  static func start() {
    #if canImport(ActivityKit)
    guard #available(iOS 16.2, *) else { return }
    queue.async {
      guard let state = currentState(), state.status == "importing" else { return }
      Task { @MainActor in
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
        if let existing = Activity<SmsImportActivityAttributes>.activities.first {
          await existing.update(content)
        } else {
          _ = try? Activity.request(attributes: SmsImportActivityAttributes(), content: content)
        }
      }
    }
    #endif
  }

  static func refresh() {
    #if canImport(ActivityKit)
    guard #available(iOS 16.2, *) else { return }
    queue.async {
      let state = currentState()
      Task {
        for activity in Activity<SmsImportActivityAttributes>.activities {
          if let state, ["importing", "processing", "paused"].contains(state.status) {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter)))
          } else {
            let final = state ?? .init(status: "complete", done: 0, total: 0, range: "")
            await activity.end(ActivityContent(state: final, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(15 * 60)))
          }
        }
      }
    }
    #endif
  }

  #if canImport(ActivityKit)
  @available(iOS 16.2, *)
  private static func currentState() -> SmsImportActivityAttributes.ContentState? {
    guard let progress = try? IncomingSmsSpool.shared.importProgress(),
          let status = progress["state"] as? String, status != "none" else { return nil }
    return .init(status: status,
                 done: progress["done"] as? Int ?? 0,
                 total: progress["total"] as? Int ?? 0,
                 range: rangeLabel(start: progress["start"] as? String, end: progress["end"] as? String),
                 received: progress["received"] as? Int,
                 processed: progress["processed"] as? Int)
  }
  #endif

  private static func rangeLabel(start: String?, end: String?) -> String {
    guard let start, let from = IncomingSmsSpool.date(start) else { return "" }
    let day = DateFormatter(), dayYear = DateFormatter()
    day.dateFormat = "d MMM"; dayYear.dateFormat = "d MMM yyyy"
    // The end is exclusive: show the last moment inside the range.
    guard let end, let to = IncomingSmsSpool.date(end)?.addingTimeInterval(-0.001), to > from else {
      return dayYear.string(from: from)
    }
    return "\(day.string(from: from)) – \(dayYear.string(from: to))"
  }
}
#endif
