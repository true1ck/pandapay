import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../settings/feedback_support_screen.dart';

/// Design 24 "Account recovery" — sends a sign-in code to the email on the
/// account (the same real AuthApi.requestEmailOtp/verifyEmailOtp path
/// LoginScreen uses, just framed for someone who's lost their phone, not
/// their email). The "lost access to both" support path is inherently a
/// human process — this app has no automated "verify via last 4
/// transactions" checker, so rather than fabricate one, it hands off to the
/// real support form (FeedbackSupportScreen) with a prefilled message that
/// tells the support team what to verify, matching the README's own framing
/// of that path.
class AccountRecoveryScreen extends ConsumerStatefulWidget {
  const AccountRecoveryScreen({super.key});

  @override
  ConsumerState<AccountRecoveryScreen> createState() => _AccountRecoveryScreenState();
}

class _AccountRecoveryScreenState extends ConsumerState<AccountRecoveryScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  bool _otpRequested = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter the email address on your account.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authApiProvider).requestEmailOtp(email);
      if (mounted) setState(() => _otpRequested = true);
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyCode() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final deviceId = await ref.read(localDeviceIdProvider.future);
      final tokens = await ref
          .read(authApiProvider)
          .verifyEmailOtp(_emailController.text.trim(), _codeController.text.trim(), deviceId);
      final store = await ref.read(tokenStoreProvider.future);
      await store.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
      ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
      await ref.read(profileApiProvider)!.ensureProfile();
      ref.invalidate(profileProvider);
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.slate,
      appBar: AppBar(
        backgroundColor: BambooInk.slate,
        foregroundColor: BambooInk.onSlate,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Account recovery', style: BambooFonts.heading(17, color: BambooInk.onSlate)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _otpRequested
                    ? 'Enter the code we sent to ${_emailController.text.trim()}'
                    : "We'll send a sign-in code to the email on your account.",
                style: BambooFonts.ui(14, color: BambooInk.onSlateMuted),
              ),
              const SizedBox(height: AppSpace.xl),
              if (!_otpRequested) ...[
                Text(
                  'Email address',
                  style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.onSlateMuted),
                ),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  style: BambooFonts.ui(15, color: BambooInk.onSlate),
                  decoration: InputDecoration(
                    hintText: 'you@example.com',
                    hintStyle: BambooFonts.ui(14, color: BambooInk.onSlateMuted),
                    prefixIcon: const Icon(Icons.mail_outline_rounded, color: BambooInk.onSlateMuted),
                    filled: true,
                    fillColor: BambooInk.slateLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.xl),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.lime,
                    foregroundColor: BambooInk.slate,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _loading ? null : _sendCode,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.slate),
                        )
                      : const Text('Send code'),
                ),
              ] else ...[
                Text(
                  'Verification code',
                  style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.onSlateMuted),
                ),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  style: BambooFonts.ui(15, color: BambooInk.onSlate),
                  decoration: InputDecoration(
                    hintText: '6-digit code',
                    hintStyle: BambooFonts.ui(14, color: BambooInk.onSlateMuted),
                    prefixIcon: const Icon(Icons.pin_outlined, color: BambooInk.onSlateMuted),
                    filled: true,
                    fillColor: BambooInk.slateLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.xl),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.lime,
                    foregroundColor: BambooInk.slate,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _loading ? null : _verifyCode,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.slate),
                        )
                      : const Text('Verify & sign in'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpace.lg),
                Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clay)),
              ],
              const Spacer(),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const FeedbackSupportScreen(
                        prefilledKind: 'general',
                        prefilledMessage:
                            "I've lost access to both the phone number and email on my account and need help recovering it. "
                            "I can verify my identity via my last 4 transactions.",
                      ),
                    ),
                  ),
                  style: TextButton.styleFrom(foregroundColor: BambooInk.onSlateMuted),
                  child: const Text("Lost access to both? Contact support"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
