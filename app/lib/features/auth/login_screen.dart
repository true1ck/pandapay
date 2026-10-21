import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../onboarding/entry_brand.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/phone_number_hint.dart';
import '../../data/product_access_api.dart';
import '../settings/feedback_support_screen.dart';
import '../settings/legal_screen.dart';
import 'account_recovery_screen.dart';

/// A4: DPDP §8.2 — purpose-specific, unbundled consent, never a single
/// bundled "I agree to everything" checkbox. Bumped by hand whenever the
/// Terms/Privacy copy actually changes; every consent row this screen
/// writes is tagged with whichever version was current at sign-up time.
const currentPolicyVersion = appProductTermsVersion;

/// Whether this screen is creating a new account or signing an existing one in.
///
/// Both modes collect the same two fields — email and phone — and verify the
/// same way: an OTP to the email. Design 06 is explicit that these are two
/// separate required fields, never an either/or toggle, so a returning user
/// isn't left implying one substitutes for the other. The two modes differ
/// only in what happens with the phone number once OTP verification
/// succeeds: [signUp] links it to the new account; [logIn] uses the existing
/// email OTP session and leaves the account's stored phone linkage untouched.
/// This preserves sign-in for older accounts whose stored phone may be in a
/// legacy format while still collecting the phone field on the form.
enum AuthMode { signUp, logIn }

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
  /// The email — both modes verify by email OTP, so this is always the
  /// email field regardless of mode.
  final _identifierController = TextEditingController();

  /// Both modes collect this now (design 06). Sign-up links it to the new
  /// account; log-in validates its form locally but does not rewrite the
  /// account's existing phone linkage.
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _phoneFocusNode = FocusNode();

  bool _otpRequested = false;
  bool _loading = false;
  String? _error;
  bool _autoPhoneHintRequested = false;

  /// A4's three purpose-specific checkboxes — sign-up only. [_acceptedTerms]
  /// is required (gates submit); the other two default OFF and are optional.
  bool _acceptedTerms = false;
  bool _optInCrowdsource = false;
  bool _optInMarketing = false;

  bool get _isSignUp => widget.mode == AuthMode.signUp;

  @override
  void initState() {
    super.initState();
    _phoneFocusNode.addListener(_onPhoneFocusChanged);
  }

  void _onPhoneFocusChanged() {
    if (_phoneFocusNode.hasFocus &&
        _phoneController.text.trim().isEmpty &&
        !_autoPhoneHintRequested) {
      _autoPhoneHintRequested = true;
      _requestPhoneNumberHint();
    }
  }

  Future<void> _requestPhoneNumberHint() async {
    final phoneNumber = await PhoneNumberHint.request();
    if (!mounted || phoneNumber == null || phoneNumber.trim().isEmpty) return;
    final trimmed = phoneNumber.trim();
    _phoneController.value = TextEditingValue(
      text: trimmed,
      selection: TextSelection.collapsed(offset: trimmed.length),
    );
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _identifierController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    _phoneFocusNode
      ..removeListener(_onPhoneFocusChanged)
      ..dispose();
    super.dispose();
  }

  /// Client-side checks that mirror auth/'s own validators, so an obviously
  /// malformed entry gets an inline message instead of a round-trip and a
  /// generic server error.
  String? _validate() {
    final identifier = _identifierController.text.trim();
    if (identifier.isEmpty) {
      return 'Enter your email address.';
    }
    if (!identifier.contains('@')) {
      return 'That email address doesn\'t look right.';
    }
    // Design 06: email and phone are both mandatory in every mode, never an
    // either/or — see AuthMode's doc comment for what log-in does (and
    // doesn't) do with this once it's collected.
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) return 'Enter your phone number.';
    // auth/ normalises a bare 10-digit number to +91; anything else must
    // already be E.164.
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 10) return 'That phone number looks too short.';
    if (_isSignUp) {
      if (!_acceptedTerms) {
        return 'You need to accept the Terms & Privacy Policy to continue.';
      }
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
      await ref
          .read(authApiProvider)
          .requestEmailOtp(
            identifier,
            isSignUp: _isSignUp,
            phoneNumber: _isSignUp ? _phoneController.text.trim() : null,
          );
      setState(() => _otpRequested = true);
    } catch (e) {
      // The auth service deliberately rejects a second request while the
      // first code is still valid. That is not a dead end: the code already
      // in the user's inbox is the one they should enter. Move straight to
      // the verification step instead of leaving them on a form whose only
      // action is guaranteed to fail again.
      final activeOtp =
          e is ApiException &&
          e.statusCode == 429 &&
          e.userMessage.toLowerCase().contains('otp') &&
          e.userMessage.toLowerCase().contains('active');
      if (activeOtp) {
        setState(() {
          _otpRequested = true;
          _error = 'A code was already sent. Enter that code below.';
        });
      } else {
        setState(() => _error = userFacingErrorMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _verifyOtp() async {
    if (_codeController.text.trim().length != 4) {
      setState(() => _error = 'Enter the 4-digit code from your email.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final identifier = _identifierController.text.trim();
      final code = _codeController.text.trim();
      final authApi = ref.read(authApiProvider);
      final deviceId = await ref.read(localDeviceIdProvider.future);
      final deviceInfo = await ref.read(deviceMetadataProvider.future);

      final tokens = await authApi.verifyEmailOtp(
        identifier,
        code,
        deviceId,
        deviceInfo: deviceInfo,
        // Only sign-up links the phone. Returning-user login is authorized by
        // the email OTP and keeps the existing account linkage unchanged.
        phoneNumber: _isSignUp ? _phoneController.text.trim() : null,
      );

      // Keep the explicit A4 choices through the OTP -> server activation
      // handoff, including a process restart. Sign-in does not create or
      // overwrite these sign-up choices.
      if (_isSignUp) {
        await ref
            .read(pendingSignupChoicesStoreProvider.future)
            .then(
              (store) => store.save(
                PendingSignupChoices(
                  acceptProductTerms: _acceptedTerms,
                  productTermsVersion: currentPolicyVersion,
                  optInCrowdsource: _optInCrowdsource,
                  optInMarketing: _optInMarketing,
                ),
              ),
            );
      }

      final store = await ref.read(tokenStoreProvider.future);
      await store.save(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      ref.read(accessTokenProvider.notifier).state = tokens.accessToken;

      // Keep returning-user sign-in on its existing path. New sign-ups must
      // pass the product-access gate before POST /profile creates a profile.
      if (!_isSignUp) {
        await ref.read(profileApiProvider)!.ensureProfile(email: identifier);
        ref.invalidate(profileProvider);
      }

      // This screen is also reached by being pushed (Home's "Sign in" banner),
      // where nothing else pops it once sign-in succeeds. The embedded case
      // (Cards/Activity/Account watching accessTokenProvider) has no route to
      // pop, so canPop() is false there and this is a no-op.
      if (!_isSignUp && mounted && Navigator.of(context).canPop()) {
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

  String get _title => _otpRequested
      ? 'Check your email'
      : _isSignUp
      ? 'Start saving\non every spend'
      : 'Welcome back';

  @override
  Widget build(BuildContext context) => EntryBackdrop(
    waves: !_isSignUp || _otpRequested,
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 32,
                  ),
                  child: _AccountFormHeight(
                    fill: !_isSignUp || _otpRequested,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: 'Back',
                              onPressed: _loading
                                  ? null
                                  : () {
                                      if (_otpRequested) {
                                        _changeIdentifier();
                                      } else if (context.canPop()) {
                                        context.pop();
                                      }
                                    },
                              icon: const Icon(Icons.arrow_back_rounded),
                              color: BambooInk.ink900,
                              padding: EdgeInsets.zero,
                              alignment: Alignment.centerLeft,
                            ),
                            const Spacer(),
                            const PandaWordmark(size: 18),
                          ],
                        ),
                        if (_otpRequested) ...[
                          const SizedBox(height: 8),
                          Center(
                            child: PandaIllustration(
                              asset: 'assets/illustrations/panda_mail.png',
                              size: constraints.maxHeight < 680 ? 126 : 164,
                            ),
                          ),
                          const SizedBox(height: 20),
                        ] else
                          const SizedBox(height: 26),
                        Text(
                          _title,
                          textAlign: _otpRequested
                              ? TextAlign.center
                              : TextAlign.left,
                          style: BambooFonts.heading(
                            _otpRequested ? 34 : 36,
                            weight: FontWeight.w800,
                            height: 1.06,
                            letterSpacing: -1.3,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _otpRequested
                              ? 'Enter the 4-digit verification code sent to'
                              : _isSignUp
                              ? 'Create your PandaPay account.'
                              : 'Sign in to your PandaPay account.',
                          textAlign: _otpRequested
                              ? TextAlign.center
                              : TextAlign.left,
                          style: BambooFonts.ui(
                            15,
                            color: BambooInk.ink700,
                            height: 1.4,
                          ),
                        ),
                        if (_otpRequested) ...[
                          const SizedBox(height: 6),
                          Text(
                            _identifierController.text.trim(),
                            textAlign: TextAlign.center,
                            style: BambooFonts.ui(15, weight: FontWeight.w600),
                          ),
                        ],
                        SizedBox(height: _otpRequested ? 28 : 34),
                        if (!_otpRequested)
                          _IdentifierStep(
                            isSignUp: _isSignUp,
                            minHeight:
                                _isSignUp &&
                                    MediaQuery.textScalerOf(context).scale(1) <=
                                        1.2 &&
                                    constraints.maxHeight > 300
                                ? constraints.maxHeight - 300
                                : 0,
                            identifierController: _identifierController,
                            phoneController: _phoneController,
                            phoneFocusNode: _phoneFocusNode,
                            loading: _loading,
                            onSubmit: _requestOtp,
                            onRequestPhoneHint: _requestPhoneNumberHint,
                            acceptedTerms: _acceptedTerms,
                            optInCrowdsource: _optInCrowdsource,
                            optInMarketing: _optInMarketing,
                            onAcceptedTermsChanged: (v) =>
                                setState(() => _acceptedTerms = v),
                            onOptInCrowdsourceChanged: (v) =>
                                setState(() => _optInCrowdsource = v),
                            onOptInMarketingChanged: (v) =>
                                setState(() => _optInMarketing = v),
                          )
                        else
                          _OtpStep(
                            controller: _codeController,
                            loading: _loading,
                            onSubmit: _verifyOtp,
                            onChangeIdentifier: _changeIdentifier,
                            onResend: _requestOtp,
                          ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          _ErrorBanner(message: _error!),
                        ],
                        if (!_isSignUp && !_otpRequested) ...[
                          const SizedBox(height: 14),
                          Center(
                            child: TextButton(
                              onPressed: () async {
                                final resetFields = await Navigator.of(context)
                                    .push<bool>(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const AccountRecoveryScreen(),
                                      ),
                                    );
                                if (!mounted || resetFields != true) return;
                                setState(() {
                                  _identifierController.clear();
                                  _phoneController.clear();
                                  _codeController.clear();
                                  _otpRequested = false;
                                  _error = null;
                                });
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: BambooInk.ink700,
                              ),
                              child: Text(
                                'Need help signing in?',
                                style:
                                    BambooFonts.ui(
                                      13,
                                      color: BambooInk.ink700,
                                    ).copyWith(
                                      decoration: TextDecoration.underline,
                                    ),
                              ),
                            ),
                          ),
                          const Spacer(),
                          const SizedBox(height: 22),
                          const Align(
                            alignment: Alignment.bottomRight,
                            child: PandaIllustration(
                              asset: 'assets/illustrations/panda_peek.png',
                              size: 190,
                              halo: false,
                            ),
                          ),
                        ],
                        if (_isSignUp && !_otpRequested) ...[
                          const SizedBox(height: 8),
                          Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const LegalScreen(),
                                ),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: BambooInk.ink700,
                              ),
                              child: const Text(
                                'Read our terms & privacy policy',
                              ),
                            ),
                          ),
                        ],
                        if (_otpRequested) ...[
                          const Spacer(),
                          const SizedBox(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.lock_outline_rounded,
                                size: 14,
                                color: BambooInk.jade,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'A small step. A safer account.',
                                  textAlign: TextAlign.center,
                                  style: BambooFonts.ui(
                                    12,
                                    color: BambooInk.ink700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Only the short sign-in/OTP forms need to fill the viewport. The long
/// consent form measures naturally, including wrapped accessibility text.
class _AccountFormHeight extends StatelessWidget {
  final bool fill;
  final Widget child;
  const _AccountFormHeight({required this.fill, required this.child});

  @override
  Widget build(BuildContext context) =>
      fill ? IntrinsicHeight(child: child) : child;
}

/// The identifier step — design 06: always TWO required fields, email (which
/// receives the code) and phone, never a toggle between them. Sign-up links
/// the phone; returning-user login uses the email OTP without changing linkage.
class _IdentifierStep extends StatelessWidget {
  final bool isSignUp;
  final double minHeight;
  final TextEditingController identifierController;
  final TextEditingController phoneController;
  final FocusNode phoneFocusNode;
  final bool loading;
  final VoidCallback onSubmit;
  final VoidCallback onRequestPhoneHint;

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
    this.minHeight = 0,
    required this.identifierController,
    required this.phoneController,
    required this.phoneFocusNode,
    required this.loading,
    required this.onSubmit,
    required this.onRequestPhoneHint,
    required this.acceptedTerms,
    required this.optInCrowdsource,
    required this.optInMarketing,
    required this.onAcceptedTermsChanged,
    required this.onOptInCrowdsourceChanged,
    required this.onOptInMarketingChanged,
  });

  InputDecoration _fieldDecoration({
    required String hint,
    required IconData icon,
  }) => InputDecoration(
    hintText: hint,
    hintStyle: BambooFonts.ui(15, color: BambooInk.ink500),
    prefixIcon: Icon(icon, size: 21, color: BambooInk.ink900),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    filled: true,
    fillColor: Colors.white.withValues(alpha: .85),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xFFDDE1E3)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: BambooInk.jade, width: 1.5),
    ),
  );

  @override
  Widget build(BuildContext context) => AutofillGroup(
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: identifierController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                onSubmitted: (_) => phoneFocusNode.requestFocus(),
                style: BambooFonts.ui(15),
                decoration: _fieldDecoration(
                  hint: 'Email address',
                  icon: Icons.mail_outline_rounded,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneController,
                focusNode: phoneFocusNode,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.telephoneNumber],
                onSubmitted: (_) => loading ? null : onSubmit(),
                style: BambooFonts.ui(15),
                decoration:
                    _fieldDecoration(
                      hint: 'Phone number',
                      icon: Icons.phone_outlined,
                    ).copyWith(
                      suffixIcon: IconButton(
                        tooltip: 'Use a saved phone number',
                        onPressed: onRequestPhoneHint,
                        icon: const Icon(
                          Icons.expand_more_rounded,
                          size: 19,
                          color: BambooInk.ink700,
                        ),
                      ),
                    ),
              ),
              if (isSignUp) ...[
                const SizedBox(height: 20),
                _ConsentCheckbox(
                  value: acceptedTerms,
                  onChanged: onAcceptedTermsChanged,
                  label: 'I agree to the Terms & Privacy Policy',
                  subtitle: 'Required to create an account.',
                ),
                _ConsentCheckbox(
                  value: optInCrowdsource,
                  onChanged: onOptInCrowdsourceChanged,
                  label: 'Help improve PandaPay',
                  subtitle: 'Share anonymized merchant data. Optional.',
                ),
                _ConsentCheckbox(
                  value: optInMarketing,
                  onChanged: onOptInMarketingChanged,
                  label: 'Send me product updates and saving tips',
                  subtitle: 'Optional. You can change this anytime.',
                ),
              ] else ...[
                const SizedBox(height: 10),
                Text(
                  'We’ll send your sign-in code to your email.',
                  style: BambooFonts.ui(12, color: BambooInk.ink700),
                ),
              ],
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: EntryButton(
              label: isSignUp ? 'Send verification code' : 'Send code',
              onPressed: onSubmit,
              loading: loading,
            ),
          ),
        ],
      ),
    ),
  );
}

