#if !PANDAPAY_DEVICE_IMPORT_PROBE
import Foundation
import UIKit
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

  /// Starts the Lock Screen progress for a range the app just launched.
  static func start() { ensure() }

  /// Makes sure an import in progress has a visible Live Activity, the way
  /// delivery and upload apps do: if the person swiped it away, or it ended,
  /// a new one is created the next time PandaPay is in the foreground; an
  /// existing one is updated with the latest counts. iOS only allows creating
  /// one while the app is in the foreground, so call this from foreground
  /// moments (launching a range, becoming active, about to leave).
  static func ensure() {
    #if canImport(ActivityKit)
    guard #available(iOS 16.2, *) else { return }
    queue.async {
      guard let state = currentState(), liveStatuses.contains(state.status) else { return }
      Task { @MainActor in
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
        if let existing = visibleActivities().first {
          await existing.update(content)
        } else if !SmsImportBackgroundHost.continuedTaskRunning {
          // iOS shows its own progress while the continued task runs.
          _ = try? Activity.request(attributes: SmsImportActivityAttributes(), content: content)
        }
      }
    }
    #endif
  }

  private static let liveStatuses: Set<String> = ["importing", "processing", "paused"]

  #if canImport(ActivityKit)
  /// Activities the person can still see. A dismissed or ended one is never
  /// shown again, so updating it would change nothing on screen.
  @available(iOS 16.2, *)
  private static func visibleActivities() -> [Activity<SmsImportActivityAttributes>] {
    Activity<SmsImportActivityAttributes>.activities.filter {
      $0.activityState == .active || $0.activityState == .stale
    }
  }
  #endif

  static func refresh() {
    #if canImport(ActivityKit)
    guard #available(iOS 16.2, *) else { return }
    queue.async {
      let state = currentState()
      Task {
        for activity in Activity<SmsImportActivityAttributes>.activities {
          if let state, liveStatuses.contains(state.status) {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter)))
          } else {
            let final = state ?? .init(status: "complete", done: 0, total: 0, range: "")
            await activity.end(ActivityContent(state: final, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(15 * 60)))
          }
        }
        // Still importing but nothing on screen (swiped away, or this is a
        // new run): recreate it while PandaPay is in the foreground.
        if let state, liveStatuses.contains(state.status) {
          await MainActor.run {
            if UIApplication.shared.applicationState == .active { ensure() }
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
