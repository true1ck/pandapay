import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/consents_api.dart';

/// The strings are fixed by the learning-loop plan (L1, Task A2). The footer
/// names the AI provider, so it must change together with the server's
/// provider, the privacy policy (section 5) and the store declarations.
class TemplateSharingCopy {
  const TemplateSharingCopy._();

  static const title = 'Help PandaPay get better for everyone';
  static const intro = 'If you turn this on, PandaPay shares:';
  static const bullets = <String>[
    'the layout of bank messages it can\'t read, with every amount, name, '
        'number and date removed',
    'the shop names it couldn\'t put in a category, and the categories and '
        'shop names you pick for shops',
  ];
  static const footer =
      'It never shares your messages, amounts, account numbers or the people '
      'you pay. Google Gemini may process message layouts and shop names to '
      'suggest new rules. Nothing is shared unless you turn this on. If you '
      'turn it off, what you shared is deleted. Rules already added for '
      'everyone stay, and they contain nothing about you.';

  /// One-paragraph form for the Settings tile, which opens the full sheet.
  static const summary =
      'Share anonymised message layouts and the categories and shop names you '
      'pick, so a rule can be added for everyone. Off unless you turn it on.';
}

/// Optional shared learning: message layouts, shop categories and shop names (consent purpose
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
            TemplateSharingCopy.intro,
            style: BambooFonts.ui(14, color: BambooInk.ink900, height: 1.45),
          ),
          const SizedBox(height: AppSpace.xs),
          for (final bullet in TemplateSharingCopy.bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•  ',
                    style: BambooFonts.ui(14, color: BambooInk.ink900),
                  ),
                  Expanded(
                    child: Text(
                      bullet,
                      style: BambooFonts.ui(
                        14,
                        color: BambooInk.ink900,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpace.xs),
          Text(
            TemplateSharingCopy.footer,
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
