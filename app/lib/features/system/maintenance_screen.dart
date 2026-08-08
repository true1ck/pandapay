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
      backgroundColor: AppColors.navy900,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.build_circle_outlined, color: Colors.white, size: 56),
              const SizedBox(height: AppSpace.lg),
              Text(
                "PandaPay is briefly unavailable",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: AppSpace.xl),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                ),
                onPressed: () => ref.invalidate(appStatusProvider),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
