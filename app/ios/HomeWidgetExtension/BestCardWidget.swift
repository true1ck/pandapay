import WidgetKit
import SwiftUI
import UIKit

private let appGroupId = "group.app.pandapay.pandapay.homewidget"

/// How long one card pick stays up. Must match `widgetPickRotation` in
/// home_widget_service.dart so the picture drawn by the app and the card the
/// widget shows are the same one at the moment the app writes them.
private let pickRotation: TimeInterval = 20 * 60

// MARK: - Data

struct CardPick: Hashable {
    let caption: String   // "Best for Dining" / "Best near Starbucks"
    let name: String
    let value: String
    let reason: String
    let art: String
}

struct CategoryShare: Hashable {
    let label: String
    let value: String
    let share: Double
    let color: Color
}

struct WidgetData {
    var brandMarkPath = ""
    var compactDetailsPath = ""
    var spendingCompactDetailsPath = ""
    var expandedMediumDetailsPath = ""
    var expandedLargeDetailsPath = ""
    var spendingMediumDetailsPath = ""
    var spendingLargeDetailsPath = ""
    var spendTotal = "₹0"
    var spendPeriod = "This month"
    var rewards = "₹0"
    var updatedAt = ""
    var categories: [CategoryShare] = []
    var picks: [CardPick] = []
    var single: CardPick? = nil
}

struct PandaPayEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
    let pick: CardPick?
}

private func readData() -> WidgetData {
    let defaults = UserDefaults(suiteName: appGroupId)
    func s(_ key: String) -> String { defaults?.string(forKey: key) ?? "" }
    var d = WidgetData()
    d.brandMarkPath = s("widget_brand_mark_path")
    d.compactDetailsPath = s("compact_details_path")
    d.spendingCompactDetailsPath = s("spending_compact_details_path")
    d.expandedMediumDetailsPath = s("expanded_medium_details_path")
    d.expandedLargeDetailsPath = s("expanded_large_details_path")
    d.spendingMediumDetailsPath = s("spending_medium_details_path")
    d.spendingLargeDetailsPath = s("spending_large_details_path")
    let total = s("spend_total_formatted")
    d.spendTotal = total.isEmpty ? "₹0" : total
    let period = s("spend_period_label")
    d.spendPeriod = period.isEmpty ? "This month" : period
    let rewards = s("spend_rewards_formatted")
    d.rewards = rewards.isEmpty ? "₹0" : rewards
    d.updatedAt = s("best_card_updated_at")

    if let raw = defaults?.string(forKey: "spend_categories_json"),
       let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
        d.categories = list.compactMap { row in
            guard let label = row["label"] as? String else { return nil }
            let rgb = (row["color"] as? NSNumber)?.intValue ?? 0x889988
            return CategoryShare(
                label: label,
                value: row["value"] as? String ?? "",
                share: (row["share"] as? NSNumber)?.doubleValue ?? 0,
                color: Color(
                    red: Double((rgb >> 16) & 0xFF) / 255,
                    green: Double((rgb >> 8) & 0xFF) / 255,
                    blue: Double(rgb & 0xFF) / 255
                )
            )
        }
    }
    if let raw = defaults?.string(forKey: "card_picks_json"),
       let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] {
        d.picks = list.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return CardPick(
                caption: row["caption"] as? String ?? "",
                name: name,
                value: row["value"] as? String ?? "",
                reason: row["reason"] as? String ?? "",
                art: row["art"] as? String ?? ""
            )
        }
    }
    let none = defaults?.bool(forKey: "best_card_none") ?? true
    if !none, !s("best_card_name").isEmpty {
        d.single = CardPick(
            caption: s("best_card_caption"),
            name: s("best_card_name"),
            value: s("best_card_value_formatted"),
            reason: s("best_card_reason"),
            art: s("best_card_art_path")
        )
    }
    return d
}

