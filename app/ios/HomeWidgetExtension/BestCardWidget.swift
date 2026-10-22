import WidgetKit
import SwiftUI
import UIKit

private let appGroupId = "group.app.pandapay.pandapay.homewidget"

struct PandaPayEntry: TimelineEntry {
    let date: Date
    let spendChartPath: String
    let brandMarkPath: String
    let compactDetailsPath: String
    let spendingCompactDetailsPath: String
    let expandedDetailsPath: String
    let expandedPortraitDetailsPath: String
    let expandedWideDetailsPath: String
    let expandedMediumDetailsPath: String
    let expandedLargeDetailsPath: String
    let spendingDetailsPath: String
    let spendingPortraitDetailsPath: String
    let spendingWideDetailsPath: String
    let spendingMediumDetailsPath: String
    let spendingLargeDetailsPath: String
    let cardArtPath: String
    let spendTotal: String
    let spendPeriod: String
    let topCategory: String
    let topCategoryValue: String
    let rewards: String
    let cardName: String
    let cardValue: String
    let cardReason: String
    let noCard: Bool
}

struct PandaPayProvider: TimelineProvider {
    func placeholder(in context: Context) -> PandaPayEntry {
        PandaPayEntry(
            date: Date(),
            spendChartPath: "",
            brandMarkPath: "",
            compactDetailsPath: "",
            spendingCompactDetailsPath: "",
            expandedDetailsPath: "",
            expandedPortraitDetailsPath: "",
            expandedWideDetailsPath: "",
            expandedMediumDetailsPath: "",
            expandedLargeDetailsPath: "",
            spendingDetailsPath: "",
            spendingPortraitDetailsPath: "",
            spendingWideDetailsPath: "",
            spendingMediumDetailsPath: "",
            spendingLargeDetailsPath: "",
            cardArtPath: "",
            spendTotal: "₹0",
            spendPeriod: "This month",
            topCategory: "Add a transaction",
            topCategoryValue: "",
            rewards: "₹0",
            cardName: "Your best card",
            cardValue: "",
            cardReason: "Based on your Home selection",
            noCard: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PandaPayEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PandaPayEntry>) -> Void) {
        completion(Timeline(entries: [readEntry()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private func readEntry() -> PandaPayEntry {
        let defaults = UserDefaults(suiteName: appGroupId)
        return PandaPayEntry(
            date: Date(),
            spendChartPath: defaults?.string(forKey: "spend_chart_path") ?? "",
            brandMarkPath: defaults?.string(forKey: "widget_brand_mark_path") ?? "",
            compactDetailsPath: defaults?.string(forKey: "compact_details_path") ?? "",
            spendingCompactDetailsPath: defaults?.string(forKey: "spending_compact_details_path") ?? "",
            expandedDetailsPath: defaults?.string(forKey: "expanded_details_path") ?? "",
            expandedPortraitDetailsPath: defaults?.string(forKey: "expanded_portrait_details_path") ?? "",
            expandedWideDetailsPath: defaults?.string(forKey: "expanded_wide_details_path") ?? "",
            expandedMediumDetailsPath: defaults?.string(forKey: "expanded_medium_details_path") ?? "",
            expandedLargeDetailsPath: defaults?.string(forKey: "expanded_large_details_path") ?? "",
            spendingDetailsPath: defaults?.string(forKey: "spending_details_path") ?? "",
            spendingPortraitDetailsPath: defaults?.string(forKey: "spending_portrait_details_path") ?? "",
            spendingWideDetailsPath: defaults?.string(forKey: "spending_wide_details_path") ?? "",
            spendingMediumDetailsPath: defaults?.string(forKey: "spending_medium_details_path") ?? "",
            spendingLargeDetailsPath: defaults?.string(forKey: "spending_large_details_path") ?? "",
            cardArtPath: defaults?.string(forKey: "best_card_art_path") ?? "",
            spendTotal: defaults?.string(forKey: "spend_total_formatted") ?? "₹0",
            spendPeriod: defaults?.string(forKey: "spend_period_label") ?? "This month",
            topCategory: defaults?.string(forKey: "spend_top_category") ?? "",
            topCategoryValue: defaults?.string(forKey: "spend_top_category_value_formatted") ?? "",
            rewards: defaults?.string(forKey: "spend_rewards_formatted") ?? "₹0",
            cardName: defaults?.string(forKey: "best_card_name") ?? "",
            cardValue: defaults?.string(forKey: "best_card_value_formatted") ?? "",
            cardReason: defaults?.string(forKey: "best_card_reason") ?? "",
            noCard: defaults?.bool(forKey: "best_card_none") ?? true
        )
    }
}

private struct SharedImage: View {
    let path: String

    var body: some View {
        if !path.isEmpty, let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Circle()
                .stroke(Color(red: 0.91, green: 0.94, blue: 0.93), lineWidth: 12)
                .padding(8)
        }
    }
}

private enum WidgetPalette {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let ink = Color(red: 0.17, green: 0.19, blue: 0.23)
    static let muted = Color(red: 0.55, green: 0.56, blue: 0.58)
    static let jade = Color(red: 0.07, green: 0.50, blue: 0.36)
}

private struct WidgetBrandMark: View {
    let path: String

    var body: some View {
        if !path.isEmpty, let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "leaf.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(WidgetPalette.jade)
        }
    }
}

private struct CombinedWidgetView: View {
    let entry: PandaPayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemLarge {
                SharedImage(
                    path: entry.expandedLargeDetailsPath.isEmpty
                        ? (entry.expandedPortraitDetailsPath.isEmpty
                            ? entry.expandedDetailsPath
                            : entry.expandedPortraitDetailsPath)
                        : entry.expandedLargeDetailsPath
                )
                    .padding(5)
            } else if family == .systemMedium {
                SharedImage(
                    path: entry.expandedMediumDetailsPath.isEmpty
                        ? (entry.expandedWideDetailsPath.isEmpty
                            ? entry.expandedDetailsPath
                            : entry.expandedWideDetailsPath)
                        : entry.expandedMediumDetailsPath
                )
                    .padding(4)
            } else if !entry.compactDetailsPath.isEmpty {
                SharedImage(path: entry.compactDetailsPath)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        WidgetBrandMark(path: entry.brandMarkPath)
                            .frame(width: 16, height: 16)
                        Text(entry.spendPeriod.uppercased())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.muted)
                    HStack(spacing: 2) {
                        SharedImage(path: entry.spendChartPath)
                            .frame(width: 86, height: 86)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BEST PICK")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(WidgetPalette.muted)
                            Text(entry.noCard ? "Add a card" : entry.cardName)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(WidgetPalette.ink)
                                .lineLimit(3)
                                .minimumScaleFactor(0.75)
                            if !entry.noCard {
                                Text(entry.cardValue)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(WidgetPalette.jade)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(categorySummary(entry))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(WidgetPalette.muted)
                        .lineLimit(1)
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(WidgetPalette.paper)
        .widgetURL(URL(string: "pandapay:///insights/trends"))
    }
}

private struct SpendingWidgetView: View {
    let entry: PandaPayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemLarge {
                SharedImage(
                    path: entry.spendingLargeDetailsPath.isEmpty
                        ? (entry.spendingPortraitDetailsPath.isEmpty
                            ? entry.spendingDetailsPath
                            : entry.spendingPortraitDetailsPath)
                        : entry.spendingLargeDetailsPath
                )
                    .padding(5)
            } else if family == .systemMedium {
                SharedImage(
                    path: entry.spendingMediumDetailsPath.isEmpty
                        ? (entry.spendingWideDetailsPath.isEmpty
                            ? entry.spendingDetailsPath
                            : entry.spendingWideDetailsPath)
                        : entry.spendingMediumDetailsPath
                )
                    .padding(4)
            } else if !entry.spendingCompactDetailsPath.isEmpty {
                SharedImage(path: entry.spendingCompactDetailsPath)
            } else {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        WidgetBrandMark(path: entry.brandMarkPath)
                            .frame(width: 15, height: 15)
                        Text(entry.spendPeriod.uppercased())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.muted)
                    SharedImage(path: entry.spendChartPath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 4) {
                        Text(entry.topCategory.isEmpty ? "No categories yet" : entry.topCategory)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.topCategoryValue)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.ink)
                    Text("\(entry.rewards) rewards")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(WidgetPalette.jade)
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WidgetPalette.paper)
        .widgetURL(URL(string: "pandapay:///insights/trends"))
    }
}

