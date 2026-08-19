import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/import_repository.dart';

/// ui-spec.md F3 Email Forwarding Setup ⭐ highest-friction flow, rebuilt
/// around a provider picker (Task F-8).
///
/// ## Why forwarding rather than "link your Gmail"
///
/// The obvious design here — the one most finance apps show — is a list of
/// providers you tap to "connect", implying OAuth. PandaPay deliberately
/// doesn't do that, and the copy must not imply it does. OAuth on Gmail
/// would put PandaPay into Google's restricted-scope programme with an
/// annual CASA security assessment attached; forwarding needs no OAuth
/// grant, no stored credential, and no Google policy staying still.
///
/// So the provider list here picks *instructions*, not an auth flow. Each
/// entry opens the exact settings path for that provider. That's the real
/// work in this screen: the friction is entirely in "where is that setting",
/// and a generic "set up forwarding in your email provider" sentence leaves
/// every user to find it themselves.
///
/// ## The verification step
///
/// Gmail (and Outlook/Yahoo) won't forward to a new address until you prove
/// you own it: they mail a code or a link there first. That mail reaches
/// `inbound_emails` — and before Task F-8, nothing ever showed it to the
/// user, so setup dead-ended silently for most people. [_VerificationCard]
/// surfaces it as the loudest thing on the screen while it's live.
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
        title: Text('Email statements', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: AppBackground(
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
                title: 'Sign in to set up email statements',
              );
            }
            if (addr == null) {
              return _IntroView(
                onIssue: () async {
                  await repo.issueForwardingAddress();
                  ref.invalidate(forwardingAddressProvider);
                },
              );
            }
            return _SetupView(address: addr);
          },
        ),
      ),
    );
  }
}

// ---- Intro ----------------------------------------------------------------

/// The pitch, before an address exists. Three concrete outcomes rather than
/// a description of the mechanism — the mechanism comes next, once they've
/// said yes.
class _IntroView extends StatefulWidget {
  final Future<void> Function() onIssue;
  const _IntroView({required this.onIssue});

  @override
  State<_IntroView> createState() => _IntroViewState();
}

class _IntroViewState extends State<_IntroView> {
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
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        const SizedBox(height: AppSpace.md),
        const _FlowGlyph(),
        const SizedBox(height: AppSpace.xl),
        Text(
          'Track statements from your\nbank emails',
          style: BambooFonts.heading(24, color: BambooInk.ink900),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          'Forward the emails your bank already sends you. PandaPay reads the statement '
          'and alert emails, and nothing else.',
          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
        ),
        const SizedBox(height: AppSpace.xl),
        const _Benefit(text: 'Reward points tracked as they post'),
        const _Benefit(text: 'Spends logged without typing them in'),
        const _Benefit(text: 'Statement totals you can check against'),
        const SizedBox(height: AppSpace.xxl),
        FilledButton(
          style: _primary.copyWith(minimumSize: WidgetStatePropertyAll(const Size.fromHeight(52))),
          onPressed: _issuing ? null : _issue,
          child: Text(_issuing ? 'Setting up…' : 'Get started'),
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          "PandaPay never asks for your email password, and doesn't sign in to your mailbox. "
          'You set up forwarding yourself and can turn it off from your email provider at any time.',
          textAlign: TextAlign.center,
          style: BambooFonts.ui(11.5, color: BambooInk.ink500),
        ),
      ],
    );
  }
}

/// The mail → wallet glyph. Drawn from theme tokens rather than shipped as
/// an asset so it stays correct if the palette moves.
class _FlowGlyph extends StatelessWidget {
  const _FlowGlyph();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _circle(Icons.mail_outline_rounded, BambooInk.paperMuted, BambooInk.slate),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          child: Row(
            children: List.generate(
              5,
              (i) => Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.symmetric(horizontal: 2.5),
                decoration: const BoxDecoration(color: BambooInk.ink300, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
        _circle(Icons.account_balance_wallet_outlined, BambooInk.slate, BambooInk.lime),
      ],
    );
  }

  Widget _circle(IconData icon, Color bg, Color fg) => Container(
    width: 64,
    height: 64,
    decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
    child: Icon(icon, size: 28, color: fg),
  );
}

class _Benefit extends StatelessWidget {
  final String text;
  const _Benefit({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded, size: 20, color: BambooInk.jade),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(text, style: BambooFonts.ui(14, color: BambooInk.ink900)),
          ),
        ],
      ),
    );
  }
}

// ---- Setup ----------------------------------------------------------------

