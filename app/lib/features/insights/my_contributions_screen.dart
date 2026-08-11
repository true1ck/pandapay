import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// ui-spec.md E12 My Contributions. Significantly scoped down from the
/// plan's original ask — see GET /my-contributions' doc-comment
/// (api/src/index.js) for why: `merchant_contributions` is deliberately
/// R2-designed with NO profile_id column ("R2 IS ABSOLUTE HERE... Devices
/// are identified by a salted, ROTATING hash used only for rate
/// limiting"), so a genuine per-user "how many merchants have YOU
/// mapped/confirmed" count cannot be computed server-side without adding a
/// profile_id column to a table whose own migration explicitly says that's
/// deliberate — a schema-design decision out of scope for this pass.
///
/// What this screen actually shows: the opt-in toggle (wired to
/// profiles.contributions_opt_in, real and working) and network-wide
/// aggregate stats (real, safe under R2 — no per-user data at all). It
/// does NOT show a per-user contribution count or "you've helped X users"
/// figure — showing either would mean fabricating a number the app can't
/// justify, which the cross-cutting data-honesty rule forbids.
class MyContributionsScreen extends ConsumerWidget {
  const MyContributionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(contributionNetworkStatsProvider);
    final optedIn = ref.watch(contributionsOptInProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Container(
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Share what you see', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                    const SizedBox(height: 4),
                    Text(
                      'When on, PandaPay may anonymously log a merchant name/MCC/rough location '
                      '(never an amount, exact time, or your identity) to help other users\' '
                      'recommendations. You can turn this off any time.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Switch(
                value: optedIn,
                activeTrackColor: BambooInk.jade,
                activeColor: BambooInk.lime,
                onChanged: (v) async {
                  final repo = ref.read(userCardsRepositoryProvider);
                  if (repo == null) return;
                  try {
                    await repo.setContributionsOptIn(v);
                    ref.invalidate(profileProvider);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
                    }
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        Text(
          'Network-wide',
          style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
        ),
        const SizedBox(height: AppSpace.sm),
        stats.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(contributionNetworkStatsProvider),
          ),
          data: (s) {
            if (s == null) {
              return const EmptyState(icon: Icons.groups_outlined, title: 'Sign in to see network stats');
            }
            return Container(
              padding: const EdgeInsets.all(AppSpace.lg),
              decoration: BoxDecoration(
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${s.publishedMerchantCount}',
                    style: BambooFonts.heading(26, color: BambooInk.ink900),
                  ),
                  Text(
                    'merchants published across all contributors',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    '${s.contributingDeviceCount}',
                    style: BambooFonts.heading(26, color: BambooInk.ink900),
                  ),
                  Text(
                    'devices have contributed at least one report',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    'This is a network-wide total, not specific to your own contributions — '
                    'per-contributor counts aren\'t tracked, by design (see the privacy note above).',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
