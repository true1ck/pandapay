import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';

/// One insight made of several closely-related views, shown as tabs.
///
/// WHY THIS EXISTS
/// ---------------
/// The Insights hub had grown to EIGHTEEN tiles, and most of them answered
/// slices of the same four or five questions. "Caps & Limits", "Milestones"
/// and "Fee Waivers" are three screens for one idea — progress toward a
/// threshold on a card, with a deadline. "Savings Report", "Missed
/// Opportunities" and "Portfolio Audit" are three screens for another —
/// did this wallet actually pay off. Presenting them as eighteen equal
/// choices made the user do the grouping in their head, every time.
///
/// Grouping them here is not just tidying: a tab bar makes the relationship
/// between the views explicit and lets someone compare them in two taps
/// instead of navigating back to a grid in between.
///
/// The tab bodies are the ORIGINAL screens, unchanged. Each was already a
/// plain body widget that the router wrapped in a Scaffold, so nothing had
/// to be rewritten to sit here — which is also why the old routes still
/// work and still show the same content when reached directly.
class GroupedInsightScreen extends StatelessWidget {
  final String title;

  /// Short label + body per tab. Labels stay short deliberately: the tab
  /// bar is scrollable, but a row the user has to drag to discover is a row
  /// they will not discover.
  final List<({String label, Widget body})> tabs;

  const GroupedInsightScreen({super.key, required this.title, required this.tabs});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        backgroundColor: BambooInk.paper,
        appBar: AppBar(
          backgroundColor: BambooInk.paper,
          foregroundColor: BambooInk.ink900,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(title, style: BambooFonts.heading(17, color: BambooInk.ink900)),
          bottom: TabBar(
            // Scrollable so a four-tab group doesn't squeeze its labels to
            // the point of truncation on a narrow phone.
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: BambooInk.slate,
            unselectedLabelColor: BambooInk.ink500,
            indicatorColor: BambooInk.slate,
            labelStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
            unselectedLabelStyle: BambooFonts.ui(13.5, weight: FontWeight.w500),
            tabs: [for (final t in tabs) Tab(text: t.label)],
          ),
        ),
        body: AppBackground(
          child: TabBarView(children: [for (final t in tabs) t.body]),
        ),
      ),
    );
  }
}
