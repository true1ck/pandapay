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
/// Forwarding-address issuance + status-polling UI, now backed by a real
/// receiver: POST /inbound-emails/webhook (api/src/index.js) actually
/// writes to `inbound_emails` and bumps `forwarding_addresses.email_count`
/// once a mail provider (SendGrid/Mailgun inbound parse, or a Cloudflare
/// Email Worker) is configured to POST forwarded mail there for a given
/// deployment. That DNS + provider-dashboard wiring is real infra setup
/// outside this repo (same class of action as the Play Store listing or
/// scraper legal review) — until it's done for a given environment,
/// `emailCount` legitimately stays 0, which is still an honestly-reported
/// status, not a fake one.
///
/// Gmail's verification-code paste step and provider-specific screenshots
/// still aren't built (lower priority than the ingestion pipeline itself)
/// — only the generic forward-to-this-address instructions are shown.
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
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Email forwarding', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
        child: forwarding.when(
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
      action: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: BambooInk.slate,
          foregroundColor: BambooInk.lime,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
        ),
        onPressed: _issuing ? null : _issue,
        child: Text(_issuing ? 'Creating…' : 'Get my forwarding address'),
      ),
    );
  }
}

class _StatusView extends ConsumerWidget {
  final ForwardingAddress address;
  final VoidCallback onRefresh;
  const _StatusView({required this.address, required this.onRefresh});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = address.emailCount > 0;
    final inboundEmails = ref.watch(inboundEmailsProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [BambooInk.slateRaised, BambooInk.slate],
            ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your forwarding address', style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
              const SizedBox(height: AppSpace.sm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      address.fullAddress,
                      style: BambooFonts.heading(16, color: BambooInk.onSlate),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, color: BambooInk.onSlateMuted, size: 20),
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
              color: connected ? BambooInk.jade : BambooInk.amber,
            ),
            const SizedBox(width: AppSpace.sm),
            Text(
              connected ? 'Connected — ${address.emailCount} received' : 'Waiting for first email…',
              style: BambooFonts.heading(14.5, color: BambooInk.ink900),
            ),
          ],
        ),
        if (connected) ...[
          const SizedBox(height: AppSpace.xxl),
          Text('Recent emails', style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.sm),
          inboundEmails.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpace.md),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (err, _) => Text(userFacingErrorMessage(err), style: BambooFonts.ui(12.5, color: BambooInk.clay)),
            data: (emails) {
              if (emails.isEmpty) {
                return Text('No emails received yet.', style: BambooFonts.ui(12.5, color: BambooInk.ink500));
              }
              return Column(
                children: emails
                    .map((e) => Container(
                          margin: const EdgeInsets.only(bottom: AppSpace.sm),
                          padding: const EdgeInsets.all(AppSpace.md),
                          decoration: BoxDecoration(
                            color: BambooInk.glassFillOnPaper,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: BambooInk.hairlineOnPaper),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                e.parsedOk == true
                                    ? Icons.check_circle_rounded
                                    : (e.parsedOk == false ? Icons.error_outline_rounded : Icons.hourglass_top_rounded),
                                size: 16,
                                color: e.parsedOk == true ? BambooInk.jade : BambooInk.amber,
                              ),
                              const SizedBox(width: AppSpace.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      e.subject ?? e.sender ?? 'Email',
                                      style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      e.parsedOk == true
                                          ? (e.producedTxnId != null ? 'Added as a transaction' : 'Parsed — ready to add')
                                          : (e.parsedOk == false ? 'Could not parse automatically' : 'Received'),
                                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              );
            },
          ),
        ],
        const SizedBox(height: AppSpace.xxl),
        Text('How to set up forwarding', style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900)),
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
          decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
          child: Text(
            'Provider-specific step-by-step guides with screenshots (Gmail/Outlook/Yahoo/Other) and Gmail\'s '
            'forwarding-verification-code paste step aren\'t available yet — both need a live inbound-email '
            'receiver, which this pass didn\'t build (see this screen\'s doc-comment).',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ),
        const SizedBox(height: AppSpace.xxl),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: BambooInk.ink900,
            side: const BorderSide(color: BambooInk.hairlineOnPaper),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
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
          CircleAvatar(
            radius: 11,
            backgroundColor: BambooInk.slate,
            child: Text('$step', style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.lime)),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(child: Text(text, style: BambooFonts.ui(13.5, color: BambooInk.ink900))),
        ],
      ),
    );
  }
}
