import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// Whether this screen is creating a new account or signing an existing one in.
///
/// The two differ in what they collect, not in how they verify:
///   * [signUp] collects BOTH email and phone. The OTP goes to the email; the
///     phone is stored on the same account so SMS-based transaction detection
///     (UA-5.3) works from day one without a second onboarding prompt later.
///   * [logIn] collects a single identifier — either one already linked to the
///     account is enough, so returning users aren't made to retype both.
enum AuthMode { signUp, logIn }

/// Which identifier a returning user is signing in with. Sign-up has no such
/// choice: it is always email-plus-phone.
enum _SignInMethod { phone, email }

/// UA-3: OTP sign-in/sign-up against the real auth/ service.
///
/// On success this ensures a profiles row exists (api/'s POST /profile is an
/// upsert) so the "signed in" state always has something for profileProvider
/// to fetch.
class LoginScreen extends ConsumerStatefulWidget {
  final AuthMode mode;
  const LoginScreen({super.key, this.mode = AuthMode.logIn});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  /// In sign-up this is always the email. In log-in it is whichever identifier
  /// [_method] currently selects.
  final _identifierController = TextEditingController();

  /// Sign-up only — the phone we link to the account alongside the email.
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  _SignInMethod _method = _SignInMethod.phone;
  bool _otpRequested = false;
  bool _loading = false;
  String? _error;

  bool get _isSignUp => widget.mode == AuthMode.signUp;

  /// Sign-up always verifies by email; log-in follows the toggle.
  bool get _usesEmail => _isSignUp || _method == _SignInMethod.email;

  @override
  void dispose() {
    _identifierController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _switchMethod(_SignInMethod method) {
    if (method == _method) return;
    setState(() {
      _method = method;
      _identifierController.clear();
      _error = null;
    });
  }

  /// Client-side checks that mirror auth/'s own validators, so an obviously
  /// malformed entry gets an inline message instead of a round-trip and a
  /// generic server error.
  String? _validate() {
    final identifier = _identifierController.text.trim();
    if (identifier.isEmpty) {
      return _usesEmail ? 'Enter your email address.' : 'Enter your phone number.';
    }
    if (_usesEmail && !identifier.contains('@')) {
      return 'That email address doesn\'t look right.';
    }
    if (_isSignUp) {
      final phone = _phoneController.text.trim();
      if (phone.isEmpty) return 'Enter your phone number.';
      // auth/ normalises a bare 10-digit number to +91; anything else must
      // already be E.164.
      final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length < 10) return 'That phone number looks too short.';
    }
    return null;
  }

