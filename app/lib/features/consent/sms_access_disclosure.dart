import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/consent_policy.dart';
import 'sms_reading_consent.dart';

/// Standalone disclosure shown before PandaPay touches SMS: before every
/// Android SMS permission request and before the iPhone Shortcut setup.
///
/// Google Play requires an in-app disclosure that immediately precedes the
/// permission request, cannot live only in the terms, and needs a tap or tick.
/// India's DPDP Act needs specific, informed and unconditional consent, so
/// "Not now" leaves the app fully usable for manual entry.
///
/// Shown as a modal sheet. Resolves to `true` only after the consent row was
/// written (`POST /consents`); dismissing the sheet or tapping "Not now"
/// resolves to `false`.
class SmsAccessDisclosure extends ConsumerStatefulWidget {
  const SmsAccessDisclosure({
    super.key,
    required this.sourceScreen,
    this.accountLabel,
    this.ios,
  });

  /// Which screen asked, stored with the consent row (`source_screen`).
  final String sourceScreen;

  /// Masked phone number or email of the account the messages will be added
  /// to. When unknown the copy says "your PandaPay account".
  final String? accountLabel;

  /// Forces the iPhone wording. Defaults to the running platform.
  final bool? ios;

  static Future<bool> show(
    BuildContext context, {
    required String sourceScreen,
    String? accountLabel,
    bool? ios,
  }) async {
    final granted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (_) => SmsAccessDisclosure(
        sourceScreen: sourceScreen,
        accountLabel: accountLabel,
        ios: ios,
      ),
    );
    return granted ?? false;
  }

  @override
  ConsumerState<SmsAccessDisclosure> createState() =>
      _SmsAccessDisclosureState();
}

/// The strings are fixed by the release plan (Task 5.1). Do not reword them
/// without changing the plan and the store declarations that quote them.
class SmsAccessDisclosureCopy {
  const SmsAccessDisclosureCopy._();

  static const title = 'PandaPay reads your bank SMS on this phone';
  static const androidReading =
      'PandaPay reads messages from banks, cards and wallets to record your '
      'transactions automatically, including in the background when a new '
      'message arrives.';
  static const iosReading =
      'PandaPay records your transactions from the bank messages you share '
      'with it through the Shortcut.';
  static const onThisPhone =
      'Messages are read on this phone. Only the transaction details (amount, '
      'merchant, date, card or account ending, and type) are sent to PandaPay, '
      'so your spending shows on any phone you sign in to.';
  static const skipped =
      'Personal messages and one-time passwords are skipped and never sent.';
  static const turnOff = 'You can turn this off in Settings at any time.';
  static const agree = 'I agree to PandaPay reading my bank SMS as described.';

  static String existing(String? accountLabel) =>
      accountLabel == null || accountLabel.isEmpty
      ? 'Messages already on this phone will be added to your PandaPay account.'
      : 'Messages already on this phone will be added to the account '
            '$accountLabel.';
}

class _SmsAccessDisclosureState extends ConsumerState<SmsAccessDisclosure> {
  bool _agreed = false;
  bool _saving = false;

  bool get _ios =>
      widget.ios ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _continue() async {
    final api = ref.read(consentsApiProvider);
    if (api == null) {
      _showError('Sign in to turn on SMS reading.');
      return;
    }
    final namespace = ref.read(cacheNamespaceProvider);
    setState(() => _saving = true);
    try {
      await api.submit(
        purpose: smsReadingConsentPurpose,
        granted: true,
        policyVersion: consentPolicyVersion,
        sourceScreen: widget.sourceScreen,
      );
      await SmsReadingConsentMirror.set(namespace, true);
      ref.invalidate(smsReadingConsentProvider);
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
            SmsAccessDisclosureCopy.title,
            style: BambooFonts.heading(20, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.lg),
          _Point(
            icon: Icons.sms_outlined,
            text: _ios
                ? SmsAccessDisclosureCopy.iosReading
                : SmsAccessDisclosureCopy.androidReading,
          ),
          const _Point(
            icon: Icons.phone_iphone_rounded,
            text: SmsAccessDisclosureCopy.onThisPhone,
          ),
          const _Point(
            icon: Icons.filter_alt_outlined,
            text: SmsAccessDisclosureCopy.skipped,
          ),
          _Point(
            icon: Icons.person_outline_rounded,
            text: SmsAccessDisclosureCopy.existing(widget.accountLabel),
          ),
          const _Point(
            icon: Icons.toggle_on_outlined,
            text: SmsAccessDisclosureCopy.turnOff,
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
              SmsAccessDisclosureCopy.agree,
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

/// A short, masked label for the signed-in account (`a***@example.com` or
/// `+91 ******3210`) taken from the profile row, or null when it is not known.
String? maskedAccountLabel(Map<String, dynamic>? profile) {
  final email = (profile?['email'] as String?)?.trim();
  if (email != null && email.contains('@')) {
    final at = email.indexOf('@');
    final local = email.substring(0, at);
    final head = local.isEmpty ? '' : local.substring(0, 1);
    return '$head***${email.substring(at)}';
  }
  final phone = (profile?['phone_number'] as String?)?.trim();
  if (phone != null && phone.length >= 4) {
    final digits = phone.replaceAll(RegExp(r'\s'), '');
    final tail = digits.substring(digits.length - 3);
    return '••••••$tail';
  }
  return null;
}

/// The profile is cache-first and usually loaded by now; when it is not, wait
/// only briefly so the disclosure is never held back by a slow network.
Future<String?> _accountLabel(WidgetRef ref) async {
  final loaded = ref.read(profileProvider).valueOrNull;
  if (loaded != null) return maskedAccountLabel(loaded);
  try {
    final profile = await ref
        .read(profileProvider.future)
        .timeout(const Duration(milliseconds: 400));
    return maskedAccountLabel(profile);
  } catch (_) {
    return null;
  }
}

/// Shows the disclosure unless this account already agreed (against the
/// current policy version). Call it immediately before any Android SMS
/// permission request or any step that starts reading messages; only proceed
/// when it returns `true`.
///
/// A failed lookup shows the disclosure rather than assuming consent.
Future<bool> ensureSmsReadingConsent(
  BuildContext context,
  WidgetRef ref, {
  required String sourceScreen,
  bool? ios,
}) async {
  try {
    if (await ref.read(smsReadingConsentProvider.future)) return true;
  } catch (_) {
    // Show the disclosure below.
  }
  final label = await _accountLabel(ref);
  if (!context.mounted) return false;
  return SmsAccessDisclosure.show(
    context,
    sourceScreen: sourceScreen,
    accountLabel: label,
    ios: ios,
  );
}

/// Holds [child] back until this account has agreed to
/// [SmsAccessDisclosure]. Declining pops the screen it is on, so nothing
/// behind it (the Shortcut setup, the history import) is shown without
/// consent.
class SmsReadingConsentGate extends ConsumerStatefulWidget {
  const SmsReadingConsentGate({
    super.key,
    required this.sourceScreen,
    required this.child,
    this.ios,
  });

  final String sourceScreen;
  final Widget child;
  final bool? ios;

  @override
  ConsumerState<SmsReadingConsentGate> createState() =>
      _SmsReadingConsentGateState();
}

class _SmsReadingConsentGateState extends ConsumerState<SmsReadingConsentGate> {
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (!mounted) return;
    final granted = await ensureSmsReadingConsent(
      context,
      ref,
      sourceScreen: widget.sourceScreen,
      ios: widget.ios,
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
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