class _ConsentCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;
  final String subtitle;

  const _ConsentCheckbox({
    required this.value,
    required this.onChanged,
    required this.label,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: CheckboxListTile(
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      visualDensity: const VisualDensity(horizontal: -4, vertical: -2),
      checkboxShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
      ),
      activeColor: const Color(0xFFB0E34D),
      checkColor: BambooInk.slate,
      side: const BorderSide(color: Color(0xFFACB2B6), width: 1.5),
      title: Text(
        label,
        style: BambooFonts.ui(13, weight: FontWeight.w500, height: 1.3),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          subtitle,
          style: BambooFonts.ui(11.5, color: BambooInk.ink700, height: 1.3),
        ),
      ),
    ),
  );
}

class _OtpStep extends StatefulWidget {
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
  State<_OtpStep> createState() => _OtpStepState();
}

class _OtpStepState extends State<_OtpStep> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() => setState(() {});

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Verification code',
        textAlign: TextAlign.center,
        style: BambooFonts.ui(13, weight: FontWeight.w600),
      ),
      const SizedBox(height: 14),
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 310),
          child: SizedBox(
            height: 64,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  enabled: !widget.loading,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  onSubmitted: (_) => widget.loading ? null : widget.onSubmit(),
                  showCursor: false,
                  enableInteractiveSelection: false,
                  style: const TextStyle(
                    color: Colors.transparent,
                    fontSize: 1,
                  ),
                  decoration: const InputDecoration(
                    labelText: '4-digit verification code',
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    labelStyle: TextStyle(
                      color: Colors.transparent,
                      fontSize: 1,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                  ),
                ),
                IgnorePointer(
                  child: ExcludeSemantics(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: widget.controller,
                      builder: (context, value, _) => Row(
                        children: [
                          for (var i = 0; i < 4; i++) ...[
                            if (i > 0) const SizedBox(width: 12),
                            Expanded(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(15),
                                  border: Border.all(
                                    color:
                                        _focus.hasFocus &&
                                            i == value.text.length.clamp(0, 3)
                                        ? BambooInk.jade
                                        : const Color(0xFFDDE1E3),
                                    width:
                                        _focus.hasFocus &&
                                            i == value.text.length.clamp(0, 3)
                                        ? 1.6
                                        : 1,
                                  ),
                                ),
                                child: Text(
                                  i < value.text.length ? value.text[i] : '–',
                                  style: BambooFonts.heading(
                                    28,
                                    weight: FontWeight.w600,
                                    color: i < value.text.length
                                        ? BambooInk.ink900
                                        : const Color(0xFFCDD1CE),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        'Your code is valid for 2 minutes.',
        textAlign: TextAlign.center,
        style: BambooFonts.ui(12, color: BambooInk.ink700),
      ),
      const SizedBox(height: 26),
      EntryButton(
        label: 'Verify & continue',
        onPressed: widget.onSubmit,
        loading: widget.loading,
      ),
      const SizedBox(height: 12),
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(
            onPressed: widget.loading ? null : widget.onChangeIdentifier,
            style: TextButton.styleFrom(foregroundColor: BambooInk.ink700),
            child: const Text('Change email'),
          ),
          Text('·', style: BambooFonts.ui(13, color: BambooInk.ink700)),
          TextButton(
            onPressed: widget.loading ? null : widget.onResend,
            style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
            child: const Text('Resend code'),
          ),
        ],
      ),
      Center(
        child: TextButton(
          style: TextButton.styleFrom(foregroundColor: BambooInk.ink700),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const FeedbackSupportScreen(
                prefilledKind: 'general',
                prefilledMessage: "I'm not receiving my OTP code.",
              ),
            ),
          ),
          child: Text(
            'Trouble receiving it?',
            style: BambooFonts.ui(12.5, color: BambooInk.ink700),
          ),
        ),
      ),
    ],
  );
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
          const Icon(
            Icons.error_outline_rounded,
            color: BambooInk.clay,
            size: 20,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              message,
              style: BambooFonts.ui(13, color: BambooInk.clayInk),
            ),
          ),
        ],
      ),
    );
  }
}
