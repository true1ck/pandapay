import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import 'gmail_connect_service.dart';

/// Pre‑consent explanation shown before the Google account picker.
///
/// Google's own consent dialog can't be reworded, so this screen is where the
/// user is told, in plain language, exactly what PandaPay will read and what
/// it will not do — required both by Google's Limited Use policy and by
/// India's DPDP Act. Pops with a Gmail **access token** (`String`) on success,
/// or `null` if the user backs out.
class GmailConnectScreen extends ConsumerStatefulWidget {
  const GmailConnectScreen({super.key});

  @override
  ConsumerState<GmailConnectScreen> createState() => _GmailConnectScreenState();
}

class _GmailConnectScreenState extends ConsumerState<GmailConnectScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await ref.read(gmailConnectControllerProvider.notifier).connectAndGetToken();
      if (!mounted) return;
      if (token == null) {
        setState(() => _busy = false); // user cancelled the picker
        return;
      }
      Navigator.of(context).pop(token);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Couldn\'t connect to Gmail. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Connect Gmail', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, AppSpace.md, 24, 24),
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(color: BambooInk.paperMuted, shape: BoxShape.circle),
                child: const Icon(Icons.mark_email_read_outlined, size: 30, color: BambooInk.slate),
              ),
              const SizedBox(height: AppSpace.lg),
              Text(
                'Find your cards from bank emails',
                style: BambooFonts.heading(21, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                'PandaPay will look through your Gmail for credit‑card statements and '
                'transaction alerts, and suggest the cards it recognises. You add the '
                'ones you actually hold — nothing is added on its own.',
                style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.5),
              ),
              const SizedBox(height: AppSpace.xl),

              _Bullets(
                title: 'What we read',
                good: true,
                items: const [
                  'Read‑only access — we can never send, delete, or change your email.',
                  'Only emails from known banks (HDFC, ICICI, SBI, Axis, Amex, and similar), from the last ~15 months.',
                  'Just enough to recognise the card: issuer name and the last 4 digits.',
                ],
              ),
              const SizedBox(height: AppSpace.md),
              _Bullets(
                title: 'What stays on your phone',
                good: true,
                items: const [
                  'Emails are scanned and parsed entirely on this device.',
                  'No email content, and no Google sign‑in token, is ever sent to PandaPay\'s servers.',
                  'You can disconnect anytime in Settings → Privacy & Permissions, which revokes the access.',
                ],
              ),
              const SizedBox(height: AppSpace.xl),

              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(
                    color: BambooInk.clay.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Text(
                    _error!,
                    style: BambooFonts.ui(12.5, color: BambooInk.clay, height: 1.45),
                  ),
                ),
                const SizedBox(height: AppSpace.md),
              ],

              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
                ),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime),
                      )
                    : const Icon(Icons.lock_outline_rounded, size: 18),
                label: Text(_busy ? 'Connecting…' : 'Allow read‑only access & continue'),
                onPressed: _busy ? null : _connect,
              ),
              const SizedBox(height: AppSpace.sm),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(
                  'Not now',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink500, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                'Next you\'ll pick your Google account and see Google\'s own permission '
                'screen for "${_scopeLabel()}". Approving there is what grants the access.',
                style: BambooFonts.ui(11.5, color: BambooInk.ink300, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _scopeLabel() {
    // Human label for gmailReadonlyScope, matching Google's consent wording.
    assert(gmailReadonlyScope.endsWith('gmail.readonly'));
    return 'View your email messages and settings';
  }
}

class _Bullets extends StatelessWidget {
  final String title;
  final bool good;
  final List<String> items;

  const _Bullets({required this.title, required this.good, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.sm),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    good ? Icons.check_rounded : Icons.close_rounded,
                    size: 16,
                    color: good ? BambooInk.jade : BambooInk.clay,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(item, style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.45)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
