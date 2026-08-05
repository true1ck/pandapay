// UA-8.2 (Chunk 32): iOS WidgetKit skeleton source — deliberately NOT wired
// into an Xcode target. Unlike Android's `<receiver>` (a plain manifest
// entry this session could safely hand-edit and reason about), a real
// WidgetKit extension needs a *second Xcode target* — a new
// `.pbxproj` entry, an App Group entitlement shared with the main
// Runner target, a widget bundle Info.plist, and code-signing — all
// created and wired through Xcode itself, not safely hand-edited into a
// binary-ish `.pbxproj` file blind, without Xcode/a Mac build toolchain
// to actually open the project and verify nothing broke. That's the real
// reason this file sits outside any build target: hand-editing a pbxproj
// without being able to open/build the project risks silently corrupting
// the whole iOS build for a feature nobody can verify anyway in this
// sandbox. See PROGRESS.md for the explicit callout.
//
// What IS true and intentional: this shows the actual shape a real
// extension's TimelineProvider/View would take, reading the same
// `best_card_name` / `best_card_value_formatted` / `best_card_none` keys
// (via the same App Group `UserDefaults(suiteName:)` `home_widget`'s Dart
// side already writes to through `HomeWidget.saveWidgetData`) that
// BestCardWidgetProvider.kt reads on Android — same data contract, two
// platforms, written once from home_widget_service.dart.
//
// To actually finish this: open Runner.xcworkspace in Xcode, File > New >
// Target > Widget Extension, name it "HomeWidgetExtension", add this file
// (and drop the boilerplate Xcode generates), enable the same App Group
// capability on both the Runner and HomeWidgetExtension targets, and call
// `HomeWidget.setAppGroupId(...)` from the Dart side (not yet called
// anywhere in home_widget_service.dart — another explicit gap, since there
// is no App Group id to set until the Xcode target exists).

import WidgetKit
import SwiftUI

private let appGroupId = "group.app.pandapay.pandapay.homewidget" // not yet created in Xcode

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
