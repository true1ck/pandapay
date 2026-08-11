import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';

/// S5 (ui-spec System Surfaces, GAP_ANALYSIS.md §3) — blocks the app when
/// the installed version is older than app_status.min_supported_version.
/// No "skip" or "later" — a forced upgrade is forced by definition; the
/// only way out is actually updating, same as router.dart's onboarding
/// guard treats its own preOnboarding set as unbypassable by direct nav.
///
/// The Play Store / App Store URL isn't in app_status (GAP_ANALYSIS.md
/// flagged S5/S6 as unbuilt with no store-listing plumbing anywhere yet in
/// this codebase) — hardcoded as a TODO-style placeholder search query
/// rather than a fabricated real listing URL, since PandaPay has no
/// confirmed real Play Store listing at the time this screen was built.
class ForcedUpgradeScreen extends StatelessWidget {
  const ForcedUpgradeScreen({super.key});

  static const _storeSearchUrl = 'https://play.google.com/store/search?q=pandapay&c=apps';

  Future<void> _openStore(BuildContext context) async {
    final launched = await launchUrl(Uri.parse(_storeSearchUrl), mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't open the store — update PandaPay from your device's app store."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.slate,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.system_update_rounded, color: BambooInk.lime, size: 56),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'Update required',
                  textAlign: TextAlign.center,
                  style: BambooFonts.heading(22, color: BambooInk.onSlate),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  "This version of PandaPay is no longer supported. Update to keep using the app.",
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(14.5, color: BambooInk.onSlateMuted),
                ),
                const SizedBox(height: AppSpace.xl),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.lime,
                    foregroundColor: BambooInk.slate,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                  ),
                  onPressed: () => _openStore(context),
                  child: const Text('Update now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
