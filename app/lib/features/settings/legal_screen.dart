import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

/// H8 — Legal. Signed-out-safe by spec (see plan §5: "H7 Help, H8 Legal —
/// both must render without auth"), so this screen has zero provider reads,
/// zero network calls, and is reachable via a plain Navigator.push from
/// anywhere (including before sign-in) exactly like G4 Emergency Card Info.
///
/// Copy provenance, section by section:
/// - Terms of Service / Privacy Policy: `product-plan.md` §8.4 only states
///   *what* these documents must cover (reward-data staleness, no
///   liability, crowdsource usage, anonymization guarantee) — it contains
///   no drafted legal text to copy verbatim. The bodies below are therefore
///   [Draft — pending legal review] placeholder copy written to satisfy
///   §8.4's coverage checklist, each visibly flagged with a "Draft" badge
///   next to its header so a real user is never shown unfinished legal
///   text as if it were final.
/// - Not-financial-advice disclaimer: `product-plan.md` §8.1 (⭐ REQUIRED)
///   — paraphrased into one clear paragraph per that section's own
///   required framing ("informational suggestions based on publicly
///   available reward terms", "not a regulated financial advisor",
///   "verify terms with their issuer"). This is exact required framing,
///   not draft copy, so it carries no Draft badge.
/// - ODbL attribution: exact required copy per the plan's DoD ("verify
///   wording against osm.org's own attribution guideline page"). This
///   repo's merchant data really is OSM-derived — `nearby_merchants_repository.dart`
///   fetches `GET /merchants/nearby`, backed by `merchants` rows carrying
///   `osm_matched`/`osm_ref` columns (db/supabase/migrations/0007_crowdsource.sql)
///   — so this is a real legal obligation, not decorative filler. Exact
///   required copy, not a draft, so it carries no Draft badge either.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Legal')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          const _SectionHeader(title: 'Terms of Service', showDraftBadge: true),
          const SizedBox(height: AppSpace.sm),
          const _BodyText(
            '[Draft — pending legal review]\n\n'
            'These Terms of Service govern your use of PandaPay. By using the app, '
            'you agree to the following:\n\n'
            '• Reward and card-benefit data shown in the app is sourced from public '
            'card issuer terms and community contributions, and may be inaccurate, '
            'incomplete, or out of date at any time. Always confirm reward terms '
            'directly with your card issuer before relying on them.\n\n'
            '• PandaPay is a personal-finance information tool, not a party to any '
            'transaction between you and your card issuer, merchant, or bank, and '
            'accepts no liability for financial decisions made using the app.\n\n'
            '• Crowdsourced contributions (e.g. merchant category corrections) you '
            'submit may be used, in anonymized form, to improve recommendations for '
            'all users.\n\n'
            '• You may delete your account at any time; see the Account section for '
            'how deletion works.\n\n'
            'This placeholder will be replaced with reviewed, final Terms of Service '
            'before general release.',
          ),
          const SizedBox(height: AppSpace.xl),
          const _SectionHeader(title: 'Privacy Policy', showDraftBadge: true),
          const SizedBox(height: AppSpace.sm),
          const _BodyText(
            '[Draft — pending legal review]\n\n'
            'This Privacy Policy describes what data PandaPay collects and how it is '
            'used:\n\n'
            '• Account data (email, phone) is used to authenticate you and is never '
            'sold to third parties.\n\n'
            '• Card and transaction data you add is used to power recommendations and '
            'is stored securely, scoped to your account.\n\n'
            '• Crowdsourced merchant contributions are anonymized before they are '
            'used to improve recommendations for other users — your identity is never '
            'linked back to a contribution once submitted.\n\n'
            '• You may request export or deletion of your data at any time from '
            'Settings.\n\n'
            'This placeholder will be replaced with a reviewed, final Privacy Policy '
            'before general release.',
          ),
          const SizedBox(height: AppSpace.xl),
          const _SectionHeader(title: 'Not financial advice'),
          const SizedBox(height: AppSpace.sm),
          const _BodyText(
            'PandaPay estimates rewards and surfaces informational suggestions based '
            'on publicly available card and reward terms. It is not a regulated '
            'financial advisor and never provides personalized financial or '
            'investment advice. Always verify reward terms with your card issuer, '
            'and consult a licensed financial advisor before making real financial '
            'decisions.',
          ),
          const SizedBox(height: AppSpace.xl),
          const _SectionHeader(title: 'Open-source licences'),
          const SizedBox(height: AppSpace.sm),
          Card(
            elevation: 0,
            color: AppColors.surfaceMuted,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
              leading: const Icon(Icons.code_rounded, color: AppColors.ink700),
              title: const Text('View open-source licences'),
              subtitle: const Text('Every package this app depends on, and its licence'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showLicensePage(context: context, applicationName: 'PandaPay'),
            ),
          ),
          const SizedBox(height: AppSpace.xl),
          const _SectionHeader(title: 'Map data attribution'),
          const SizedBox(height: AppSpace.sm),
          const _BodyText(
            'Merchant location data includes information © OpenStreetMap contributors, '
            'available under the Open Database License (ODbL).',
          ),
          const SizedBox(height: AppSpace.xl),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final bool showDraftBadge;

  const _SectionHeader({required this.title, this.showDraftBadge = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        if (showDraftBadge) ...[
          const SizedBox(width: AppSpace.sm),
          const _DraftBadge(),
        ],
      ],
    );
  }
}

/// Visible "Draft" chip — the plan's product-honesty requirement that a
/// real user is never shown unfinished legal text as though it were final.
/// Deliberately styled with the warning palette (not error, not neutral):
/// this isn't broken, it's incomplete, and warning tokens read as
/// "needs attention" without alarming a user mid-signup.
class _DraftBadge extends StatelessWidget {
  const _DraftBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Text(
        'Draft',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.warning,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _BodyText extends StatelessWidget {
  final String text;
  const _BodyText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.ink700, height: 1.5),
    );
  }
}
