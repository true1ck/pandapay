import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// Consent purpose and policy version recorded with `POST /consents`.
const emailImportConsentPurpose = 'email_import';
const emailImportPolicyVersion = '2026-11-15';

/// Email import sends email text to the server, so it has its own disclosure
/// and consent, separate from SMS and never bundled into the terms.
///
/// Shown as a modal sheet. Resolves to `true` only after the consent row was
/// written (`POST /consents`); dismissing the sheet or tapping "Not now"
/// resolves to `false`.
class EmailImportDisclosure extends ConsumerStatefulWidget {
  const EmailImportDisclosure({super.key, required this.sourceScreen});

  /// Which screen asked, stored with the consent row (`source_screen`).
  final String sourceScreen;

  static Future<bool> show(
    BuildContext context, {
    required String sourceScreen,
  }) async {
    final granted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (_) => EmailImportDisclosure(sourceScreen: sourceScreen),
    );
    return granted ?? false;
  }

  @override
  ConsumerState<EmailImportDisclosure> createState() =>
      _EmailImportDisclosureState();
}

class _EmailImportDisclosureState extends ConsumerState<EmailImportDisclosure> {
  bool _agreed = false;
  bool _saving = false;

  Future<void> _continue() async {
    final api = ref.read(consentsApiProvider);
    if (api == null) {
      _showError('Sign in to connect your email.');
      return;
    }
    setState(() => _saving = true);
    try {
      await api.submit(
        purpose: emailImportConsentPurpose,
        granted: true,
        policyVersion: emailImportPolicyVersion,
        sourceScreen: widget.sourceScreen,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _showError(userFacingErrorMessage(e));
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'PandaPay reads your bank emails',
            style: BambooFonts.heading(20, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.lg),
          const _Point(
            icon: Icons.mail_outline_rounded,
            text:
                'Connecting your mailbox lets PandaPay check it regularly for emails from your banks '
                'and cards and record those transactions. Forwarded emails are read the same way.',
          ),
          const _Point(
            icon: Icons.filter_alt_outlined,
            text:
                'Only emails from bank and card senders are read. Other emails are not opened.',
          ),
          const _Point(
            icon: Icons.lock_outline_rounded,
            text:
                'The email text is sent to PandaPay to read the transaction and deleted once it has '
                'been read. Emails PandaPay couldn\'t read are kept for up to 30 days so you can review them.',
          ),
          const _Point(
            icon: Icons.key_outlined,
            text:
                'Your mailbox app password is stored encrypted and used only to read these emails. '
                'Disconnecting deletes it.',
          ),
          const SizedBox(height: AppSpace.sm),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _agreed,
            onChanged: _saving
                ? null
                : (value) => setState(() => _agreed = value ?? false),
            title: Text(
              'I agree to PandaPay reading my bank emails as described.',
              style: BambooFonts.ui(14, color: BambooInk.ink900),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            onPressed: (_agreed && !_saving) ? _continue : null,
            child: Text(_saving ? 'Saving…' : 'Continue'),
          ),
          const SizedBox(height: AppSpace.sm),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: BambooInk.slate),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              text,
              style: BambooFonts.ui(14, color: BambooInk.ink900),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the disclosure unless the latest `email_import` consent is already
/// granted for the current policy version. A failed lookup shows the
/// disclosure rather than assuming consent.
Future<bool> ensureEmailImportConsent(
  BuildContext context,
  WidgetRef ref, {
  required String sourceScreen,
}) async {
  if (await _hasCurrentEmailImportConsent(ref)) return true;
  if (!context.mounted) return false;
  return EmailImportDisclosure.show(context, sourceScreen: sourceScreen);
}

Future<bool> _hasCurrentEmailImportConsent(WidgetRef ref) async {
  final api = ref.read(consentsApiProvider);
  if (api == null) return false;
  try {
    final latest = await api.fetchLatest();
    return latest.any(
      (c) =>
          c.purpose == emailImportConsentPurpose &&
          c.granted &&
          c.revokedAt == null &&
          c.policyVersion == emailImportPolicyVersion,
    );
  } catch (_) {
    return false;
  }
}

/// Holds [child] back until the user has agreed to [EmailImportDisclosure].
/// Declining pops the screen it is on, so nothing behind it (the connect
/// form, the forwarding address) is shown without consent.
class EmailImportConsentGate extends ConsumerStatefulWidget {
  const EmailImportConsentGate({
    super.key,
    required this.sourceScreen,
    required this.child,
  });

  final String sourceScreen;
  final Widget child;

  @override
  ConsumerState<EmailImportConsentGate> createState() =>
      _EmailImportConsentGateState();
}

class _EmailImportConsentGateState
    extends ConsumerState<EmailImportConsentGate> {
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (!mounted) return;
    final granted = await ensureEmailImportConsent(
      context,
      ref,
      sourceScreen: widget.sourceScreen,
    );
    if (!mounted) return;
    if (granted) {
      setState(() => _granted = true);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_granted) return widget.child;
    return const Center(child: CircularProgressIndicator());
  }
}
