import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../settings/feedback_support_screen.dart';

/// A4: DPDP §8.2 — purpose-specific, unbundled consent, never a single
/// bundled "I agree to everything" checkbox. Bumped by hand whenever the
/// Terms/Privacy copy actually changes; every consent row this screen
/// writes is tagged with whichever version was current at sign-up time.
const currentPolicyVersion = '2026-08-07';

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

  /// A4's three purpose-specific checkboxes — sign-up only. [_acceptedTerms]
  /// is required (gates submit); the other two default OFF and are optional.
  bool _acceptedTerms = false;
  bool _optInCrowdsource = false;
  bool _optInMarketing = false;

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
      if (!_acceptedTerms) return 'You need to accept the Terms & Privacy Policy to continue.';
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

      // A4: record the three purpose-specific consents now that a profile
      // row exists to attach them to. Each POST /consents call inserts its
      // own audit-log row (see ConsentsApi's doc-comment) — never skipped
      // for "required", since even a required grant needs its own
      // timestamped record per DPDP §8.2.
      if (_isSignUp) {
        final consentsApi = ref.read(consentsApiProvider)!;
        await consentsApi.submit(
          purpose: 'terms',
          granted: _acceptedTerms,
          policyVersion: currentPolicyVersion,
          sourceScreen: 'A4',
        );
        await consentsApi.submit(
          purpose: 'crowdsource',
          granted: _optInCrowdsource,
          policyVersion: currentPolicyVersion,
          sourceScreen: 'A4',
        );
        await consentsApi.submit(
          purpose: 'marketing',
          granted: _optInMarketing,
          policyVersion: currentPolicyVersion,
          sourceScreen: 'A4',
        );
        // Mirrors E12/H4's actual toggle — profiles.contributions_opt_in is
        // the live flag other screens read, not the consent log itself.
        if (_optInCrowdsource) {
          await ref.read(userCardsRepositoryProvider)!.setContributionsOptIn(true);
        }
      }
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
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
        ),
      ),
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
                    Container(
                      width: 64,
                      height: 64,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: BambooInk.paper, borderRadius: BorderRadius.circular(20)),
                      child: const PandaMark(size: 48),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    Text(_title, style: BambooFonts.heading(24, color: BambooInk.onSlate)),
                    const SizedBox(height: AppSpace.xs),
                    Text(_subtitle, style: BambooFonts.ui(14, color: BambooInk.onSlateMuted)),
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
                        acceptedTerms: _acceptedTerms,
                        optInCrowdsource: _optInCrowdsource,
                        optInMarketing: _optInMarketing,
                        onAcceptedTermsChanged: (v) => setState(() => _acceptedTerms = v),
                        onOptInCrowdsourceChanged: (v) => setState(() => _optInCrowdsource = v),
                        onOptInMarketingChanged: (v) => setState(() => _optInMarketing = v),
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
                    const SizedBox(height: AppSpace.xl),
                    // G4's "zero login" requirement in practice: AccountScreen
                    // (this widget's usual host) shows LoginScreen instead of
                    // its Tools list whenever signed out, so without this link
                    // Emergency Card Info would be unreachable from the tab
                    // it's otherwise discoverable from pre-sign-in. Lost-card
                    // help has to work for someone who's never made an
                    // account at all, not just someone temporarily signed out.
                    Center(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: BambooInk.onSlateMuted),
                        onPressed: () => context.push(AppRoute.emergencyCardInfo),
                        icon: const Icon(Icons.emergency_outlined, size: 16),
                        label: const Text('Lost or stolen card? Get emergency help — no sign-in needed'),
                      ),
                    ),
                    // A4: the bundled "by continuing you agree..." footer is
                    // gone for sign-up — the three checkboxes in
                    // _IdentifierStep are the real, unbundled consent now.
                    // Log-in has no new consent to collect (the account
                    // already has one on file from its own sign-up), so it
                    // keeps a short reference line instead.
                    if (!_isSignUp) ...[
                      const SizedBox(height: AppSpace.md),
                      Center(
                        child: Text(
                          'By continuing you agree to PandaPay\'s Terms & Privacy Policy.',
                          style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
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
        color: BambooInk.slateLow,
        borderRadius: BorderRadius.circular(16),
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
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        decoration: BoxDecoration(
          color: selected ? BambooInk.slate : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? BambooInk.lime : BambooInk.onSlateMuted),
            const SizedBox(width: AppSpace.xs),
            Text(
              label,
              style: BambooFonts.ui(
                13.5,
                weight: FontWeight.w600,
                color: selected ? BambooInk.onSlate : BambooInk.onSlateMuted,
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

  /// A4 — sign-up only. See _LoginScreenState's own fields for what each
  /// means; this widget just renders/reports them, LoginScreen owns state.
  final bool acceptedTerms;
  final bool optInCrowdsource;
  final bool optInMarketing;
  final ValueChanged<bool> onAcceptedTermsChanged;
  final ValueChanged<bool> onOptInCrowdsourceChanged;
  final ValueChanged<bool> onOptInMarketingChanged;

  const _IdentifierStep({
    required this.isSignUp,
    required this.usesEmail,
    required this.identifierController,
    required this.phoneController,
    required this.loading,
    required this.onSubmit,
    required this.acceptedTerms,
    required this.optInCrowdsource,
    required this.optInMarketing,
    required this.onAcceptedTermsChanged,
    required this.onOptInCrowdsourceChanged,
    required this.onOptInMarketingChanged,
  });

  static InputDecoration _fieldDecoration({required String hint, required IconData icon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: BambooFonts.ui(14, color: BambooInk.onSlateMuted),
      prefixIcon: Icon(icon, color: BambooInk.onSlateMuted),
      filled: true,
      fillColor: BambooInk.slateLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: BambooInk.slateHairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: BambooInk.lime, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labelStyle = BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.onSlateMuted);
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
          style: BambooFonts.ui(15, color: BambooInk.onSlate),
          decoration: _fieldDecoration(
            hint: usesEmail ? 'you@example.com' : '+91 98765 43210',
            icon: usesEmail ? Icons.mail_outline_rounded : Icons.phone_outlined,
          ),
        ),
        if (isSignUp) ...[
          const SizedBox(height: AppSpace.lg),
          Text('Phone number', style: labelStyle),
          const SizedBox(height: 2),
          Text(
            'Used to detect card transactions from your bank SMS.',
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.telephoneNumber],
            onSubmitted: (_) => loading ? null : onSubmit(),
            style: BambooFonts.ui(15, color: BambooInk.onSlate),
            decoration: _fieldDecoration(hint: '+91 98765 43210', icon: Icons.phone_outlined),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline_rounded,
                  size: 14, color: BambooInk.onSlateMuted),
              const SizedBox(width: AppSpace.xs),
              Expanded(
                child: Text(
                  'We\'ll send your verification code to your email.',
                  style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          // A4: three separate, purpose-specific checkboxes — DPDP §8.2
          // forbids bundling these into one "I agree" tick. Only the first
          // is required; the other two are optional and default off.
          _ConsentCheckbox(
            value: acceptedTerms,
            onChanged: onAcceptedTermsChanged,
            label: "I accept PandaPay's Terms & Privacy Policy",
            required: true,
          ),
          _ConsentCheckbox(
            value: optInCrowdsource,
            onChanged: onOptInCrowdsourceChanged,
            label: 'Contribute anonymized merchant data to improve the app',
          ),
          _ConsentCheckbox(
            value: optInMarketing,
            onChanged: onOptInMarketingChanged,
            label: 'Send me product update emails',
          ),
        ],
        const SizedBox(height: AppSpace.xl),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: BambooInk.lime,
            foregroundColor: BambooInk.slate,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
          ),
          onPressed: loading ? null : onSubmit,
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: BambooInk.slate),
                )
              : const Text('Send code'),
        ),
      ],
    );
  }
}

