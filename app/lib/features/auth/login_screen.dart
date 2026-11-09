import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../onboarding/entry_brand.dart';
import '../onboarding/onboarding_back.dart';
import '../../app/providers.dart';
import '../../app/router.dart' show AppRoute;
import '../../data/api_exception.dart';
import '../../data/auth_api.dart';
import '../../data/phone_number_hint.dart';
import '../../data/consent_policy.dart';
import '../../data/product_access_api.dart';
import '../settings/feedback_support_screen.dart';
import '../settings/legal_screen.dart';
import 'account_recovery_screen.dart';
import 'phone_gate_provider.dart';
import 'phone_input.dart';
import 'auth_feedback.dart';

/// A4: DPDP §8.2 — purpose-specific, unbundled consent, never a single
/// bundled "I agree to everything" checkbox. Every consent row this screen
/// writes is tagged with the one shared policy version
/// ([consentPolicyVersion], the published policy date), which changes in one
/// place whenever the Terms/Privacy copy actually changes.
const currentPolicyVersion = consentPolicyVersion;

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
  final _codeFocusNode = FocusNode();

  /// auth/'s OTP_TTL_SECONDS and OTP_VERIFY_MAX_ATTEMPTS defaults, which
  /// production uses. v2 challenges carry their own expiry.
  static const _codeLifetime = Duration(seconds: 60);
  static const _maxCodeAttempts = 5;

  OtpChallenge? _challenge;
  int get _codeLength => ref.read(authApiProvider).otpCodeLength;
  bool _otpRequested = false;
  bool _loading = false;
  AuthNotice? _notice;
  bool _autoPhoneHintRequested = false;

  /// When the current code stops working. Null when another request sent
  /// it, so its exact expiry is unknown.
  DateTime? _codeExpiresAt;
  Duration? _codeTimeLeft;
  Timer? _codeTicker;

  /// Wrong tries on the current code. Only counted for a code this screen
  /// requested, since an earlier code's tries are unknown.
  int _wrongAttempts = 0;

  /// Set when a new code can be requested before the timer ends, e.g. after
  /// a verify reply was lost and the code may already be used.
  bool _resendUnlocked = false;

  /// The server accepts a code only once. Keep the session it returned so a
  /// failure while saving it or creating the profile is retried with
  /// Continue instead of resubmitting a used code.
  AuthTokens? _verifiedTokens;

  bool get _codeExpired => _codeTimeLeft == Duration.zero;
  bool get _codeLocked => _wrongAttempts >= _maxCodeAttempts;
  bool get _canResend =>
      _codeTimeLeft == null || _codeExpired || _resendUnlocked;

  /// A4's purpose-specific checkboxes — sign-up only. [_acceptedTerms] and
  /// [_confirmedAdult] are required (they gate submit); the other two default
  /// OFF and are optional. PandaPay is for people aged 18 or over (DPDP needs
  /// verifiable parental consent below that), so the age box is its own
  /// required tick, never folded into the Terms.
  bool _acceptedTerms = false;
  bool _confirmedAdult = false;
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
    setState(() => _notice = null);
  }

  @override
  void dispose() {
    _codeTicker?.cancel();
    _identifierController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    _codeFocusNode.dispose();
    _phoneFocusNode
      ..removeListener(_onPhoneFocusChanged)
      ..dispose();
    super.dispose();
  }

  DateTime _now() => ref.read(authApiProvider).now();

  /// Starts the visible countdown for a freshly sent code. Time left is
  /// always measured against the expiry instant, so it stays correct after
  /// the app was in the background.
  void _startCodeTimer(DateTime? expiresAt) {
    _codeTicker?.cancel();
    _codeExpiresAt = expiresAt;
    _wrongAttempts = 0;
    _resendUnlocked = false;
    _verifiedTokens = null;
    _syncCodeTimeLeft();
    if (expiresAt == null) return;
    _codeTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(_syncCodeTimeLeft);
      if (_codeExpired) timer.cancel();
    });
  }

  void _syncCodeTimeLeft() {
    final expiresAt = _codeExpiresAt;
    if (expiresAt == null) {
      _codeTimeLeft = null;
      return;
    }
    final left = expiresAt.difference(_now());
    _codeTimeLeft = left <= Duration.zero
        ? Duration.zero
        : Duration(seconds: (left.inMilliseconds / 1000).ceil());
  }

  void _stopCodeTimer() {
    _codeTicker?.cancel();
    _codeTicker = null;
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
    // Sign-up asks for a mobile number, which is saved on the new account (one
    // number belongs to one account). Log-in is the email alone: a typed phone
    // proves nothing there.
    if (_isSignUp) {
      final phoneProblem = indianMobileError(_phoneController.text);
      if (phoneProblem != null) return phoneProblem;
      if (!_acceptedTerms) {
        return 'You need to accept the Terms & Privacy Policy to continue.';
      }
      if (!_confirmedAdult) {
        return 'Confirm that you are 18 or older to continue.';
      }
    }
    return null;
  }

  /// Whether the submit button should read as active. Mirrors [_validate]
  /// without duplicating its messages: every hard requirement that would
  /// just bounce straight back as an inline error instead greys the button
  /// out until it's met.
  bool get _canSubmit {
    final identifier = _identifierController.text.trim();
    if (identifier.isEmpty || !identifier.contains('@')) return false;
    if (_isSignUp) {
      if (indianMobileDigits(_phoneController.text) == null) return false;
      if (!_acceptedTerms || !_confirmedAdult) return false;
    }
    return true;
  }

  Future<void> _requestOtp() async {
    final validationError = _validate();
    if (validationError != null) {
      setState(() => _notice = AuthNotice.input(validationError));
      return;
    }
    final resending = _otpRequested;
    setState(() {
      _loading = true;
      _notice = null;
    });
    final identifier = _identifierController.text.trim();
    try {
      final auth = ref.read(authApiProvider);
      final deviceId = auth.versionedOtpEnabled
          ? await ref.read(localDeviceIdProvider.future)
          : null;
      _challenge = await auth.requestEmailOtp(
        identifier,
        deviceId: deviceId,
        isSignUp: _isSignUp,
        phoneNumber: _isSignUp ? _phoneController.text.trim() : null,
      );
      if (!mounted) return;
      setState(() {
        _otpRequested = true;
        _codeController.clear();
        _startCodeTimer(_challenge?.expiresAt ?? _now().add(_codeLifetime));
        if (resending) {
          _notice = AuthNotice(
            title: 'New code sent',
            message:
                'Check $identifier for the newest email. Earlier codes no '
                'longer work.',
            kind: AuthFailureKind.codeAlreadySent,
            tone: AuthNoticeTone.info,
          );
        }
      });
      _codeFocusNode.requestFocus();
    } catch (e, stack) {
      debugPrint('Sign-in code request failed: $e\n$stack');
      if (!mounted) return;
      // The auth service deliberately rejects a second request while the
      // first code is still valid. That is not a dead end: the code already
      // in the user's inbox is the one they should enter. Move straight to
      // the verification step instead of leaving them on a form whose only
      // action is guaranteed to fail again.
      final activeOtp =
          (!ref.read(authApiProvider).versionedOtpEnabled ||
              _challenge != null) &&
          isCodeStillActive(e);
      setState(() {
        _notice = describeAuthFailure(
          e,
          stage: AuthStage.sendCode,
          email: identifier,
        );
        if (activeOtp) {
          // Keep a running countdown; a code sent elsewhere has an unknown
          // expiry, so resend stays available.
          if (!_otpRequested || _codeExpiresAt == null) _startCodeTimer(null);
          _otpRequested = true;
        }
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _verifyOtp() async {
    final alreadyVerified = _verifiedTokens != null;
    if (!alreadyVerified) {
      if (_codeExpired) {
        setState(() => _notice = const AuthNotice.codeExpired());
        return;
      }
      if (_codeLocked) {
        setState(() => _notice = const AuthNotice.codeLocked());
        return;
      }
      if (!RegExp(
        '^[0-9]{$_codeLength}\$',
      ).hasMatch(_codeController.text.trim())) {
        setState(
          () => _notice = AuthNotice.input(
            'Enter the $_codeLength-digit code from your email.',
          ),
        );
        return;
      }
    }
    setState(() {
      _loading = true;
      _notice = null;
    });
    var stage = alreadyVerified ? AuthStage.finishSignIn : AuthStage.verifyCode;
    final identifier = _identifierController.text.trim();
    // Taken before any await: it outlives this screen (see below).
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final code = _codeController.text.trim();
      final authApi = ref.read(authApiProvider);

      var tokens = _verifiedTokens;
      if (tokens == null) {
        final deviceId = await ref.read(localDeviceIdProvider.future);
        final deviceInfo = await ref.read(deviceMetadataProvider.future);
        tokens = await authApi.verifyEmailOtp(
          identifier,
          code,
          deviceId,
          deviceInfo: deviceInfo,
          challenge: _challenge,
          // Only sign-up links the phone. Returning-user login is authorized
          // by the email OTP and keeps the existing account linkage unchanged.
          phoneNumber: _isSignUp ? _phoneController.text.trim() : null,
        );
        // The code is used up now. Anything that fails from here is retried
        // with these tokens, never by resubmitting the code.
        _verifiedTokens = tokens;
        _stopCodeTimer();
      }
      stage = AuthStage.finishSignIn;

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

      if (!mounted) return;
      final store = await ref.read(tokenStoreProvider.future);
      await store.save(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      // The phone lock. Settled before the token is published, so the router
      // already knows whether the Add phone screen must come first. Never fails
      // the sign-in: an older server, a lock that is off, or no network just
      // leaves the gate closed.
      await _settlePhone(container, tokens.accessToken);

      // Setting the token swaps this screen out of the tree, which disposes
      // this State and its `ref`. Keep the provider container, which outlives
      // the screen, for the steps that must still run afterwards; using `ref`
      // there threw "Cannot use ref after the widget was disposed", skipped
      // ensureProfile and logged a false sign-in failure.
      container.read(accessTokenProvider.notifier).state = tokens.accessToken;

      // Keep returning-user sign-in on its existing path. New sign-ups must
      // pass the product-access gate before POST /profile creates a profile.
      if (!_isSignUp && !container.read(phoneGateProvider).needsPhone) {
        await container
            .read(profileApiProvider)!
            .ensureProfile(email: identifier);
        container.invalidate(profileProvider);
      }

      // This screen is also reached by being pushed (Home's "Sign in" banner),
      // where nothing else pops it once sign-in succeeds. The embedded case
      // (Cards/Activity/Account watching accessTokenProvider) has no route to
      // pop, so canPop() is false there and this is a no-op.
      if (!_isSignUp && mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e, stack) {
      debugPrint('Sign-in failed at ${stage.name}: $e\n$stack');
      if (!mounted) return;
      final rejected = stage == AuthStage.verifyCode && isRejectedCode(e);
      // Tries are only countable for a code this screen sent and timed.
      final countTries = rejected && _codeTimeLeft != null;
      if (countTries) _wrongAttempts++;
      setState(() {
        _notice = describeAuthFailure(
          e,
          stage: stage,
          email: identifier,
          codeTimeLeft: _codeTimeLeft,
          attemptsLeft: countTries ? _maxCodeAttempts - _wrongAttempts : null,
        );
        if (rejected) _codeController.clear();
        // A lost verify reply may have used the code; let the user get a
        // new one now instead of waiting out the timer.
        if (stage == AuthStage.verifyCode && e is TimeoutException) {
          _resendUnlocked = true;
        }
        if (_notice?.kind == AuthFailureKind.sessionRejected) {
          _verifiedTokens = null;
          _resendUnlocked = true;
        }
      });
      if (rejected && !_codeLocked) _codeFocusNode.requestFocus();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Saves the number typed at sign-up on the new account, or finds out that this
  /// account still needs one. Anything that goes wrong here is swallowed unless the
  /// server says the phone lock is on, because the lock is off by default.
  Future<void> _settlePhone(ProviderContainer container, String accessToken) async {
    try {
      final phoneApi = container.read(authApiProvider).phoneApiFor(accessToken);
      var status = await phoneApi.status();
      if (!status.required || status.hasPhone) return;
      final gate = container.read(phoneGateProvider.notifier);
      final typed = _isSignUp ? indianMobileDigits(_phoneController.text) : null;
      if (typed == null) {
        gate.needs();
        return;
      }
      try {
        await phoneApi.claim(typed);
      } on ApiException catch (error) {
        // The number is taken or refused: let the person see why and change it.
        gate.needs(prefill: typed, message: error.userMessage);
      }
    } catch (_) {
      // Lock off, older server, or offline: the sign-in goes ahead.
    }
  }

  void _changeIdentifier() {
    _stopCodeTimer();
    setState(() {
      _otpRequested = false;
      _notice = null;
      _codeController.clear();
      _codeExpiresAt = null;
      _codeTimeLeft = null;
      _wrongAttempts = 0;
      _resendUnlocked = false;
      _verifiedTokens = null;
    });
  }

  /// A one-tap way out of the error, when there is an obvious one.
  ({String label, VoidCallback onPressed})? _noticeAction(AuthNotice notice) {
    if (notice.kind == AuthFailureKind.accountNotFound &&
        !_isSignUp &&
        GoRouter.maybeOf(context) != null) {
      return (
        label: 'Create an account',
        onPressed: () => context.pushReplacement(AppRoute.signUp),
      );
    }
    if (notice.kind == AuthFailureKind.accountExists &&
        _isSignUp &&
        GoRouter.maybeOf(context) != null) {
      return (
        label: 'Sign in instead',
        onPressed: () => context.pushReplacement(AppRoute.logIn),
      );
    }
    return null;
  }

  String get _title => _otpRequested
      ? 'Check your email'
      : _isSignUp
      ? 'Start saving\non every spend'
      : 'Welcome back';

  @override
  Widget build(BuildContext context) => OnboardingBackScope(
    handlesStep: _otpRequested,
    busy: _loading,
    onBack: _back,
    child: _buildPage(context),
  );

  void _back() {
    if (_otpRequested) {
      _changeIdentifier();
    } else {
      onboardingBack(context, fallback: AppRoute.welcome);
    }
  }

  Widget _buildPage(BuildContext context) => EntryBackdrop(
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
                              onPressed: _loading ? null : _back,
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
                              ? 'Enter the $_codeLength-digit verification code sent to'
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
                            canSubmit: () => _canSubmit,
                            onRequestPhoneHint: _requestPhoneNumberHint,
                            acceptedTerms: _acceptedTerms,
                            confirmedAdult: _confirmedAdult,
                            optInCrowdsource: _optInCrowdsource,
                            optInMarketing: _optInMarketing,
                            onAcceptedTermsChanged: (v) =>
                                setState(() => _acceptedTerms = v),
                            onConfirmedAdultChanged: (v) =>
                                setState(() => _confirmedAdult = v),
                            onOptInCrowdsourceChanged: (v) =>
                                setState(() => _optInCrowdsource = v),
                            onOptInMarketingChanged: (v) =>
                                setState(() => _optInMarketing = v),
                          )
                        else
                          _OtpStep(
                            codeLength: _codeLength,
                            controller: _codeController,
                            focusNode: _codeFocusNode,
                            loading: _loading,
                            codeTimeLeft: _codeTimeLeft,
                            canResend: _canResend,
                            locked: _codeLocked,
                            verified: _verifiedTokens != null,
                            // Shown beside the code boxes, where the user is
                            // looking, rather than at the bottom of the page.
                            notice: _notice == null
                                ? null
                                : _NoticeBanner(
                                    notice: _notice!,
                                    action: _noticeAction(_notice!),
                                  ),
                            onSubmit: _verifyOtp,
                            onChangeIdentifier: _changeIdentifier,
                            onResend: _requestOtp,
                          ),
                        if (_notice != null && !_otpRequested) ...[
                          const SizedBox(height: 16),
                          _NoticeBanner(
                            notice: _notice!,
                            action: _noticeAction(_notice!),
                          ),
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
                                  _notice = null;
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

  /// Read at build time so typing in either field re-evaluates it; the
  /// submit button stays disabled while this returns false.
  final bool Function() canSubmit;
  final VoidCallback onRequestPhoneHint;

  /// A4 — sign-up only. See _LoginScreenState's own fields for what each
  /// means; this widget just renders/reports them, LoginScreen owns state.
  final bool acceptedTerms;
  final bool confirmedAdult;
  final bool optInCrowdsource;
  final bool optInMarketing;
  final ValueChanged<bool> onAcceptedTermsChanged;
  final ValueChanged<bool> onConfirmedAdultChanged;
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
    required this.canSubmit,
    required this.onRequestPhoneHint,
    required this.acceptedTerms,
    required this.confirmedAdult,
    required this.optInCrowdsource,
    required this.optInMarketing,
    required this.onAcceptedTermsChanged,
    required this.onConfirmedAdultChanged,
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
      borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
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
                textInputAction: isSignUp ? TextInputAction.next : TextInputAction.done,
                autofillHints: const [AutofillHints.email],
                onSubmitted: (_) => isSignUp
                    ? phoneFocusNode.requestFocus()
                    : (loading || !canSubmit() ? null : onSubmit()),
                style: BambooFonts.ui(15),
                decoration: _fieldDecoration(
                  hint: 'Email address',
                  icon: Icons.mail_outline_rounded,
                ),
              ),
              if (isSignUp) const SizedBox(height: 12),
              if (isSignUp)
              TextField(
                controller: phoneController,
                focusNode: phoneFocusNode,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.telephoneNumber],
                onSubmitted: (_) => loading || !canSubmit() ? null : onSubmit(),
                style: BambooFonts.ui(15),
                decoration:
                    _fieldDecoration(
                      hint: 'Mobile number (India)',
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
                  value: confirmedAdult,
                  onChanged: onConfirmedAdultChanged,
                  label: 'I am 18 or older.',
                  subtitle: 'Required. PandaPay is only for adults.',
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
            // Typing in either field doesn't rebuild the screen, so listen
            // to both controllers here to flip the button between its light
            // (not ready) and dark (ready) states.
            child: ListenableBuilder(
              listenable: Listenable.merge([
                identifierController,
                phoneController,
              ]),
              builder: (context, _) => EntryButton(
                label: isSignUp ? 'Send verification code' : 'Send code',
                onPressed: canSubmit() ? onSubmit : null,
                loading: loading,
              ),
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
      activeColor: BambooInk.slate,
      checkColor: BambooInk.lime,
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
  final int codeLength;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool loading;

  /// Null when the code's expiry is unknown (it was sent by an earlier
  /// request); [Duration.zero] once it has expired.
  final Duration? codeTimeLeft;
  final bool canResend;
  final bool locked;

  /// The code was accepted but sign-in has not finished yet.
  final bool verified;
  final Widget? notice;
  final VoidCallback onSubmit;
  final VoidCallback onChangeIdentifier;
  final VoidCallback onResend;

  const _OtpStep({
    required this.codeLength,
    required this.controller,
    required this.focusNode,
    required this.loading,
    required this.codeTimeLeft,
    required this.canResend,
    required this.locked,
    required this.verified,
    required this.notice,
    required this.onSubmit,
    required this.onChangeIdentifier,
    required this.onResend,
  });

  bool get expired => codeTimeLeft == Duration.zero;

  @override
  State<_OtpStep> createState() => _OtpStepState();
}

class _OtpStepState extends State<_OtpStep> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant _OtpStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
  }

  void _focusChanged() => setState(() {});

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    super.dispose();
  }

  /// The one obvious next step for the current state.
  ({String label, VoidCallback? onPressed}) get _primary {
    if (widget.verified) {
      return (label: 'Continue', onPressed: widget.onSubmit);
    }
    if (widget.expired || (widget.locked && widget.canResend)) {
      return (label: 'Send a new code', onPressed: widget.onResend);
    }
    return (
      label: 'Verify & continue',
      onPressed: widget.locked ? null : widget.onSubmit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final focus = widget.focusNode;
    final inputLocked = widget.verified || widget.expired || widget.locked;
    final primary = _primary;
    final showResendLink =
        !widget.verified && primary.label != 'Send a new code';
    final timeLeft = widget.codeTimeLeft;
    return Column(
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
                    focusNode: focus,
                    enabled: !widget.loading && !inputLocked,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(widget.codeLength),
                    ],
                    onSubmitted: (_) =>
                        widget.loading ? null : primary.onPressed?.call(),
                    showCursor: false,
                    enableInteractiveSelection: false,
                    style: const TextStyle(
                      color: Colors.transparent,
                      fontSize: 1,
                    ),
                    decoration: InputDecoration(
                      labelText: '${widget.codeLength}-digit verification code',
                      floatingLabelBehavior: FloatingLabelBehavior.never,
                      labelStyle: TextStyle(
                        color: Colors.transparent,
                        fontSize: 1,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                    ),
                  ),
                  IgnorePointer(
                    child: ExcludeSemantics(
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: widget.controller,
                        builder: (context, value, _) {
                          final active = value.text.length.clamp(
                            0,
                            widget.codeLength - 1,
                          );
                          return Row(
                            children: [
                              for (var i = 0; i < widget.codeLength; i++) ...[
                                if (i > 0) const SizedBox(width: 12),
                                Expanded(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 160),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: inputLocked
                                          ? BambooInk.paperMuted
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(15),
                                      border: Border.all(
                                        color: focus.hasFocus && i == active
                                            ? BambooInk.jade
                                            : const Color(0xFFDDE1E3),
                                        width: focus.hasFocus && i == active
                                            ? 1.6
                                            : 1,
                                      ),
                                    ),
                                    child: Text(
                                      i < value.text.length
                                          ? value.text[i]
                                          : '–',
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
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _CodeStatusLine(timeLeft: timeLeft, verified: widget.verified),
        if (widget.notice != null) ...[
          const SizedBox(height: 16),
          widget.notice!,
        ],
        const SizedBox(height: 22),
        EntryButton(
          label: primary.label,
          onPressed: primary.onPressed,
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
            if (showResendLink) ...[
              Text('·', style: BambooFonts.ui(13, color: BambooInk.ink700)),
              TextButton(
                onPressed: widget.loading || !widget.canResend
                    ? null
                    : widget.onResend,
                style: TextButton.styleFrom(
                  foregroundColor: BambooInk.jade,
                  disabledForegroundColor: BambooInk.ink500,
                ),
                child: Text(
                  widget.canResend || timeLeft == null
                      ? 'Resend code'
                      : 'Resend in ${formatCountdown(timeLeft)}',
                ),
              ),
            ],
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
}

/// "Code expires in 1:42", turning amber in the last 30 seconds and showing
/// a clear expired state, like the countdowns in banking and payment apps.
class _CodeStatusLine extends StatelessWidget {
  final Duration? timeLeft;
  final bool verified;
  const _CodeStatusLine({required this.timeLeft, required this.verified});

  @override
  Widget build(BuildContext context) {
    final left = timeLeft;
    final (
      IconData icon,
      String text,
      Color color,
      FontWeight weight,
    ) = switch (left) {
      _ when verified => (
        Icons.check_circle_rounded,
        'Code accepted',
        BambooInk.jade,
        FontWeight.w600,
      ),
      null => (
        Icons.schedule_rounded,
        'Codes are valid for 1 minute.',
        BambooInk.ink700,
        FontWeight.w400,
      ),
      Duration.zero => (
        Icons.timer_off_outlined,
        'Code expired',
        BambooInk.clayInk,
        FontWeight.w600,
      ),
      _ when left <= const Duration(seconds: 30) => (
        Icons.timer_outlined,
        'Code expires in ${formatCountdown(left)}',
        BambooInk.amber,
        FontWeight.w600,
      ),
      _ => (
        Icons.timer_outlined,
        'Code expires in ${formatCountdown(left)}',
        BambooInk.ink700,
        FontWeight.w400,
      ),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: BambooFonts.ui(
              12.5,
              color: color,
              weight: weight,
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    );
  }
}

/// Title, plain-language explanation, optional next step and support
/// reference. Errors are clay, things to wait out are amber, and neutral
/// updates (a code was sent) are jade.
class _NoticeBanner extends StatelessWidget {
  final AuthNotice notice;
  final ({String label, VoidCallback onPressed})? action;
  const _NoticeBanner({required this.notice, this.action});

  @override
  Widget build(BuildContext context) {
    final (Color accent, Color ink, IconData icon) = switch (notice.tone) {
      AuthNoticeTone.error => (
        BambooInk.clay,
        BambooInk.clayInk,
        Icons.error_outline_rounded,
      ),
      AuthNoticeTone.warning => (
        BambooInk.amber,
        BambooInk.ink900,
        Icons.info_outline_rounded,
      ),
      AuthNoticeTone.info => (
        BambooInk.jade,
        BambooInk.ink900,
        Icons.mark_email_read_outlined,
      ),
    };
    final title = notice.title;
    final reference = notice.reference;
    final next = action;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: accent, size: 20),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(
                      title,
                      style: BambooFonts.ui(
                        13.5,
                        color: ink,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text(
                    notice.message,
                    style: BambooFonts.ui(13, color: ink, height: 1.35),
                  ),
                  if (next != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: next.onPressed,
                        style: TextButton.styleFrom(
                          foregroundColor: BambooInk.jade,
                          padding: const EdgeInsets.only(top: 6),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          next.label,
                          style: BambooFonts.ui(
                            13,
                            color: BambooInk.jade,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  if (reference != null) ...[
                    const SizedBox(height: 6),
                    SelectableText(
                      reference,
                      style: BambooFonts.ui(11, color: BambooInk.ink500),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
