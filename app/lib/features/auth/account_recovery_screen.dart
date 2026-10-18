import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../app/env.dart';
import '../../data/api_exception.dart';
import '../../data/auth_api.dart';
import '../../data/recovery_api.dart';
import '../settings/feedback_support_screen.dart';

/// Recovery accepts either verified sign-in channel. Email OTP uses the
/// existing email login path; phone OTP uses the existing phone authenticator
/// with `recovery_only` so an unknown number can never create an account.
class AccountRecoveryScreen extends ConsumerStatefulWidget {
  const AccountRecoveryScreen({super.key});

  @override
  ConsumerState<AccountRecoveryScreen> createState() =>
      _AccountRecoveryScreenState();
}

class _AccountRecoveryScreenState extends ConsumerState<AccountRecoveryScreen> {
  final _identifierController = TextEditingController();
  final _codeController = TextEditingController();
  final _replacementController = TextEditingController();
  final _codeFocus = FocusNode();
  bool _otpRequested = false;
  bool _recoveryComplete = false;
  bool _identifierIsEmail = true;
  bool _loading = false;
  int _resendSeconds = 0;
  Timer? _resendTimer;
  String? _normalizedPhone;
  String? _error;
  RecoveryStatus? _recoveryStatus;
  AuthTokens? _pendingTokens;
  bool _replacingContact = false;
  String? _replacementChallenge;
  String? _newVerifiedContact;