class _ConsentCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;
  final bool required;

  const _ConsentCheckbox({
    required this.value,
    required this.onChanged,
    required this.label,
    this.required = false,
  });

  @override
  Widget build(BuildContext context) {
    // Explicit Material ancestor: CheckboxListTile paints its background/ink
    // on the nearest Material, and this widget sits inside a plain Column
    // with no Material of its own between it and any coloured ancestor —
    // caught by Flutter's own debug assertion under widget testing, same
    // class of bug as the ListTile fix elsewhere in this codebase's H7 work.
    return Material(
      color: Colors.transparent,
      child: CheckboxListTile(
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
        activeColor: BambooInk.lime,
        checkColor: BambooInk.slate,
        side: const BorderSide(color: BambooInk.slateHairline),
        title: Text(
          required ? '$label (required)' : '$label (optional)',
          style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
        ),
      ),
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
            style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.onSlateMuted)),
        const SizedBox(height: AppSpace.sm),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => loading ? null : onSubmit(),
          textAlign: TextAlign.center,
          style: BambooFonts.money(28, color: BambooInk.onSlate, letterSpacing: 8),
          decoration: InputDecoration(
            hintText: '••••',
            hintStyle: BambooFonts.money(28, color: BambooInk.onSlateMuted, letterSpacing: 8),
            filled: true,
            fillColor: BambooInk.slateLow,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: BambooInk.slateHairline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: BambooInk.lime, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
                style: TextButton.styleFrom(foregroundColor: BambooInk.onSlateMuted),
                onPressed: loading ? null : onChangeIdentifier,
                child: const Text('Change')),
            TextButton(
                style: TextButton.styleFrom(foregroundColor: BambooInk.lime),
                onPressed: loading ? null : onResend,
                child: const Text('Resend code')),
          ],
        ),
        // A6: this app is OTP-only (no password ever exists — see
        // login_screen.dart's own top-of-file doc comment), so there is no
        // password-reset screen to build. This is the real, functional
        // equivalent the spec's "clear re-request path" asks for: a dead
        // end (code never arrives) gets a route to a human, not a fake
        // password flow bolted onto a system that doesn't have one.
        Center(
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: BambooInk.onSlateMuted),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const FeedbackSupportScreen(
                  prefilledKind: 'general',
                  prefilledMessage: "I'm not receiving my OTP code.",
                ),
              ),
            ),
            child: const Text('Trouble receiving it?'),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: BambooInk.lime,
            foregroundColor: BambooInk.slate,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
          ),
          onPressed: loading ? null : onSubmit,
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: BambooInk.slate),
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
        color: BambooInk.clay.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.clay.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: BambooInk.clay, size: 20),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              message,
              style: BambooFonts.ui(13, color: BambooInk.onSlate),
            ),
          ),
        ],
      ),
    );
  }
}