private func pick(from data: WidgetData, bucket: Int) -> CardPick? {
    if data.picks.isEmpty { return data.single }
    return data.picks[((bucket % data.picks.count) + data.picks.count) % data.picks.count]
}

// MARK: - Timeline

struct PandaPayProvider: TimelineProvider {
    func placeholder(in context: Context) -> PandaPayEntry {
        var d = WidgetData()
        d.spendTotal = "₹12.4K"
        d.rewards = "₹86"
        d.updatedAt = "sample"
        d.categories = [
            CategoryShare(label: "Dining", value: "₹4.8K", share: 0.39, color: Color(red: 0.93, green: 0.42, blue: 0.35)),
            CategoryShare(label: "Groceries", value: "₹3.1K", share: 0.25, color: Color(red: 0.07, green: 0.62, blue: 0.47)),
            CategoryShare(label: "Fuel", value: "₹2.2K", share: 0.18, color: Color(red: 0.91, green: 0.62, blue: 0.16)),
            CategoryShare(label: "Shopping", value: "₹1.5K", share: 0.12, color: Color(red: 0.51, green: 0.40, blue: 0.80)),
        ]
        let sample = CardPick(caption: "Best for Dining", name: "Your best card", value: "₹50", reason: "5% back", art: "")
        d.single = sample
        return PandaPayEntry(date: Date(), data: d, pick: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (PandaPayEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let data = readData()
        let bucket = Int(Date().timeIntervalSince1970 / pickRotation)
        completion(PandaPayEntry(date: Date(), data: data, pick: pick(from: data, bucket: bucket)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PandaPayEntry>) -> Void) {
        let data = readData()
        let now = Date()
        let bucket = Int(now.timeIntervalSince1970 / pickRotation)
        // One entry per upcoming rotation slot, so the card pick changes by
        // itself even while the app is closed.
        var entries = [PandaPayEntry(date: now, data: data, pick: pick(from: data, bucket: bucket))]
        if data.picks.count > 1 {
            for i in 1...min(data.picks.count * 2, 8) {
                let start = Date(timeIntervalSince1970: Double(bucket + i) * pickRotation)
                entries.append(PandaPayEntry(date: start, data: data, pick: pick(from: data, bucket: bucket + i)))
            }
            completion(Timeline(entries: entries, policy: .atEnd))
        } else {
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
        }
    }
}

// MARK: - Shared pieces

private enum WidgetPalette {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let ink = Color(red: 0.17, green: 0.19, blue: 0.23)
    static let muted = Color(red: 0.55, green: 0.56, blue: 0.58)
    static let jade = Color(red: 0.07, green: 0.50, blue: 0.36)
}

private func loadImage(_ paths: [String]) -> UIImage? {
    for path in paths where !path.isEmpty {
        if let image = UIImage(contentsOfFile: path) { return image }
    }
    return nil
}

private struct SharedImage: View {
    let path: String

    var body: some View {
        if !path.isEmpty, let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }
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

private struct DonutView: View {
    let categories: [CategoryShare]
    let total: String

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = side * 0.17
            ZStack {
                Circle().stroke(Color(red: 0.91, green: 0.93, blue: 0.92), lineWidth: line)
                ForEach(Array(arcs().enumerated()), id: \.offset) { _, arc in
                    Circle()
                        .trim(from: arc.start, to: arc.end)
                        .stroke(arc.color, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(total)
                        .font(.system(size: side * 0.19, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetPalette.ink)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("spent")
                        .font(.system(size: side * 0.11, weight: .medium, design: .rounded))
                        .foregroundStyle(WidgetPalette.muted)
                }
                .padding(line * 1.1)
            }
            .padding(line / 2)
            .frame(width: side, height: side)
        }
    }

    private func arcs() -> [(start: CGFloat, end: CGFloat, color: Color)] {
        var out: [(start: CGFloat, end: CGFloat, color: Color)] = []
        var cursor: CGFloat = 0
        for category in categories {
            let share = CGFloat(max(0, min(1, category.share)))
            let end = min(1, cursor + share)
            if end > cursor { out.append((start: cursor, end: end, color: category.color)) }
            cursor = end
        }
        return out
    }
}

// MARK: - Plain (picture-less) summary
//
// Drawn from the saved numbers alone, so a widget never shows an empty ring:
// either the real breakdown, or a clear "open the app" message before the app
// has ever written anything.

private struct NativeSummary: View {
    let entry: PandaPayEntry
    let family: WidgetFamily
    let showCard: Bool

    private var k: CGFloat {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 1.15
        default: return 1.5
        }
    }

    private var rowCount: Int {
        switch family {
        case .systemSmall: return 2
        case .systemMedium: return 4
        default: return 6
        }
    }

    var body: some View {
        if entry.data.updatedAt.isEmpty {
            VStack(spacing: 8) {
                WidgetBrandMark(path: entry.data.brandMarkPath)
                    .frame(width: 30 * k, height: 30 * k)
                Text("Open PandaPay to load your spending")
                    .font(.system(size: 12 * k, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.ink)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }

    private var content: some View {
        if family == .systemSmall { return AnyView(smallContent) }
        return AnyView(regularContent)
    }

    private var cardLines: some View {
        Group {
            if showCard, let pick = entry.pick {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pick.caption.isEmpty ? "BEST CARD" : pick.caption.uppercased())
                        .font(.system(size: 8.5 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetPalette.muted)
                        .lineLimit(1)
                    Text(pick.name)
                        .font(.system(size: 11.5 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text([pick.value, pick.reason].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetPalette.jade)
                        .lineLimit(1)
                }
            } else if !showCard {
                Text("\(entry.data.rewards) rewards")
                    .font(.system(size: 10.5 * k, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.jade)
                    .lineLimit(1)
            }
        }
    }

    /// 170 pt square: no room for a label and an amount side by side, so each
    /// category is a name over its amount.
    private var smallContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                WidgetBrandMark(path: entry.data.brandMarkPath)
                    .frame(width: 15, height: 15)
                Text(entry.data.spendPeriod.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 8) {
                DonutView(categories: entry.data.categories, total: entry.data.spendTotal)
                    .frame(width: 78, height: 78)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(entry.data.categories.prefix(2).enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 3) {
                                Circle().fill(c.color).frame(width: 6, height: 6)
                                Text(c.label)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(WidgetPalette.ink)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            Text(c.value)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(WidgetPalette.ink)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            cardLines
        }
        .padding(10)
    }

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: 6 * k) {
            HStack(spacing: 5) {
                WidgetBrandMark(path: entry.data.brandMarkPath)
                    .frame(width: 18 * k, height: 18 * k)
                Text(entry.data.spendPeriod.uppercased())
                    .font(.system(size: 9.5 * k, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(entry.data.rewards) rewards")
                    .font(.system(size: 9.5 * k, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.jade)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            HStack(alignment: .center, spacing: 10 * k) {
                DonutView(categories: entry.data.categories, total: entry.data.spendTotal)
                    .frame(width: family == .systemLarge ? 165 : 82 * k, height: family == .systemLarge ? 165 : 82 * k)
                VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 4 * k) {
                    ForEach(Array(entry.data.categories.prefix(rowCount).enumerated()), id: \.offset) { _, c in
                        HStack(spacing: 5) {
                            Circle().fill(c.color).frame(width: 7 * k, height: 7 * k)
                            Text(c.label)
                                .font(.system(size: 10.5 * k, weight: .medium, design: .rounded))
                                .foregroundStyle(WidgetPalette.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 2)
                            Text(c.value)
                                .font(.system(size: 10.5 * k, weight: .bold, design: .rounded))
                                .foregroundStyle(WidgetPalette.ink)
                                .lineLimit(1)
                        }
                    }
                    if entry.data.categories.isEmpty {
                        Text("No categories yet")
                            .font(.system(size: 11 * k, weight: .medium, design: .rounded))
                            .foregroundStyle(WidgetPalette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            cardLines
        }
        .padding(14)
    }
}

// MARK: - Widgets

private struct CombinedWidgetView: View {
    let entry: PandaPayEntry
    @Environment(\.widgetFamily) private var family

    private var paths: [String] {
        switch family {
        case .systemLarge: return [entry.data.expandedLargeDetailsPath]
        case .systemMedium: return [entry.data.expandedMediumDetailsPath]
        default: return [entry.data.compactDetailsPath]
        }
    }

    var body: some View {
        Group {
            if let image = loadImage(paths) {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
            } else {
                NativeSummary(entry: entry, family: family, showCard: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .widgetURL(URL(string: "pandapay://assistant/spending?period=month"))
    }
}

private struct SpendingWidgetView: View {
    let entry: PandaPayEntry
    @Environment(\.widgetFamily) private var family

    private var paths: [String] {
        switch family {
        case .systemLarge: return [entry.data.spendingLargeDetailsPath]
        case .systemMedium: return [entry.data.spendingMediumDetailsPath]
        default: return [entry.data.spendingCompactDetailsPath]
        }
    }

    var body: some View {
        Group {
            if let image = loadImage(paths) {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
            } else {
                NativeSummary(entry: entry, family: family, showCard: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .widgetURL(URL(string: "pandapay://assistant/spending?period=month"))
    }
}

private struct RecommendationWidgetView: View {
    let entry: PandaPayEntry
    @Environment(\.widgetFamily) private var family

    /// Type grows with the widget.
    private var k: CGFloat {
        switch family {
        case .systemSmall: return 1.0
        case .systemMedium: return 1.2
        default: return 1.5
        }
    }

    private var pick: CardPick? { entry.pick }
    private var waiting: Bool { entry.data.updatedAt.isEmpty }

    private var caption: String {
        if waiting { return "HOME PICK" }
        guard let pick = pick, !pick.caption.isEmpty else { return "HOME PICK" }
        return pick.caption.uppercased()
    }

    private var title: String {
        if waiting { return "Open PandaPay" }
        return pick?.name ?? "No card yet"
    }

    private var value: String {
        if waiting { return "to see your best card" }
        guard let pick = pick else { return "Add a card in PandaPay" }
        return [pick.value, pick.reason].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var art: some View {
        SharedImage(path: pick?.art ?? "")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 3 * k) {
            Text(title)
                .font(.system(size: 14 * k, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.system(size: 12 * k, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.jade)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            WidgetBrandMark(path: entry.data.brandMarkPath)
                .frame(width: 18 * k, height: 18 * k)
            Text(caption)
                .font(.system(size: 10 * k, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    var body: some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        header
                        art
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading) {
                        Spacer(minLength: 0)
                        texts
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 4 * k) {
                    header
                    art
                    texts
                }
            }
        }
        .padding(family == .systemSmall ? 10 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "pandapay://assistant/best-card"))
    }
}

struct PandaPayCombinedWidget: Widget {
    let kind = "PandaPayCombinedWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PandaPayProvider()) { entry in
            CombinedWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.white }
        }
        .configurationDisplayName("PandaPay: Spending + Card")
        .description("This month's category pie and your best card pick.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct PandaPaySpendingWidget: Widget {
    let kind = "PandaPaySpendingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PandaPayProvider()) { entry in
            SpendingWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.white }
        }
        .configurationDisplayName("PandaPay: Spending")
        .description("Your monthly spending pie, top category and rewards.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct BestCardWidget: Widget {
    let kind = "PandaPayBestCardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PandaPayProvider()) { entry in
            RecommendationWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetPalette.paper }
        }
        .configurationDisplayName("PandaPay: Card Pick")
        .description("The best card for what you spend on, changing through the day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
