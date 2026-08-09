// UA-8.2: iOS WidgetKit extension. Now a real Xcode target
// (HomeWidgetExtension, added via the xcodeproj gem — see
// ios/add_widget_extension_target.rb, run once to generate the
// project.pbxproj changes; safe to re-run, it no-ops if the target already
// exists) — Runner embeds it (Embed Foundation Extensions build phase),
// both targets share the `group.app.pandapay.pandapay.homewidget` App
// Group via their respective .entitlements files, and
// HomeWidgetService.setAppGroupId is called from the Dart side (see
// home_widget_service.dart) so `home_widget`'s saveWidgetData actually
// lands in the UserDefaults suite this file reads from.
//
// Reads the same `best_card_name` / `best_card_value_formatted` /
// `best_card_none` keys BestCardWidgetProvider.kt reads on Android — same
// data contract, two platforms, written once from home_widget_service.dart.
//
// Still unverified: whether this actually renders on a real device/
// simulator home screen (no way to install/run a widget on this
// environment's build target), and code signing for a real distribution
// build (needs a real Apple Developer Team ID, App Group capability
// enabled on developer.apple.com, and a provisioning profile covering
// both bundle ids — none of which can be set up from source alone).
// `xcodebuild -list` confirming the target exists and a
// `-showBuildSettings`/build-for-simulator pass are as far as this
// environment can verify.

import WidgetKit
import SwiftUI

private let appGroupId = "group.app.pandapay.pandapay.homewidget"

struct BestCardEntry: TimelineEntry {
    let date: Date
    let cardName: String
    let cardValue: String
    let noCard: Bool
}

struct BestCardProvider: TimelineProvider {
    func placeholder(in context: Context) -> BestCardEntry {
        BestCardEntry(date: Date(), cardName: "PandaPay", cardValue: "", noCard: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (BestCardEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BestCardEntry>) -> Void) {
        let entry = readEntry()
        // No background refresh scheduling is set up (matches the app-side
        // "no WorkManager/BGTaskScheduler job" gap noted in
        // widget_settings_screen.dart) — `.never` means this entry only
        // changes when the app itself calls `HomeWidget.updateWidget()`.
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func readEntry() -> BestCardEntry {
        let defaults = UserDefaults(suiteName: appGroupId)
        let noCard = defaults?.bool(forKey: "best_card_none") ?? true
        let name = defaults?.string(forKey: "best_card_name") ?? ""
        let value = defaults?.string(forKey: "best_card_value_formatted") ?? ""
        return BestCardEntry(date: Date(), cardName: name, cardValue: value, noCard: noCard)
    }
}

struct BestCardWidgetView: View {
    var entry: BestCardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Best card right now")
                .font(.caption2)
                .foregroundColor(.gray)
            if entry.noCard {
                Text("No card yet")
                    .font(.headline)
            } else {
                Text(entry.cardName)
                    .font(.headline)
                Text(entry.cardValue)
                    .font(.subheadline)
            }
        }
        .padding()
    }
}

struct BestCardWidget: Widget {
    let kind: String = "PandaPayBestCardWidget" // must match HomeWidgetService.iosWidgetName

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BestCardProvider()) { entry in
            BestCardWidgetView(entry: entry)
        }
        .configurationDisplayName("PandaPay: Best Card")
        .description("Shows the single best card to use right now.")
        .supportedFamilies([.systemSmall])
    }
}
