import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';

/// S6 (ui-spec System Surfaces, GAP_ANALYSIS.md §3) — a full-screen block
/// with no way past it other than app_status.maintenance_mode flipping back
/// to false server-side. router.dart's redirect guard re-checks
/// appStatusProvider on every refreshListenable tick, so this screen
/// disappears on its own once maintenance ends — no manual "try again"
/// polling loop needed here, just a retry button that re-triggers a fetch.
class MaintenanceScreen extends ConsumerWidget {
  const MaintenanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appStatusProvider).valueOrNull;
    final message = status?.maintenanceMessage ?? "We're doing some maintenance — please check back shortly.";

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
                const Icon(Icons.build_circle_outlined, color: BambooInk.lime, size: 56),
                const SizedBox(height: AppSpace.lg),
                Text(
                  "PandaPay is briefly unavailable",
                  textAlign: TextAlign.center,
                  style: BambooFonts.heading(22, color: BambooInk.onSlate),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(14.5, color: BambooInk.onSlateMuted),
                ),
                const SizedBox(height: AppSpace.xl),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BambooInk.onSlate,
                    side: const BorderSide(color: BambooInk.onSlateMuted),
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                  ),
                  onPressed: () => ref.invalidate(appStatusProvider),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
