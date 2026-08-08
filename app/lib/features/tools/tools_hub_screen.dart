import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
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
      appBar: AppBar(title: const Text('Tools & Travel')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(
            'Travel-aware ranking, multi-card planning, and the one screen in this app that always '
            'works with no sign-in and no signal.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.ink500),
          ),
          const SizedBox(height: AppSpace.lg),
          _ToolTile(
            icon: Icons.flight_takeoff_rounded,
            title: 'Travel Mode',
            subtitle: 'Re-rank cards by forex markup, lounge access abroad, travel insurance',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TravelModeScreen())),
          ),
          const SizedBox(height: AppSpace.md),
          _ToolTile(
            icon: Icons.call_split_rounded,
            title: 'Multi-Card Split Planner',
            subtitle: 'Divide a big purchase across your cards for maximum rewards',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SplitPlannerScreen())),
          ),
          const SizedBox(height: AppSpace.md),
          _ToolTile(
            icon: Icons.calculate_outlined,
            title: 'EMI Advisor',
            subtitle: 'See the real cost of converting a purchase to EMI',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EmiAdvisorScreen())),
          ),
          const SizedBox(height: AppSpace.md),
          _ToolTile(
            icon: Icons.emergency_outlined,
            title: 'Emergency Card Info',
            subtitle: 'Lost-card hotlines — works offline and without signing in',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EmergencyCardInfoScreen())),
          ),
        ],
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
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppRadius.md), border: Border.all(color: AppColors.ink100)),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(color: AppColors.surfaceMuted, shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: AppColors.navy800),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.ink300),
            ],
          ),
        ),
      ),
    );
  }
}