class _SetupView extends ConsumerWidget {
  final ForwardingAddress address;
  const _SetupView({required this.address});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = address.emailCount > 0;
    final verification = ref.watch(forwardingVerificationProvider);
    final inboundEmails = ref.watch(inboundEmailsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(forwardingAddressProvider);
        ref.invalidate(forwardingVerificationProvider);
        ref.invalidate(inboundEmailsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          _AddressCard(address: address, connected: connected),
          const SizedBox(height: AppSpace.md),

          // The verification code jumps the queue when it exists — at that
          // moment it is the only thing standing between the user and a
          // working setup, and it expires.
          verification.maybeWhen(
            data: (v) => v == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: _VerificationCard(verification: v),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),

          if (!connected) ...[
            Text(
              'Set up forwarding',
              style: BambooFonts.heading(15, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Pick where you get your bank emails. Forward only your bank — never everything.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            for (final provider in _providers) ...[
              _ProviderTile(
                provider: provider,
                onTap: () => _showProviderSteps(context, provider, address),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
          ],

          if (connected) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              'Emails received',
              style: BambooFonts.heading(15, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            inboundEmails.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpace.md),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (err, _) =>
                  Text(userFacingErrorMessage(err), style: BambooFonts.ui(12.5, color: BambooInk.clay)),
              data: (emails) => emails.isEmpty
                  ? Text('Nothing yet.', style: BambooFonts.ui(12.5, color: BambooInk.ink500))
                  : Column(children: [for (final e in emails) _InboundEmailRow(email: e)]),
            ),
            const SizedBox(height: AppSpace.lg),
            OutlinedButton.icon(
              style: _secondary,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Forward another mailbox'),
              onPressed: () => _showProviderPicker(context, address),
            ),
          ],
        ],
      ),
    );
  }

  void _showProviderPicker(BuildContext context, ForwardingAddress address) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpace.lg),
                decoration: BoxDecoration(
                  color: BambooInk.ink300,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              Text(
                'Where do you get your bank emails?',
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.md),
              for (final provider in _providers) ...[
                _ProviderTile(
                  provider: provider,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _showProviderSteps(context, provider, address);
                  },
                ),
                const SizedBox(height: AppSpace.sm),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showProviderSteps(BuildContext context, _Provider provider, ForwardingAddress address) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetContext) => _ProviderStepsSheet(provider: provider, address: address),
    );
  }
}

class _AddressCard extends StatelessWidget {
  final ForwardingAddress address;
  final bool connected;
  const _AddressCard({required this.address, required this.connected});

  @override
  Widget build(BuildContext context) {
    return Container(
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
          Row(
            children: [
              Text(
                'Forward your bank email here',
                style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 3),
                decoration: BoxDecoration(
                  color: connected ? BambooInk.jade : BambooInk.amber,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  connected ? 'Receiving' : 'Waiting',
                  style: BambooFonts.ui(10.5, weight: FontWeight.w700, color: BambooInk.slate),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          SelectableText(
            address.fullAddress,
            style: BambooFonts.heading(17, color: BambooInk.onSlate),
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  connected
                      ? '${address.emailCount} email${address.emailCount == 1 ? '' : 's'} received'
                      : 'No emails yet',
                  style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 16, color: BambooInk.lime),
                label: Text('Copy', style: BambooFonts.ui(12.5, color: BambooInk.lime)),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: address.fullAddress));
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Address copied')));
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Task F-8. Deliberately the loudest element on the screen while it exists:
/// the user is mid-flow in another app, waiting on this exact number, and
/// before this card existed there was nowhere for them to find it.
class _VerificationCard extends StatelessWidget {
  final ForwardingVerification verification;
  const _VerificationCard({required this.verification});

  @override
  Widget build(BuildContext context) {
    final name = switch (verification.provider) {
      'gmail' => 'Gmail',
      'outlook' => 'Outlook',
      'yahoo' => 'Yahoo',
      _ => 'Your email provider',
    };

    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.amber, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.key_rounded, size: 18, color: BambooInk.amber),
              const SizedBox(width: AppSpace.sm),
              Text(
                '$name is waiting for this code',
                style: BambooFonts.heading(14.5, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (verification.code != null) ...[
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    verification.code!,
                    style: BambooFonts.heading(28, color: BambooInk.ink900),
                  ),
                ),
                OutlinedButton(
                  style: _secondary,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: verification.code!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('Code copied')));
                    }
                  },
                  child: const Text('Copy'),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Paste this back into $name\'s forwarding settings to finish. '
              'It usually expires within a few minutes.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ] else ...[
            Text(
              '$name sent a confirmation link instead of a code. Open $name\'s forwarding '
              'settings and confirm there — the link was delivered to your forwarding address.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
        ],
      ),
    );
  }
}

