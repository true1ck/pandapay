import WidgetKit
import SwiftUI

/// Entry point for the widget extension process — every WidgetKit
/// extension needs exactly one `@main WidgetBundle`; all three compact
/// PandaPay variants are exposed through this bundle.
@main
struct HomeWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        PandaPayCombinedWidget()
        PandaPaySpendingWidget()
        BestCardWidget()
    }
}
