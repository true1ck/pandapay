import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

/// H8 — Legal. Signed-out-safe by spec (see plan §5: "H7 Help, H8 Legal —
/// both must render without auth"), so this screen has zero provider reads,
/// zero network calls, and is reachable via a plain Navigator.push from
/// anywhere (including before sign-in) exactly like G4 Emergency Card Info.
///
/// The hosted and in-app privacy text are maintained together from source
/// behavior. Owner/legal/store review remains a separate launch requirement.
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
        title: Text(
          'Legal',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
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
            'You are responsible for keeping your sign-in access secure. A '
            'PandaPay account is required to use the app so your cards, '
            'transactions, and insights remain tied to your account.\n\n'
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
          const _BodyText('Last updated: 26 October 2026', muted: true),
          const SizedBox(height: AppSpace.sm),
          const _BodyText(
            'This Privacy Policy describes what data PandaPay collects, why, and '
            'what you can do about it. We are committed to collecting only what the '
            'app actually needs to function.\n\n'
            '1. Account data\n'
            'If you create an account, we retain the account identifiers needed for '
            'email or phone sign-in and supported Google sign-in. We do not sell this '
            'data. Account data is stored on our servers with access controls, and '
            'traffic between the app and our servers uses HTTPS/TLS.\n\n'
            '2. Card and transaction data\n'
            'We do not ask you to save your full card number, PIN or CVV. Card or '
            'account last-four digits may be stored to match the cards and '
            'transactions you choose to add. Your card products and transactions are '
            'scoped to your account and used to estimate rewards and track spending, '
            'balances and caps.\n\n'
            '3. How you can add transactions\n'
            'You can add transactions manually or import statement and backup files '
            'you choose. On supported Android devices, enabling SMS import and '
            'granting permission lets the app read existing and incoming messages for '
            'financial parsing; unrelated personal messages are not intended for '
            'upload. Depending on the feature you use, financial message content or '
            'derived records can be sent to our backend for processing. If enabled '
            'and configured, server-assisted AI processing can send redacted '
            'financial message content to the configured AI provider. Optional '
            'shared-learning contributions use a separate opt-in. You can also '
            'forward transaction emails or connect IMAP for automatic import. Receipt '
            'images and unsynced records may exist only on your phone. If encrypted '
            'account recovery is available and you enable it, the app can upload '
            'encrypted recovery copies, including receipts when you select them, and '
            'update them automatically while connectivity and app activity permit. '
            'Recovery uses your existing account verification and adds no separate '
            'password. Work created after the last successful copy remains at risk if '
            'the phone is lost before another copy completes.\n\n'
            '4. Location\n'
            'If you grant location access, your precise location may be sent to the '
            'PandaPay API for nearby searches or enabled background alerts. The API '
            'can forward search coordinates to Google Places or OpenStreetMap-based '
            'providers, depending on the configured route. This feature is optional. '
            'Stored merchant location coordinates are rounded to roughly 11 metres; '
            'that rounding does not describe the precision sent for a nearby search.\n\n'
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
            '9. Data access choices\n'
            'We do not read your contacts or call log. Access to selected receipt '
            'images, statement files and backups is used for the import or recovery '
            'actions you choose. You can control optional Android SMS access through '
            'device permissions and the import settings described above.\n\n'
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              leading: const Icon(Icons.code_rounded, color: BambooInk.ink900),
              title: Text(
                'View open-source licences',
                style: BambooFonts.ui(
                  14.5,
                  weight: FontWeight.w600,
                  color: BambooInk.ink900,
                ),
              ),
              subtitle: Text(
                'Every package this app depends on, and its licence',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: BambooInk.ink300,
              ),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'PandaPay',
              ),
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
