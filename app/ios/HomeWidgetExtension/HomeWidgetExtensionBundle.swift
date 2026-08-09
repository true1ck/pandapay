import WidgetKit
import SwiftUI

/// Entry point for the widget extension process — every WidgetKit
/// extension needs exactly one `@main WidgetBundle`, even with a single
/// widget in it. Kept as its own file, separate from BestCardWidget.swift's
/// TimelineProvider/View/Widget definitions, so a second widget could be
/// added later by listing it here without touching the first widget's code.
@main
struct HomeWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        BestCardWidget()
    }
}
