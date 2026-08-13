import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

/// H8 — Legal. Signed-out-safe by spec (see plan §5: "H7 Help, H8 Legal —
/// both must render without auth"), so this screen has zero provider reads,
/// zero network calls, and is reachable via a plain Navigator.push from
/// anywhere (including before sign-in) exactly like G4 Emergency Card Info.
///
/// Copy provenance, section by section:
/// - Terms of Service / Privacy Policy: `product-plan.md` §8.4 states *what*
///   these documents must cover (reward-data staleness, no liability,
///   crowdsource usage, anonymization guarantee); the bodies below satisfy
///   that checklist with real, launch-ready text — no longer the earlier
///   "[Draft — pending legal review]" placeholder, replaced ahead of the
///   Play Store submission (a page telling Google's reviewers "this will be
///   replaced before general release" is a rejection risk in itself for a
///   financial app). Every data-handling claim here was checked against
///   actual app/API behavior, not written from assumption — see PROGRESS.md
///   for the verification pass. This is founder-drafted copy grounded in
///   real behavior, not a substitute for review by a lawyer familiar with
///   India's DPDP Act if that hasn't happened yet; update this screen (and
///   the hosted copy at https://api.pandapath.site/legal/) together if it
///   does.
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
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Legal', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          const _SectionHeader(title: 'Terms of Service'),
          const SizedBox(height: AppSpace.xs),
          const _BodyText('Last updated: 13 August 2026', muted: true),
          const SizedBox(height: AppSpace.sm),
          const _BodyText(
            'These Terms of Service govern your use of PandaPay ("the app", "we", '
            '"our"). By creating an account or using the app, you agree to the '
            'following:\n\n'
            '1. What PandaPay is\n'
            'PandaPay helps you decide which of your existing payment cards to use '
            'for a purchase, and tracks your own spend against each card\'s reward '
            'caps and milestones. We do not issue cards, extend credit, move money, '
            'or act as a payment processor. We are not a party to any transaction '
            'between you and your card issuer, merchant, or bank.\n\n'
            '2. Accuracy of reward and card data\n'
            'Reward rates, caps, fees, and benefit terms shown in the app are sourced '
            'from card issuers\' public terms and community contributions, and may be '
            'inaccurate, incomplete, or out of date at any time. Always confirm '
            'reward terms directly with your card issuer before relying on them for '
            'a real financial decision.\n\n'
            '3. No liability for financial decisions\n'
            'PandaPay provides informational estimates only. We accept no liability '
            'for financial outcomes, missed rewards, fees, or other consequences '
            'arising from decisions made using the app.\n\n'
            '4. Your account\n'
            'You are responsible for keeping your sign-in access secure. You may '
            'use the app without an account ("guest mode"); guest data is stored '
            'only on your device and is lost if the app is uninstalled or the '
            'device is reset — it cannot be recovered by us.\n\n'
            '5. Crowdsourced contributions\n'
            'Contributions you submit (e.g. confirming a merchant\'s card-acceptance '
            'or category) may be used, in anonymized form as described in the '
            'Privacy Policy below, to improve recommendations for all users. By '
            'submitting a contribution you grant us a perpetual, royalty-free '
            'licence to use the anonymized version of it for that purpose.\n\n'
            '6. Account deletion\n'
            'You may request account deletion at any time from Settings. See the '
            'Privacy Policy for exactly what is deleted and the timeline.\n\n'
            '7. Changes to these terms\n'
            'We may update these terms as the app changes. Material changes will be '
            'reflected here with an updated "Last updated" date; continued use of '
            'the app after a change constitutes acceptance.\n\n'
            '8. Contact\n'
            'Questions about these terms: panda.paths123@gmail.com.',
          ),
          const SizedBox(height: AppSpace.xl),
          const _SectionHeader(title: 'Privacy Policy'),
          const SizedBox(height: AppSpace.xs),
          const _BodyText('Last updated: 13 August 2026', muted: true),
          const SizedBox(height: AppSpace.sm),
          const _BodyText(
            'This Privacy Policy describes what data PandaPay collects, why, and '
            'what you can do about it. We are committed to collecting only what the '
            'app actually needs to function.\n\n'
            '1. Account data\n'
            'If you create an account, we collect your email address (used to sign '
            'in via a one-time code) and optionally a phone number. This data is '
            'never sold to third parties. Sensitive account fields are encrypted at '
            'rest, and all traffic between the app and our servers is encrypted in '
            'transit (HTTPS/TLS).\n\n'
            '2. Card and transaction data\n'
            'We never store your full card number, PIN, CVV, or expiry date — not '
            'even the last 4 digits. What we do store, scoped to your account: the '
            'card products you tell us you hold, and transactions you add manually, '
            'scan, or import (see below), used to estimate rewards and track caps.\n\n'
            '3. How you can add transactions\n'
            '• Manual entry, or scanning a card with your camera to identify it — '
            'card scanning happens entirely on your device; no photo is ever '
            'uploaded.\n'
            '• Importing a bank statement PDF, or an SMS backup file you export '
            'from another app — both are files you explicitly choose to import; '
            'we do not read your device\'s SMS messages or inbox automatically.\n'
            '• Forwarding transaction emails to a personal inbound address, or '
            'connecting an email account via IMAP for automatic import, if you '
            'choose to set that up.\n\n'
            '4. Location\n'
            'If you grant location access, your device\'s precise location is sent '
            'to our servers only to look up nearby merchants and suggest the best '
            'card — this is optional and only used while the feature is active. '
            'Merchant location data shown in the app (not your own location) is '
            'rounded to roughly 11 metres before it is ever stored or shared.\n\n'
            '5. Crowdsourced contributions\n'
            'Contributions (e.g. confirming a merchant accepts a card, or '
            'correcting a category) are stored without your name, email, account '
            'ID, or any other identifying field — enforced by an automated check '
            'that runs before every release and blocks deployment if it finds an '
            'identifying column. Merchant coordinates are rounded to ~11m, amounts '
            'are excluded entirely, and timestamps are stored to the day only, '
            'never the minute. Internally, contributions are linked across a single '
            'calendar month using a one-way hash that is rotated and discarded at '
            'the end of each month, so contributions from different months cannot '
            'be linked to each other or back to you.\n\n'
            '6. Notifications\n'
            'If you enable notifications, we store a device push token tied to '
            'your account to deliver reward alerts, due-date reminders, and cap '
            'warnings. It is deleted when you delete your account.\n\n'
            '7. Product analytics\n'
            'We collect basic in-app usage events (e.g. which screens are opened, '
            'whether an action succeeded) from a fixed, limited list of event '
            'types — never free-text input, transaction amounts, or card details. '
            'This stays on our own servers; it is not shared with third-party '
            'analytics companies.\n\n'
            '8. Card issuer "Apply" links\n'
            'Tapping "Apply" for a card sends you to the issuer\'s own site via a '
            'link containing a random reference code, not your personal '
            'information. We record that the click happened (to measure which '
            'recommendations are useful); the issuer does not receive your name, '
            'email, or any other account data from us.\n\n'
            '9. Data we never collect\n'
            'We do not read your contacts, call log, photos, or files (other than '
            'a statement/backup file you explicitly choose to import), and we do '
            'not access your device\'s SMS inbox automatically.\n\n'
            '10. Retention and deletion\n'
            'Your data is retained while your account is active. Requesting '
            'deletion from Settings starts a 30-day grace period (cancelable any '
            'time in that window, in case of accidental or unauthorized requests) '
            'after which your profile, cards, and transactions are permanently '
            'deleted from our live database. Encrypted backups are retained '
            'separately for disaster recovery and age out on their own schedule, '
            'so a small delay beyond the 30 days can occur before every backup '
            'copy is gone.\n\n'
            '11. Your rights\n'
            'You can export your data (transactions and cards, as JSON or CSV) or '
            'request deletion at any time from Settings. If you are in India, '
            'these rights are provided consistent with the Digital Personal Data '
            'Protection Act, 2023.\n\n'
            '12. Children\n'
            'PandaPay is not directed at, and should not be used by, anyone under '
            '18.\n\n'
            '13. Changes to this policy\n'
            'We may update this policy as the app changes. Material changes will '
            'be reflected here with an updated "Last updated" date.\n\n'
            '14. Contact\n'
            'Questions, data requests, or complaints: panda.paths123@gmail.com.',
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
            color: BambooInk.paperMuted,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
            ),
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              leading: const Icon(Icons.code_rounded, color: BambooInk.ink900),
              title: Text(
                'View open-source licences',
                style: BambooFonts.ui(14.5, weight: FontWeight.w600, color: BambooInk.ink900),
              ),
              subtitle: Text(
                'Every package this app depends on, and its licence',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, color: BambooInk.ink300),
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

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(title, style: BambooFonts.heading(16, color: BambooInk.ink900));
  }
}

class _BodyText extends StatelessWidget {
  final String text;
  final bool muted;
  const _BodyText(this.text, {this.muted = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: BambooFonts.ui(
        muted ? 11.5 : 13.5,
        color: muted ? BambooInk.ink300 : BambooInk.ink500,
        height: 1.5,
      ),
    );
  }
}
