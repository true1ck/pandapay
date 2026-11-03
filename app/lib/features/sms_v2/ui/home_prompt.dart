import 'migration_report_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../flag.dart';
import '../providers/data_providers.dart';

class SmsV2HomePrompt extends ConsumerWidget {
  const SmsV2HomePrompt({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(smsPipelineV2EnabledProvider)) {
      return const SizedBox.shrink();
    }
    final available =
        ref.watch(instrumentsProvider).valueOrNull ?? const <Instrument>[];
    if (available.isEmpty) return const SizedBox.shrink();
    final detected =
        (ref.watch(instrumentsProvider).valueOrNull ?? const <Instrument>[])
            .where((i) => i.status == InstrumentStatus.detected)
            .length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        children: [
          if (ref.watch(migrationPromptProvider).valueOrNull case final report?)
            Card(
              child: ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Your history has been rechecked'),
                subtitle: Text(
                  '${report.duplicatesMerged} duplicate entries merged • ${report.holdsRemoved} holds corrected',
                ),
                onTap: () => context.push('/sms-v2/migration'),
              ),
            ),
          if (detected > 0)
            Card(
              child: ListTile(
                leading: const Icon(Icons.account_balance_outlined),
                title: Text(
                  'We found $detected ${detected == 1 ? 'account or card' : 'accounts and cards'}',
                ),
                subtitle: const Text('Confirm what belongs to you.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/sms-v2/instruments'),
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                label: const Text('Accounts'),
                onPressed: () => context.push('/sms-v2/instruments'),
              ),
              ActionChip(
                label: const Text('Investments'),
                onPressed: () => context.push('/sms-v2/investments'),
              ),
              ActionChip(
                label: const Text('IPOs'),
                onPressed: () => context.push('/sms-v2/ipos'),
              ),
              ActionChip(
                label: const Text('History update'),
                onPressed: () => context.push('/sms-v2/migration'),
              ),
              ActionChip(
                label: const Text('Subscriptions'),
                onPressed: () => context.push('/sms-v2/subscriptions'),
              ),
              ActionChip(
                label: const Text('Money in'),
                onPressed: () => context.push('/sms-v2/money-in'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
