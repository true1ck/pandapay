import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../calculator/big_purchase_calculator_screen.dart';
import '../quickadd/quick_add_screen.dart';
import '../search/merchant_search_screen.dart';
import '../../app/design/widgets.dart';
import 'emergency_card_info_screen.dart';
import 'emi_advisor_screen.dart';
import 'split_planner_screen.dart';
import 'travel_mode_screen.dart';

/// ui-spec.md Group G — Tools & Modes hub. Same "hub-of-a-hub" pattern F1
/// Import Hub already established (implementation-plan-group-e-f-g.md's own
/// navigation finding): Account's Tools section hosts this one entry point,
/// and G1-G3 are reached from here via plain Navigator.push rather than a
/// second tier of registered go_router routes.
///
/// G4 Emergency Card Info is the one exception — it's ALSO registered as a
/// standalone top-level go_router route (AppRoute.emergencyCardInfo) so it
/// stays reachable without going through this hub (or being signed in) at
/// all, per its "zero login" requirement. The tile below still exists for
/// discoverability from inside the signed-in app.
class ToolsHubScreen extends StatelessWidget {
  const ToolsHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Tools & Travel', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              'Travel-aware ranking, multi-card planning, and the one screen in this app that always '
              'works with no sign-in and no signal.',
              style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.4),
            ),
            const SizedBox(height: AppSpace.lg),
            // These three used to be icon buttons in Home's header row.
            // Design 01 has no such row — the deck files every secondary
            // action under You → Tools (design 05), so they moved here
            // rather than being dropped.
            _ToolTile(
              icon: Icons.add_circle_outline_rounded,
              title: 'Quick add a spend',
              subtitle: 'Log a transaction you made without the app open',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QuickAddScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ToolTile(
              icon: Icons.search_rounded,
              title: 'Search merchants',
              subtitle: 'Look up a shop or brand and see which card wins there',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MerchantSearchScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ToolTile(
              icon: Icons.shopping_cart_checkout_rounded,
              title: 'Big-purchase calculator',
              subtitle: 'Work out the best card and split for a one-off large spend',
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const BigPurchaseCalculatorScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ToolTile(
              icon: Icons.flight_takeoff_rounded,
              title: 'Travel Mode',
              subtitle: 'Re-rank cards by forex markup, lounge access abroad, travel insurance',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TravelModeScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ToolTile(
              icon: Icons.call_split_rounded,
              title: 'Multi-Card Split Planner',
              subtitle: 'Divide a big purchase across your cards for maximum rewards',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SplitPlannerScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ToolTile(
              icon: Icons.calculate_outlined,
              title: 'EMI Advisor',
              subtitle: 'See the real cost of converting a purchase to EMI',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EmiAdvisorScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ToolTile(
              icon: Icons.emergency_outlined,
              title: 'Emergency Card Info',
              subtitle: 'Lost-card hotlines — works offline and without signing in',
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const EmergencyCardInfoScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ToolTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // See account_screen.dart's _AccountTile for why Pressable, not
    // Material+InkWell. The fill Material used to carry moves onto the
    // Container's own decoration, since there's no Material left to hold it.
    return Pressable(
      onTap: onTap,
      semanticLabel: '$title. $subtitle',
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(color: BambooInk.slate, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: BambooInk.lime),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20, color: BambooInk.ink300),
          ],
        ),
      ),
    );
  }
}
