import 'migration_report_screen.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/local_sms_rig_build.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../providers/data_providers.dart';

const _gutter = 20.0;

class SmsV2HomePrompt extends ConsumerWidget {
  const SmsV2HomePrompt({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available =
        ref.watch(instrumentsProvider).valueOrNull ?? const <Instrument>[];
    if (available.isEmpty) {
      return LocalSmsRigBuild.controlsEnabled
          ? Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _gutter,
                vertical: AppSpace.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _ShortcutChip(
                  icon: Icons.manage_history_rounded,
                  label: 'History update',
                  onPressed: () => context.push('/sms-v2/migration'),
                ),
              ),
            )
          : const SizedBox.shrink();
    }
    final detected = available
        .where((i) => i.status == InstrumentStatus.detected)
        .length;
    final report = ref.watch(migrationPromptProvider).valueOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (report != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _gutter,
                0,
                _gutter,
                AppSpace.sm,
              ),
              child: _PromptRow(
                icon: Icons.history_rounded,
                title: 'Your history has been rechecked',
                subtitle:
                    '${report.duplicatesMerged} duplicate entries merged • ${report.holdsRemoved} holds corrected',
                onTap: () => context.push('/sms-v2/migration'),
              ),
            ),
          if (detected > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _gutter,
                0,
                _gutter,
                AppSpace.sm,
              ),
              child: _PromptRow(
                icon: Icons.account_balance_outlined,
                title:
                    'We found $detected ${detected == 1 ? 'account or card' : 'accounts and cards'}',
                subtitle: 'Confirm what belongs to you.',
                onTap: () => context.push('/sms-v2/instruments'),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: _gutter),
            child: Row(
              spacing: AppSpace.sm,
              children: [
                _ShortcutChip(
                  icon: Icons.account_balance_outlined,
                  label: 'Accounts',
                  onPressed: () => context.push('/sms-v2/instruments'),
                ),
                _ShortcutChip(
                  icon: Icons.show_chart_rounded,
                  label: 'Investments',
                  onPressed: () => context.push('/sms-v2/investments'),
                ),
                _ShortcutChip(
                  icon: Icons.lock_clock_outlined,
                  label: 'IPOs',
                  onPressed: () => context.push('/sms-v2/ipos'),
                ),
                _ShortcutChip(
                  icon: Icons.manage_history_rounded,
                  label: 'History update',
                  onPressed: () => context.push('/sms-v2/migration'),
                ),
                _ShortcutChip(
                  icon: Icons.autorenew_rounded,
                  label: 'Subscriptions',
                  onPressed: () => context.push('/sms-v2/subscriptions'),
                ),
                _ShortcutChip(
                  icon: Icons.south_west_rounded,
                  label: 'Money in',
                  onPressed: () => context.push('/sms-v2/money-in'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PromptRow extends StatelessWidget {
  const _PromptRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return BambooPanel(
      onTap: onTap,
      semanticLabel: title,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          BambooIconTile(icon),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: BambooFonts.ui(
                    14.5,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500),
        ],
      ),
    );
  }
}

class _ShortcutChip extends StatelessWidget {
  const _ShortcutChip({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: Icon(icon, size: 16, color: BambooInk.ink700),
    label: Text(label),
    onPressed: onPressed,
  );
}
