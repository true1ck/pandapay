import ActivityKit
import SwiftUI
import WidgetKit

/// "Importing your SMS" on the Lock Screen and in the Dynamic Island.
@available(iOS 16.2, *)
struct SmsImportLiveActivity: Widget {
  private static let slate = Color(red: 0.17, green: 0.18, blue: 0.22)
  private static let lime = Color(red: 0.82, green: 0.94, blue: 0.40)

  var body: some WidgetConfiguration {
    ActivityConfiguration(for: SmsImportActivityAttributes.self) { context in
      LockScreenView(state: context.state, stale: context.isStale)
        .activityBackgroundTint(Self.slate)
        .activitySystemActionForegroundColor(Self.lime)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "tray.and.arrow.down.fill").foregroundColor(Self.lime)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text("\(context.state.done)/\(context.state.total)")
            .font(.headline).foregroundColor(Self.lime)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            Text(Self.title(context.state, stale: context.isStale)).font(.subheadline)
            ProgressView(value: Double(context.state.done), total: Double(max(context.state.total, 1)))
              .tint(Self.lime)
          }
        }
      } compactLeading: {
        Image(systemName: "tray.and.arrow.down.fill").foregroundColor(Self.lime)
      } compactTrailing: {
        Text("\(context.state.done)/\(context.state.total)").foregroundColor(Self.lime)
      } minimal: {
        Image(systemName: "tray.and.arrow.down.fill").foregroundColor(Self.lime)
      }
    }
  }

  static func title(_ state: SmsImportActivityAttributes.ContentState, stale: Bool) -> String {
    switch state.status {
    case "complete": return "SMS import complete"
    case "stopped": return "SMS import stopped"
    case "paused": return "Import paused · open PandaPay to continue"
    default:
      if stale { return "Waiting · open PandaPay to continue" }
      return state.range.isEmpty ? "Importing your SMS" : "Importing \(state.range)"
    }
  }

  private struct LockScreenView: View {
    let state: SmsImportActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: "tray.and.arrow.down.fill").foregroundColor(SmsImportLiveActivity.lime)
          Text("PandaPay").font(.headline).foregroundColor(.white)
          Spacer()
          Text("\(state.done) of \(state.total) months")
            .font(.subheadline).foregroundColor(SmsImportLiveActivity.lime)
        }
        Text(SmsImportLiveActivity.title(state, stale: stale))
          .font(.subheadline).foregroundColor(.white.opacity(0.85)).lineLimit(1)
        ProgressView(value: Double(state.done), total: Double(max(state.total, 1)))
          .tint(SmsImportLiveActivity.lime)
      }
      .padding(16)
    }
  }
}
