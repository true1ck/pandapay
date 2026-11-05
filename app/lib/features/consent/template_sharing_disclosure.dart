import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/consents_api.dart';

/// The strings are fixed by the release plan (Task 5.2). The body names the
/// AI provider, so it must change together with the server's provider and the
/// store declarations.
class TemplateSharingCopy {
  const TemplateSharingCopy._();

  static const title = 'Help PandaPay read new bank messages';
  static const body =
      'When PandaPay can\'t read a message, it can send a copy with every '
      'amount, name, number and date removed, so a rule can be added for '
      'everyone. These copies may be processed by Google Gemini to suggest '
      'the rule. Nothing is sent unless you turn this on, and you can turn '
      'it off at any time.';
}

/// Optional sharing of redacted message templates (consent purpose
/// `sms_shared_learning`). Off by default: it is only ever switched on by an
/// explicit "Turn on" here.
///
/// Shown as a modal sheet. Resolves to `true` only after the consent row was
/// written (`POST /consents`); "Not now" or dismissing resolves to `false`.
class TemplateSharingDisclosure extends ConsumerStatefulWidget {
  const TemplateSharingDisclosure({super.key, required this.sourceScreen});

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
      builder: (_) => TemplateSharingDisclosure(sourceScreen: sourceScreen),
    );
    return granted ?? false;
  }

  @override
  ConsumerState<TemplateSharingDisclosure> createState() =>
      _TemplateSharingDisclosureState();
}

class _TemplateSharingDisclosureState
    extends ConsumerState<TemplateSharingDisclosure> {
  bool _saving = false;

  Future<void> _turnOn() async {
    final api = ref.read(consentsApiProvider);
    if (api == null) {
      _showError('Sign in to turn this on.');
      return;
    }
    setState(() => _saving = true);
    try {
      await api.submit(
        purpose: smsSharedLearningPurpose,
        granted: true,
        // The database matches this exact string, so it is not the shared
        // policy date.
        policyVersion: smsSharedLearningPolicyVersion,
        sourceScreen: widget.sourceScreen,
      );
      ref.invalidate(smsSharedLearningConsentProvider);
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
            TemplateSharingCopy.title,
            style: BambooFonts.heading(20, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            TemplateSharingCopy.body,
            style: BambooFonts.ui(14, color: BambooInk.ink900, height: 1.45),
          ),
          const SizedBox(height: AppSpace.lg),
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
            onPressed: _saving ? null : _turnOn,
            child: Text(_saving ? 'Saving…' : 'Turn on'),
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