class _InboundEmailRow extends StatelessWidget {
  final InboundEmail email;
  const _InboundEmailRow({required this.email});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (email.parsedOk) {
      true => (
        Icons.check_circle_rounded,
        BambooInk.jade,
        email.producedTxnId != null ? 'Added as a transaction' : 'Read — ready to add',
      ),
      false => (Icons.error_outline_rounded, BambooInk.amber, "Couldn't read this one"),
      _ => (Icons.hourglass_top_rounded, BambooInk.ink500, 'Received'),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  email.subject ?? email.sender ?? 'Email',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(label, style: BambooFonts.ui(12, color: BambooInk.ink500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Providers ------------------------------------------------------------

/// One provider's forwarding setup. [steps] are the real navigation paths;
/// the whole value of this screen over a generic instruction is that these
/// are specific enough to follow without searching.
class _Provider {
  final String id;
  final String name;
  final IconData icon;
  final Color tint;
  final String settingsHint;
  final List<String> steps;

  const _Provider({
    required this.id,
    required this.name,
    required this.icon,
    required this.tint,
    required this.settingsHint,
    required this.steps,
  });
}

const _providers = <_Provider>[
  _Provider(
    id: 'gmail',
    name: 'Gmail',
    icon: Icons.mail_rounded,
    tint: Color(0xFFEA4335),
    settingsHint: 'Settings → Forwarding and POP/IMAP',
    steps: [
      'Open Gmail on a computer (the mobile app can\'t add a forwarding address).',
      'Go to Settings → See all settings → Forwarding and POP/IMAP.',
      'Click "Add a forwarding address" and paste your PandaPay address.',
      'Gmail emails a confirmation code — come back here and it will appear at the top of this screen.',
      'Paste the code into Gmail, then create a filter: Settings → Filters → "From" your bank → Forward to your PandaPay address.',
    ],
  ),
  _Provider(
    id: 'outlook',
    name: 'Outlook',
    icon: Icons.alternate_email_rounded,
    tint: Color(0xFF0078D4),
    settingsHint: 'Settings → Mail → Forwarding',
    steps: [
      'Open Outlook.com and go to Settings → Mail → Forwarding.',
      'Rather than forwarding everything, prefer Rules: Settings → Mail → Rules → Add new rule.',
      'Condition: "From" contains your bank\'s domain. Action: "Forward to" your PandaPay address.',
      'Save. Outlook may send a confirmation — it will appear at the top of this screen.',
    ],
  ),
  _Provider(
    id: 'yahoo',
    name: 'Yahoo Mail',
    icon: Icons.markunread_mailbox_outlined,
    tint: Color(0xFF6001D2),
    settingsHint: 'Settings → Mailboxes → Forwarding',
    steps: [
      'Open Yahoo Mail → Settings → More Settings → Mailboxes.',
      'Select your account, then "Forwarding address" → Add.',
      'Paste your PandaPay address and save.',
      'Yahoo sends a verification email — it will appear at the top of this screen.',
    ],
  ),
  _Provider(
    id: 'other',
    name: 'Another provider',
    icon: Icons.more_horiz_rounded,
    tint: Color(0xFF5B6472),
    settingsHint: 'Any mailbox with forwarding rules',
    steps: [
      'Open your email provider\'s settings and look for "Forwarding", "Filters" or "Rules".',
      'Add a rule that forwards mail from your bank\'s address to your PandaPay address.',
      'Forward only your bank — a catch-all forward sends us mail we don\'t need and won\'t read.',
      'If your provider sends a confirmation code, it will appear at the top of this screen.',
    ],
  ),
];

class _ProviderTile extends StatelessWidget {
  final _Provider provider;
  final VoidCallback onTap;
  const _ProviderTile({required this.provider, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: provider.tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(provider.icon, size: 18, color: provider.tint),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(provider.name, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                    const SizedBox(height: 1),
                    Text(
                      provider.settingsHint,
                      style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, size: 18, color: BambooInk.ink300),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderStepsSheet extends StatelessWidget {
  final _Provider provider;
  final ForwardingAddress address;
  const _ProviderStepsSheet({required this.provider, required this.address});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      expand: false,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: AppSpace.lg),
              decoration: BoxDecoration(
                color: BambooInk.ink300,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ),
          Row(
            children: [
              Icon(provider.icon, size: 22, color: provider.tint),
              const SizedBox(width: AppSpace.sm),
              Text(
                'Forwarding from ${provider.name}',
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    address.fullAddress,
                    style: BambooFonts.ui(13.5, weight: FontWeight.w700, color: BambooInk.ink900),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 18, color: BambooInk.ink500),
                  tooltip: 'Copy',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: address.fullAddress));
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('Address copied')));
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          for (var i = 0; i < provider.steps.length; i++) ...[
            _StepTile(step: i + 1, text: provider.steps[i]),
          ],
          const SizedBox(height: AppSpace.md),
          Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Text(
              'Forward only your bank\'s emails. PandaPay ignores mail from anyone it doesn\'t '
              'recognise as a bank, so a catch-all forward gains you nothing and sends us more '
              'than we need.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          FilledButton(
            style: _primary.copyWith(minimumSize: WidgetStatePropertyAll(const Size.fromHeight(50))),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
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
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: BambooInk.slate,
            child: Text(
              '$step',
              style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.lime),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(text, style: BambooFonts.ui(13.5, color: BambooInk.ink900)),
          ),
        ],
      ),
    );
  }
}

final ButtonStyle _primary = FilledButton.styleFrom(
  backgroundColor: BambooInk.slate,
  foregroundColor: BambooInk.lime,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
);

final ButtonStyle _secondary = OutlinedButton.styleFrom(
  foregroundColor: BambooInk.ink900,
  side: const BorderSide(color: BambooInk.hairlineOnPaper),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
);