  Future<void> _requestOtp() async {
    final validationError = _validate();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final identifier = _identifierController.text.trim();
      if (_usesEmail) {
        await ref.read(authApiProvider).requestEmailOtp(identifier);
      } else {
        await ref.read(authApiProvider).requestOtp(identifier);
      }
      setState(() => _otpRequested = true);
    } catch (e) {
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyOtp() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final identifier = _identifierController.text.trim();
      final code = _codeController.text.trim();
      final authApi = ref.read(authApiProvider);

      final tokens = _usesEmail
          ? await authApi.verifyEmailOtp(
              identifier,
              code,
              'app-mobile',
              // Only sign-up has a phone to link; log-in leaves the account's
              // existing linkage untouched.
              phoneNumber: _isSignUp ? _phoneController.text.trim() : null,
            )
          : await authApi.verifyOtp(identifier, code, 'app-mobile');

      final store = await ref.read(tokenStoreProvider.future);
      await store.save(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      ref.read(accessTokenProvider.notifier).state = tokens.accessToken;

      await ref.read(profileApiProvider)!.ensureProfile();
      ref.invalidate(profileProvider);

      // This screen is also reached by being pushed (Home's "Sign in" banner),
      // where nothing else pops it once sign-in succeeds. The embedded case
      // (Cards/Activity/Account watching accessTokenProvider) has no route to
      // pop, so canPop() is false there and this is a no-op.
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _changeIdentifier() {
    setState(() {
      _otpRequested = false;
      _error = null;
      _codeController.clear();
    });
  }

  String get _title => _isSignUp ? 'Create your account' : 'Welcome back';

  String get _subtitle {
    if (_otpRequested) {
      return 'Enter the code we sent to ${_identifierController.text.trim()}';
    }
    return _isSignUp
        ? 'Track your cards, log spend, and never miss a reward.'
        : 'Sign in to pick up where you left off.';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      color: AppColors.canvas,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl, AppSpace.xxl, AppSpace.xl, AppSpace.xl),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minHeight:
                        constraints.maxHeight - AppSpace.xxl - AppSpace.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppLogoMark(),
                    const SizedBox(height: AppSpace.lg),
                    Text(_title, style: textTheme.headlineSmall),
                    const SizedBox(height: AppSpace.xs),
                    Text(_subtitle, style: textTheme.bodyMedium),
                    const SizedBox(height: AppSpace.xl),
                    if (!_otpRequested) ...[
                      // Only returning users choose an identifier; sign-up
                      // always takes both.
                      if (!_isSignUp) ...[
                        _MethodToggle(method: _method, onChanged: _switchMethod),
                        const SizedBox(height: AppSpace.lg),
                      ],
                      _IdentifierStep(
                        isSignUp: _isSignUp,
                        usesEmail: _usesEmail,
                        identifierController: _identifierController,
                        phoneController: _phoneController,
                        loading: _loading,
                        onSubmit: _requestOtp,
                      ),
                    ],
                    if (_otpRequested)
                      _OtpStep(
                        controller: _codeController,
                        loading: _loading,
                        onSubmit: _verifyOtp,
                        onChangeIdentifier: _changeIdentifier,
                        onResend: _requestOtp,
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpace.lg),
                      _ErrorBanner(message: _error!),
                    ],
                    const SizedBox(height: AppSpace.xxxl),
                    Center(
                      child: Text(
                        'By continuing you agree to PandaPay\'s Terms & Privacy Policy.',
                        style: textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MethodToggle extends StatelessWidget {
  final _SignInMethod method;
  final ValueChanged<_SignInMethod> onChanged;
  const _MethodToggle({required this.method, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Expanded(
            child: _MethodSegment(
              label: 'Phone',
              icon: Icons.phone_outlined,
              selected: method == _SignInMethod.phone,
              onTap: () => onChanged(_SignInMethod.phone),
            ),
          ),
          Expanded(
            child: _MethodSegment(
              label: 'Email',
              icon: Icons.mail_outline_rounded,
              selected: method == _SignInMethod.email,
              onTap: () => onChanged(_SignInMethod.email),
            ),
          ),
        ],
      ),
    );
  }
}

class _MethodSegment extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _MethodSegment({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        decoration: BoxDecoration(
          color: selected ? AppColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          boxShadow: selected
              ? [
                  const BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 4,
                      offset: Offset(0, 1))
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? AppColors.teal600 : AppColors.ink500),
            const SizedBox(width: AppSpace.xs),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: selected ? AppColors.navy900 : AppColors.ink500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The identifier step. In sign-up this renders TWO fields — email (which
/// receives the code) and phone (linked to the account for SMS detection). In
/// log-in it renders exactly one, matching the selected method.
class _IdentifierStep extends StatelessWidget {
  final bool isSignUp;
  final bool usesEmail;
  final TextEditingController identifierController;
  final TextEditingController phoneController;
  final bool loading;
  final VoidCallback onSubmit;

  const _IdentifierStep({
    required this.isSignUp,
    required this.usesEmail,
    required this.identifierController,
    required this.phoneController,
    required this.loading,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelLarge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(usesEmail ? 'Email address' : 'Phone number', style: labelStyle),
        const SizedBox(height: AppSpace.sm),
        TextField(
          controller: identifierController,
          keyboardType:
              usesEmail ? TextInputType.emailAddress : TextInputType.phone,
          textInputAction:
              isSignUp ? TextInputAction.next : TextInputAction.done,
          autofillHints: [
            usesEmail ? AutofillHints.email : AutofillHints.telephoneNumber
          ],
          onSubmitted: isSignUp ? null : (_) => loading ? null : onSubmit(),
          style: Theme.of(context).textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: usesEmail ? 'you@example.com' : '+91 98765 43210',
            prefixIcon: Icon(usesEmail
                ? Icons.mail_outline_rounded
                : Icons.phone_outlined),
          ),
        ),
        if (isSignUp) ...[
          const SizedBox(height: AppSpace.lg),
          Text('Phone number', style: labelStyle),
          const SizedBox(height: 2),
          Text(
            'Used to detect card transactions from your bank SMS.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.telephoneNumber],
            onSubmitted: (_) => loading ? null : onSubmit(),
            style: Theme.of(context).textTheme.bodyLarge,
            decoration: const InputDecoration(
              hintText: '+91 98765 43210',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline_rounded,
                  size: 14, color: AppColors.ink500),
              const SizedBox(width: AppSpace.xs),
              Expanded(
                child: Text(
                  'We\'ll send your verification code to your email.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpace.xl),
        FilledButton(
          onPressed: loading ? null : onSubmit,
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: Colors.white),
                )
              : const Text('Send code'),
        ),
      ],
    );
  }
}

class _OtpStep extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final VoidCallback onSubmit;
  final VoidCallback onChangeIdentifier;
  final VoidCallback onResend;

  const _OtpStep({
    required this.controller,
    required this.loading,
    required this.onSubmit,
    required this.onChangeIdentifier,
    required this.onResend,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Verification code',
            style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: AppSpace.sm),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => loading ? null : onSubmit(),
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(letterSpacing: 8),
          decoration: const InputDecoration(hintText: '••••'),
        ),
        const SizedBox(height: AppSpace.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
                onPressed: loading ? null : onChangeIdentifier,
                child: const Text('Change')),
            TextButton(
                onPressed: loading ? null : onResend,
                child: const Text('Resend code')),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        FilledButton(
          onPressed: loading ? null : onSubmit,
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: Colors.white),
                )
              : const Text('Verify & continue'),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.errorBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppColors.error, size: 20),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }
}
