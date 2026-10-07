import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';

/// One insight made of several closely-related views.
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
/// Grouping them here is not just tidying: the related views stay together.
/// Most groups use a tab bar; limits and perks can opt into one vertical
/// scroll so every section is visible without horizontal swiping.
///
/// The tab bodies are the ORIGINAL screens, unchanged. Each was already a
/// plain body widget that the router wrapped in a Scaffold, so nothing had
/// to be rewritten to sit here — which is also why the old routes still
/// work and still show the same content when reached directly.
class GroupedInsightScreen extends StatelessWidget {
  final String title;

  /// Short label + body per grouped section. Labels stay short deliberately
  /// because they are used both by the tab bar and the vertical section
  /// headings.
  final List<({String label, Widget body})> tabs;
  final bool verticalSections;
  final int initialIndex;

  const GroupedInsightScreen({
    super.key,
    required this.title,
    required this.tabs,
    this.verticalSections = false,
    this.initialIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final safeInitialIndex = initialIndex < 0
        ? 0
        : initialIndex >= tabs.length
        ? tabs.length - 1
        : initialIndex;
    return DefaultTabController(
      length: tabs.length,
      initialIndex: safeInitialIndex,
      child: Scaffold(
        backgroundColor: BambooInk.paper,
        appBar: AppBar(
          backgroundColor: BambooInk.paper,
          foregroundColor: BambooInk.ink900,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(
            title,
            style: BambooFonts.heading(17, color: BambooInk.ink900),
          ),
          bottom: verticalSections
              ? null
              : TabBar(
                  // Scrollable so a four-tab group doesn't squeeze its labels to
                  // the point of truncation on a narrow phone.
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelColor: BambooInk.slate,
                  unselectedLabelColor: BambooInk.ink500,
                  indicatorColor: BambooInk.slate,
                  labelStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                  unselectedLabelStyle: BambooFonts.ui(
                    13.5,
                    weight: FontWeight.w500,
                  ),
                  tabs: [for (final t in tabs) Tab(text: t.label)],
                ),
        ),
        body: AppBackground(
          child: verticalSections
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.lg,
                    AppSpace.lg,
                    AppSpace.xl,
                  ),
                  children: [
                    for (final t in tabs)
                      _VerticalInsightSection(label: t.label, body: t.body),
                  ],
                )
              : TabBarView(children: [for (final t in tabs) t.body]),
        ),
      ),
    );
  }
}

class _VerticalInsightSection extends StatelessWidget {
  final String label;
  final Widget body;

  const _VerticalInsightSection({required this.label, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpace.xs,
              bottom: AppSpace.sm,
            ),
            child: Text(
              label.toUpperCase(),
              style: BambooFonts.ui(
                12,
                weight: FontWeight.w700,
                color: BambooInk.ink500,
              ).copyWith(letterSpacing: 1),
            ),
          ),
          body,
        ],
      ),
    );
  }
}

/// A consistent per-card grouping used by the limits-and-perks tabs.
///
/// The data inside each tab is already card-specific, but showing every rule
/// as a flat list made it hard to answer the practical question: "what does
/// this card give me?" Keeping the card as the first-level section makes the
/// relationship explicit while leaving each tab free to render its own
/// capability rows underneath.
class CardCapabilitySection extends StatelessWidget {
  final String cardName;
  final String capabilityLabel;
  final int capabilityCount;
  final List<Widget> children;

  const CardCapabilitySection({
    super.key,
    required this.cardName,
    required this.capabilityLabel,
    required this.capabilityCount,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Material(
        color: Colors.transparent,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            // Keep each category card immediately useful: the first level
            // answers "which cards have this benefit?" while the expanded
            // default keeps the card's individual rules visible without an
            // extra tap. Users can still collapse a card to reduce clutter.
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.symmetric(
              horizontal: AppSpace.lg,
              vertical: AppSpace.xs,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              0,
              AppSpace.lg,
              AppSpace.sm,
            ),
            leading: const Icon(
              Icons.credit_card_rounded,
              color: BambooInk.slate,
            ),
            title: Text(
              cardName,
              style: BambooFonts.heading(15, color: BambooInk.ink900),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '$capabilityCount $capabilityLabel',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

class CardCapabilitySubheading extends StatelessWidget {
  final String label;

  const CardCapabilitySubheading(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label.toUpperCase(),
          style: BambooFonts.ui(
            11,
            weight: FontWeight.w700,
            color: BambooInk.ink500,
          ).copyWith(letterSpacing: 0.8),
        ),
      ),
    );
  }
}