  @override
  void dispose() {
    _identifierController.dispose();
    _codeController.dispose();
    _replacementController.dispose();
    _codeFocus.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  void _startResendCooldown([int seconds = 120]) {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = seconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSeconds <= 1) {
        timer.cancel();
        setState(() => _resendSeconds = 0);
      } else {
        setState(() => _resendSeconds--);
      }
    });
  }

  String get _resendCountdown {
    final minutes = (_resendSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_resendSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String? _prepareIdentifier() {
    final value = _identifierController.text.trim();
    if (value.isEmpty) return 'Enter your email address or phone number.';
    _identifierIsEmail = value.contains('@');
    if (_identifierIsEmail) {
      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
        return 'That email address doesn’t look right.';
      }
      return null;
    }

    final phone = value.replaceAll(RegExp(r'[\s().-]'), '');
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10 || digits.length > 15) {
      return 'Enter a valid phone number, including its country code if needed.';
    }
    if (!phone.startsWith('+') && digits.length != 10) {
      return 'Add your country code to this phone number.';
    }
    _normalizedPhone = phone;
    return null;
  }

  Future<void> _sendCode() async {
    final validationError = _prepareIdentifier();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = ref.read(authApiProvider);
      if (_identifierIsEmail) {
        await auth.requestEmailOtp(_identifierController.text.trim());
      } else {
        await auth.requestOtp(_normalizedPhone!);
      }
      if (mounted) {
        setState(() {
          _otpRequested = true;
          _codeController.clear();
          _pendingTokens = null;
          _error = null;
        });
        _startResendCooldown();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _codeFocus.requestFocus();
        });
      }
    } catch (error) {
      final activeOtp =
          error is ApiException &&
          error.statusCode == 429 &&
          error.userMessage.toLowerCase().contains('otp') &&
          error.userMessage.toLowerCase().contains('active');
      if (mounted && activeOtp) {
        setState(() {
          _otpRequested = true;
          _error =
              'A code request is still active. Check your inbox and spam folder. If it didn’t arrive, you can request another when the timer ends.';
        });
        if (_resendSeconds == 0) _startResendCooldown();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _codeFocus.requestFocus();
        });
      } else if (mounted) {
        setState(() => _error = userFacingErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_codeController.text.trim().length != 4) {
      setState(() => _error = 'Enter the 4-digit code we sent you.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final deviceId = await ref.read(localDeviceIdProvider.future);
      final auth = ref.read(authApiProvider);
      final tokens =
          _pendingTokens ??
          (_identifierIsEmail
              ? await auth.verifyEmailOtp(
                  _identifierController.text.trim(),
                  _codeController.text.trim(),
                  deviceId,
                  recoveryOnly: true,
                )
              : await auth.verifyOtp(
                  _normalizedPhone!,
                  _codeController.text.trim(),
                  deviceId,
                  recoveryOnly: true,
                ));
      _pendingTokens = tokens;
      // Keep credentials local until the user has seen the linked contact
      // and explicitly continues. Publishing them here redirects away.
      final status = await auth
          .recoveryApiFor(tokens.accessToken)
          .fetchStatus();
      if (mounted) {
        setState(() {
          _recoveryStatus = status;
          _recoveryComplete = true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _useDifferentContact() {
    setState(() {
      _otpRequested = false;
      _pendingTokens = null;
      _codeController.clear();
      _error = null;
    });
  }

  Future<void> _continueToApp() async {
    final tokens = _pendingTokens;
    if (tokens == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ProfileApi(
        apiBaseUrl: Env.apiBaseUrl,
        accessToken: tokens.accessToken,
      ).ensureProfile(
        email: _identifierIsEmail
            ? _identifierController.text.trim()
            : _newVerifiedContact,
        phoneNumber: _identifierIsEmail
            ? _newVerifiedContact
            : _normalizedPhone,
      );
      final store = await ref.read(tokenStoreProvider.future);
      await store.save(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      if (!mounted) return;
      ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
      ref.invalidate(profileProvider);
      ref.invalidate(recoveryStatusProvider);
      if (mounted) context.go('/home');
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendReplacementCode() async {
    final value = _replacementController.text.trim();
    if (value.isEmpty) {
      setState(
        () => _error =
            'Enter your new ${_identifierIsEmail ? 'phone number' : 'email address'}.',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final challenge = await ref
          .read(authApiProvider)
          .recoveryApiFor(_pendingTokens!.accessToken)
          .requestContactReplacement(value);
      if (!mounted) return;
      setState(() {
        _replacementChallenge = challenge;
        _codeController.clear();
      });
      _startResendCooldown();
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveReplacement() async {
    if (_codeController.text.trim().length != 4) {
      setState(
        () => _error = 'Enter the 4-digit code sent to your new contact.',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref
          .read(authApiProvider)
          .recoveryApiFor(_pendingTokens!.accessToken);
      final status = await api.verifyContactReplacement(
        _replacementChallenge!,
        _codeController.text.trim(),
      );
      _newVerifiedContact = _replacementController.text.trim();
      if (mounted) {
        setState(() {
          _recoveryStatus = status;
          _replacingContact = false;
          _replacementChallenge = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _replacementForm() {
    final channel = _identifierIsEmail ? 'phone number' : 'email address';
    final hasChallenge = _replacementChallenge != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Replace your $channel',
          style: BambooFonts.heading(24, color: BambooInk.ink900),
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          hasChallenge
              ? 'Enter the code sent to ${_replacementController.text.trim()}. Your linked contact changes only after this code is verified.'
              : 'You verified the contact you can still access. Enter a new $channel, then verify the code we send there.',
          style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
        ),
        const SizedBox(height: AppSpace.xl),
        TextField(
          controller: hasChallenge ? _codeController : _replacementController,
          keyboardType: hasChallenge || _identifierIsEmail
              ? TextInputType.phone
              : TextInputType.emailAddress,
          autofillHints: hasChallenge
              ? const [AutofillHints.oneTimeCode]
              : null,
          inputFormatters: hasChallenge
              ? [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ]
              : null,
          decoration: InputDecoration(
            labelText: hasChallenge ? 'Verification code' : 'New $channel',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        _primaryButton(
          label: hasChallenge
              ? 'Verify & save contact'
              : 'Send verification code',
          loadingLabel: hasChallenge ? 'Saving…' : 'Sending…',
          onPressed: hasChallenge ? _saveReplacement : _sendReplacementCode,
        ),
        if (hasChallenge)
          TextButton(
            onPressed: _loading || _resendSeconds > 0
                ? null
                : _sendReplacementCode,
            child: Text(
              _resendSeconds > 0
                  ? 'Resend code in $_resendCountdown'
                  : 'Resend verification code',
            ),
          ),
        if (_error != null)
          Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clay)),
        TextButton(
          onPressed: _loading
              ? null
              : () => setState(() {
                  _replacingContact = false;
                  _replacementChallenge = null;
                  _error = null;
                }),
          child: const Text('Back to linked contacts'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final identifier = _identifierController.text.trim();
    final hint = _identifierIsEmail
        ? _recoveryStatus?.phoneHint
        : _recoveryStatus?.emailHint;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Find your account',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: ListView(
            children: [
              if (_recoveryComplete && _replacingContact) ...[
                _replacementForm(),
              ] else if (_recoveryComplete) ...[
                const Icon(
                  Icons.verified_rounded,
                  size: 54,
                  color: BambooInk.jade,
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'We found your account',
                  style: BambooFonts.heading(22, color: BambooInk.ink900),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  hint == null
                      ? 'You verified $identifier. No ${_identifierIsEmail ? 'phone number' : 'email address'} is linked to this account.'
                      : 'You verified $identifier. Your linked ${_identifierIsEmail ? 'phone number' : 'email address'} is:',
                  style: BambooFonts.ui(
                    14,
                    color: BambooInk.ink500,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (hint != null) ...[
                  const SizedBox(height: AppSpace.md),
                  Text(
                    hint,
                    textAlign: TextAlign.center,
                    style: BambooFonts.heading(24, color: BambooInk.ink900),
                  ),
                ],
                const SizedBox(height: AppSpace.xl),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _loading ? null : _continueToApp,
                  child: Text(_loading ? 'Signing in…' : 'Continue signing in'),
                ),
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() {
                          _replacingContact = true;
                          _replacementController.clear();
                          _replacementChallenge = null;
                          _error = null;
                        }),
                  child: Text(
                    hint == null
                        ? 'Add a ${_identifierIsEmail ? 'phone number' : 'backup email'}'
                        : 'I can’t access this ${_identifierIsEmail ? 'phone number' : 'email'}',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpace.md),
                  Text(
                    _error!,
                    style: BambooFonts.ui(13, color: BambooInk.clay),
                  ),
                ],
              ] else ...[
                Text(
                  _otpRequested
                      ? 'We requested a sign-in code for $identifier. Check your ${_identifierIsEmail ? 'inbox and spam folder' : 'text messages'}. If it doesn’t arrive, you can request another after the timer.'
                      : 'Enter the email address or phone number linked to your account. We’ll send a sign-in code if it matches.',
                  style: BambooFonts.ui(
                    14,
                    color: BambooInk.ink500,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: AppSpace.xl),
                if (!_otpRequested) ...[
                  Text(
                    'Email or phone number',
                    style: BambooFonts.ui(
                      13,
                      weight: FontWeight.w600,
                      color: BambooInk.ink700,
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextField(
                    controller: _identifierController,
                    keyboardType: TextInputType.text,
                    autofillHints: const [
                      AutofillHints.email,
                      AutofillHints.telephoneNumber,
                    ],
                    style: BambooFonts.ui(15, color: BambooInk.ink900),
                    decoration: InputDecoration(
                      hintText: 'you@example.com or +91 98765 43210',
                      hintStyle: BambooFonts.ui(13, color: BambooInk.ink500),
                      prefixIcon: const Icon(
                        Icons.alternate_email_rounded,
                        color: BambooInk.ink500,
                      ),
                      filled: true,
                      fillColor: BambooInk.glassFillOnPaper,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: BambooInk.hairlineOnPaper,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: BambooInk.hairlineOnPaper,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.xl),
                  _primaryButton(
                    label: 'Send sign-in code',
                    loadingLabel: 'Sending…',
                    onPressed: _sendCode,
                  ),
                ] else ...[
                  Text(
                    'Verification code',
                    style: BambooFonts.ui(
                      13,
                      weight: FontWeight.w600,
                      color: BambooInk.ink700,
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextField(
                    controller: _codeController,
                    focusNode: _codeFocus,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    onSubmitted: (_) => _loading ? null : _verifyCode(),
                    style: BambooFonts.ui(15, color: BambooInk.ink900),
                    decoration: InputDecoration(
                      hintText: '4-digit code',
                      hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
                      prefixIcon: const Icon(
                        Icons.pin_outlined,
                        color: BambooInk.ink500,
                      ),
                      filled: true,
                      fillColor: BambooInk.glassFillOnPaper,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: BambooInk.hairlineOnPaper,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: BambooInk.hairlineOnPaper,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.xl),
                  _primaryButton(
                    label: _pendingTokens == null
                        ? 'Verify code'
                        : 'Show linked contact',
                    loadingLabel: 'Checking…',
                    onPressed: _verifyCode,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Center(
                    child: TextButton(
                      onPressed: _loading || _resendSeconds > 0
                          ? null
                          : _sendCode,
                      child: Text(
                        _resendSeconds > 0
                            ? 'Resend code in $_resendCountdown'
                            : 'Didn’t get the code? Resend code',
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _loading ? null : _useDifferentContact,
                      child: const Text('Use a different email or phone'),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: AppSpace.md),
                  Text(
                    _error!,
                    style: BambooFonts.ui(13, color: BambooInk.clay),
                  ),
                ],
                const SizedBox(height: AppSpace.xxl),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const FeedbackSupportScreen(
                          prefilledKind: 'general',
                          prefilledMessage:
                              'I have lost access to both the email and phone number linked to my PandaPay account. Please guide me through your secure account recovery process.',
                        ),
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: BambooInk.ink500,
                    ),
                    child: const Text('Lost access to both? Contact support'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required String loadingLabel,
    required VoidCallback onPressed,
  }) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: BambooInk.slate,
        foregroundColor: BambooInk.lime,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: _loading ? null : onPressed,
      child: _loading
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: BambooInk.lime,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Text(loadingLabel),
              ],
            )
          : Text(label),
    );
  }
}
