import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../settings/feedback_support_screen.dart';
import 'account_sign_out_dialog.dart';
import 'account_sign_out_provider.dart';
import 'phone_gate_provider.dart';
import 'phone_input.dart';

/// Shown when the server's phone lock is on and this account has no phone yet.
/// The number is typed in, not verified: nothing is sent to it. It is saved on the
/// account and one number can belong to one account only.
class AddPhoneScreen extends ConsumerStatefulWidget {
  const AddPhoneScreen({super.key});

  @override
  ConsumerState<AddPhoneScreen> createState() => _AddPhoneScreenState();
}

class _AddPhoneScreenState extends ConsumerState<AddPhoneScreen> {
  final _controller = TextEditingController();
  bool _saving = false;
  String? _error;
  String? _errorCode;

  @override
  void initState() {
    super.initState();
    final gate = ref.read(phoneGateProvider);
    if (gate.prefill != null) _controller.text = gate.prefill!;
    _error = gate.message;
    if (gate.message != null) _errorCode = 'phone_unavailable';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = indianMobileError(_controller.text);
    if (problem != null) {
      setState(() {
        _error = problem;
        _errorCode = 'phone_invalid';
      });
      return;
    }
    final token = ref.read(accessTokenProvider);
    if (token == null) return;
    setState(() {
      _saving = true;
      _error = null;
      _errorCode = null;
    });
    try {
      await ref
          .read(authApiProvider)
          .phoneApiFor(token, client: ref.read(authenticatedHttpClientProvider))
          .claim(indianMobileDigits(_controller.text)!);
      // Closing the gate lets the router move on; profile is read again from there.
      ref.invalidate(profileProvider);
      ref.read(phoneGateProvider.notifier).satisfied();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingErrorMessage(error);
        _errorCode = error is ApiException ? error.errorCode : null;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _openSupport() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const FeedbackSupportScreen(
          prefilledKind: 'general',
          prefilledMessage:
              'PandaPay says my phone number cannot be used, but it is mine. '
              'Please help me add it to my account.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final blockedNumber = _errorCode == 'phone_unavailable';
    return Scaffold(
      backgroundColor: BambooInk.paper,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.xl),
          children: [
            const SizedBox(height: AppSpace.xl),
            Text(
              'Add your phone number',
              style: BambooFonts.heading(26, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              'Each PandaPay account is tied to one mobile number. We won’t text '
              'you or share it. You can change it later from Edit profile, '
              'with a code sent to your email.',
              style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
            ),
            const SizedBox(height: AppSpace.xl),
            TextField(
              controller: _controller,
              enabled: !_saving,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.telephoneNumber],
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 +().-]')),
                LengthLimitingTextInputFormatter(20),
              ],
              onSubmitted: (_) => _saving ? null : _save(),
              style: BambooFonts.ui(16, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Mobile number',
                prefixText: '+91  ',
                errorText: _error,
                errorMaxLines: 4,
                border: const OutlineInputBorder(),
              ),
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
              ),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save number'),
            ),
            if (blockedNumber) ...[
              const SizedBox(height: AppSpace.sm),
              TextButton(
                onPressed: _openSupport,
                child: const Text('It’s my number. Contact support'),
              ),
            ],
            const SizedBox(height: AppSpace.xl),
            Center(
              child: TextButton(
                onPressed: _saving
                    ? null
                    : () => confirmAndSignOut(
                        context,
                        ref.read(accountSignOutProvider),
                      ),
                style: TextButton.styleFrom(foregroundColor: BambooInk.ink500),
                child: const Text('Use a different email'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
