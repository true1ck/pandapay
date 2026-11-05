import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import 'legal_text.dart';

/// H8 — Legal. Signed-out-safe by spec (see plan §5: "H7 Help, H8 Legal —
/// both must render without auth"), so this screen has zero provider reads,
/// zero network calls, and is reachable via a plain Navigator.push from
/// anywhere (including before sign-in) exactly like G4 Emergency Card Info.
///
/// The terms and privacy policy come from `legal_text.dart`; the hosted pages
/// in `deploy/legal/` carry the same wording (a test fails if they drift).
/// Owner/legal/store review remains a separate launch requirement.
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
          const _BodyText('Last updated: $legalLastUpdated', muted: true),
          const SizedBox(height: AppSpace.sm),
          const _LegalSections(termsOfServiceSections),
          const SizedBox(height: AppSpace.xl),
          const _SectionHeader(title: 'Privacy Policy'),
          const SizedBox(height: AppSpace.xs),
          const _BodyText('Last updated: $legalLastUpdated', muted: true),
          const SizedBox(height: AppSpace.sm),
          const _LegalSections(privacyPolicySections),
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

/// Renders numbered sections: a heading, then paragraphs and bullet lists.
class _LegalSections extends StatelessWidget {
  final List<LegalSection> sections;
  const _LegalSections(this.sections);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final section in sections) ...[
        const SizedBox(height: AppSpace.md),
        Text(
          section.title,
          style: BambooFonts.heading(14, color: BambooInk.ink900),
        ),
        const SizedBox(height: AppSpace.xs),
        for (final block in section.blocks)
          if (block.text != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: _BodyText(block.text!),
            )
          else
            for (final item in block.items)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _BodyText('•  '),
                    Expanded(child: _BodyText(item)),
                  ],
                ),
              ),
      ],
    ],
  );
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
