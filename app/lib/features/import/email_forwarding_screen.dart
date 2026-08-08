import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/import_repository.dart';

/// ui-spec.md F3 Email Forwarding Setup ⭐ highest-friction flow.
///
/// Scope decision (Task F-0, per implementation-plan-group-e-f-g.md §3):
/// this screen builds the forwarding-address ISSUANCE + STATUS-POLLING UI
/// only. It deliberately does NOT build live inbound-email ingestion — no
/// SMTP server or webhook receiver exists anywhere in this codebase to
/// actually deliver mail sent to the issued address, so `emailCount` will
/// stay 0 and status will stay "Waiting for first email…" forever in this
/// environment. That's a real, honestly-reported status, not a fake one —
/// see POST /forwarding-addresses' doc-comment (api/src/index.js) for the
/// full reasoning. Gmail's verification-code paste step and the
/// provider-specific screenshots both depend on that ingestion path
/// existing (the plan's own sequencing note), so neither is built here —
/// only the generic forward-to-this-address instructions are shown.
///
/// Skippable at any point per spec: this is a plain pushed route, back
/// navigation is always available, nothing blocks progress elsewhere in
/// the app on this being completed.
class EmailForwardingScreen extends ConsumerWidget {
  const EmailForwardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forwarding = ref.watch(forwardingAddressProvider);
    final repo = ref.watch(importRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Email forwarding')),
      body: forwarding.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(forwardingAddressProvider),
        ),
        data: (addr) {
          if (repo == null) {
            return const EmptyState(
              icon: Icons.email_outlined,
              title: 'Sign in to set up email forwarding',
            );
          }
          if (addr == null) {
            return _IssueAddressView(
              onIssue: () async {
                await repo.issueForwardingAddress();
                ref.invalidate(forwardingAddressProvider);
              },
            );
          }
          return _StatusView(address: addr, onRefresh: () => ref.invalidate(forwardingAddressProvider));
        },
      ),
    );
  }
}

class _IssueAddressView extends StatefulWidget {
  final Future<void> Function() onIssue;
  const _IssueAddressView({required this.onIssue});

  @override
  State<_IssueAddressView> createState() => _IssueAddressViewState();
}

class _IssueAddressViewState extends State<_IssueAddressView> {
  bool _issuing = false;

  Future<void> _issue() async {
    setState(() => _issuing = true);
    try {
      await widget.onIssue();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _issuing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.forward_to_inbox_outlined,
      title: 'Forward your bank emails automatically',
      message:
          'We give you a unique email address. Set up forwarding once in your email provider and every '
          'bank statement/alert email sent there gets parsed into transactions automatically.',
      action: ElevatedButton(
        onPressed: _issuing ? null : _issue,
        child: Text(_issuing ? 'Creating…' : 'Get my forwarding address'),
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  final ForwardingAddress address;
  final VoidCallback onRefresh;
  const _StatusView({required this.address, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final connected = address.emailCount > 0;

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(color: AppColors.navy900, borderRadius: BorderRadius.circular(AppRadius.lg)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your forwarding address', style: textTheme.labelMedium?.copyWith(color: Colors.white60)),
              const SizedBox(height: AppSpace.sm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      address.fullAddress,
                      style: textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, color: Colors.white70, size: 20),
                    tooltip: 'Copy',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: address.fullAddress));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        Row(
          children: [
            Icon(
              connected ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
              size: 18,
              color: connected ? AppColors.success : AppColors.warning,
            ),
            const SizedBox(width: AppSpace.sm),
            Text(
              connected ? 'Connected — ${address.emailCount} received' : 'Waiting for first email…',
              style: textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(height: AppSpace.xxl),
        Text('How to set up forwarding', style: textTheme.labelLarge),
        const SizedBox(height: AppSpace.sm),
        const _StepTile(
          step: 1,
          text: 'Open your email provider\'s settings (Gmail: Settings → Forwarding and POP/IMAP).',
        ),
        const _StepTile(step: 2, text: 'Add the address above as a forwarding destination.'),
        const _StepTile(
          step: 3,
          text: 'Set a filter so only your bank\'s emails forward here — never forward everything.',
        ),
        const SizedBox(height: AppSpace.md),
        Container(
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
          child: Text(
            'Provider-specific step-by-step guides with screenshots (Gmail/Outlook/Yahoo/Other) and Gmail\'s '
            'forwarding-verification-code paste step aren\'t available yet — both need a live inbound-email '
            'receiver, which this pass didn\'t build (see this screen\'s doc-comment).',
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink500),
          ),
        ),
        const SizedBox(height: AppSpace.xxl),
        OutlinedButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Check status'),
        ),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  final int step;
  final String text;
  const _StepTile({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 11, backgroundColor: AppColors.teal600, child: Text('$step', style: const TextStyle(fontSize: 12, color: Colors.white))),
          const SizedBox(width: AppSpace.sm),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