private struct RecommendationWidgetView: View {
    let entry: PandaPayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                WidgetBrandMark(path: entry.brandMarkPath)
                    .frame(width: 16, height: 16)
                Text("HOME PICK")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.muted)
            }
            SharedImage(path: entry.cardArtPath)
                .frame(maxWidth: .infinity)
                .frame(height: 76)
            Text(entry.noCard ? "No card yet" : entry.cardName)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(1)
            Text(entry.noCard ? "Open PandaPay to see card picks" : entry.cardValue)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.jade)
                .lineLimit(1)
            Text(entry.cardReason.isEmpty ? "Recommended for your Home selection" : entry.cardReason)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(WidgetPalette.muted)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(WidgetPalette.paper)
        .widgetURL(URL(string: "pandapay:///home"))
    }
}

private func categorySummary(_ entry: PandaPayEntry) -> String {
    guard !entry.topCategory.isEmpty else { return "Tap pie for all categories" }
    return "\(entry.topCategory)  ·  \(entry.topCategoryValue)"
}

struct PandaPayCombinedWidget: Widget {
    let kind = "PandaPayCombinedWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PandaPayProvider()) { entry in
            CombinedWidgetView(entry: entry)
        }
        .configurationDisplayName("PandaPay: Spending + Card")
        .description("This month's category pie and your Home card pick.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PandaPaySpendingWidget: Widget {
    let kind = "PandaPaySpendingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PandaPayProvider()) { entry in
            SpendingWidgetView(entry: entry)
        }
        .configurationDisplayName("PandaPay: Spending")
        .description("Your monthly spending pie, top category and rewards.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct BestCardWidget: Widget {
    let kind = "PandaPayBestCardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PandaPayProvider()) { entry in
            RecommendationWidgetView(entry: entry)
        }
        .configurationDisplayName("PandaPay: Card Pick")
        .description("The card recommended by PandaPay Home.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
