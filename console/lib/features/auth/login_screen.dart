import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/admin_api.dart';
import '../../data/private_admin_auth.dart';

const _slate = Color(0xFF2B313A);
const _lime = Color(0xFFCDF564);
const _muted = Color(0xFF747B85);
const _line = Color(0xFFE6E8E4);

/// Authentication stays with the private gateway; this screen only presents
/// the current account, email-proof or security-key step.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _grantController = TextEditingController();
  final _deviceId =
      'console-${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  ConsoleOtpChallenge? _challenge;
  bool _useEmail = true;
  bool _otpRequested = false;
  bool _loading = false;
  bool _enrollmentComplete = false;
  String? _error;
  String? _notice;

  bool get _privateAdmin => ref.read(authApiProvider) is PrivateAdminAuthApi;
  bool get _enrolling =>
      _otpRequested &&
      ref.read(authApiProvider) is PrivateAdminAuthApi &&
      (ref.read(authApiProvider) as PrivateAdminAuthApi).enrollmentRequired;
  int get _step =>
      (_enrolling || _enrollmentComplete) ? 2 : (_otpRequested ? 1 : 0);

  Future<void> _enroll() async {
    if (_loading || !_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    try {
      await (ref.read(authApiProvider) as PrivateAdminAuthApi).enroll(
        _grantController.text.trim(),
      );
      if (!mounted) return;
      _grantController.clear();
      _codeController.clear();
      setState(() {
        _otpRequested = false;
        _enrollmentComplete = true;
      });
    } on AdminApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () =>
            _error = 'Security-key setup could not be completed. Please retry.',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestOtp() async {
    if (_loading || !_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    try {
      final auth = ref.read(authApiProvider);
      _challenge = _useEmail
          ? await auth.requestEmailOtp(
              _emailController.text.trim(),
              deviceId: _deviceId,
            )
          : await auth.requestOtp(
              _phoneController.text.trim(),
              deviceId: _deviceId,
            );
      if (mounted) setState(() => _otpRequested = true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyOtp() async {
    if (_loading || !_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = ref.read(authApiProvider);
      final tokens = _useEmail
          ? await auth.verifyEmailOtp(
              _emailController.text.trim(),
              _codeController.text.trim(),
              _deviceId,
              challenge: _challenge,
            )
          : await auth.verifyOtp(
              _phoneController.text.trim(),
              _codeController.text.trim(),
              _deviceId,
              challenge: _challenge,
            );
      final store = await ref.read(tokenStoreProvider.future);
      await store.save(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      if (mounted) {
        ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
      }
    } catch (error) {
      if (!mounted) return;
      // Pending administrators have completed email proof. Enrollment is a
      // normal next step, so hide the already-consumed code and its button.
      if (_enrolling) {
        _codeController.clear();
        setState(() => _error = null);
      } else {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startAgain() {
    if (_loading) return;
    _codeController.clear();
    _grantController.clear();
    setState(() {
      _otpRequested = false;
      _enrollmentComplete = false;
      _challenge = null;
      _error = null;
      _notice = null;
    });
  }

  Future<void> _submit() =>
      _enrolling ? _enroll() : (_otpRequested ? _verifyOtp() : _requestOtp());

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: _slate,
          onPrimary: _lime,
          surface: Colors.white,
        ),
        textSelectionTheme: const TextSelectionThemeData(cursorColor: _slate),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8F9F7),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 18,
          ),
          labelStyle: const TextStyle(color: _muted, fontSize: 14),
          hintStyle: const TextStyle(color: Color(0xFFA0A5AD), fontSize: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _slate, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFB5463B)),
          ),
          errorMaxLines: 2,
        ),
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F6F2),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 980;
              final padding = constraints.maxWidth < 600 ? 20.0 : 40.0;
              return SingleChildScrollView(
                padding: EdgeInsets.all(padding),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: max(0, constraints.maxHeight - padding * 2),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _BrandHeader(compact: constraints.maxWidth < 450),
                          SizedBox(height: wide ? 32 : 28),
                          Container(
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(
                                wide ? 24 : 20,
                              ),
                              border: Border.all(color: _line),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x082B313A),
                                  blurRadius: 36,
                                  offset: Offset(0, 16),
                                ),
                              ],
                            ),
                            child: wide
                                ? Stack(
                                    children: [
                                      const Positioned.fill(
                                        child: FractionallySizedBox(
                                          alignment: Alignment.centerLeft,
                                          widthFactor: 5 / 11,
                                          heightFactor: 1,
                                          child: ColoredBox(color: _slate),
                                        ),
                                      ),
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          const Expanded(
                                            flex: 5,
                                            child: _WorkspacePanel(),
                                          ),
                                          Expanded(
                                            flex: 6,
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 56,
                                                    vertical: 48,
                                                  ),
                                              child: Center(
                                                child: _buildForm(context),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  )
                                : Padding(
                                    padding: EdgeInsets.all(
                                      constraints.maxWidth < 400 ? 24 : 36,
                                    ),
                                    child: _buildForm(context),
                                  ),
                          ),
                          const SizedBox(height: 24),
                          const Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 16,
                            runSpacing: 8,
                            children: [
                              Text(
                                'PandaPay Console',
                                style: TextStyle(color: _muted, fontSize: 12),
                              ),
                              Text(
                                'For authorized administrators',
                                style: TextStyle(color: _muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final privateAuth = ref.read(authApiProvider);
    if (privateAuth is PrivateAdminAuthApi &&
        (_enrollmentComplete ||
            (_enrolling && privateAuth.awaitingActivation))) {
      return _buildEnrollmentNextStep(privateAuth);
    }
    final enrolling = _enrolling;
    final needsBackup =
        enrolling &&
        privateAuth is PrivateAdminAuthApi &&
        privateAuth.primaryKeyRegistered;
    final managedEnrollment =
        privateAuth is PrivateAdminAuthApi &&
        privateAuth.approvedBrowserEnrollment;
    final title = enrolling
        ? (needsBackup
              ? 'Register your backup key.'
              : 'Connect your security key.')
        : (_otpRequested ? 'Check your inbox.' : 'Welcome back.');
    final description = enrolling
        ? (needsBackup
              ? (managedEnrollment
                    ? 'Your primary key is already registered. Continue below to register an independent backup authenticator. Your browser will guide you.'
                    : 'Your primary key is already registered. Open PandaPay Admin Setup on your Desktop and choose option 2 for a fresh backup grant. Register a separate authenticator.')
              : 'Your email is verified. Register a passkey or hardware key to begin setting up your access.')
        : (_otpRequested
              ? 'Enter the verification code we sent to your ${_useEmail ? 'email' : 'phone'}. Your security key comes next.'
              : 'Sign in to the workspace behind PandaPay.');
    final button = _loading
        ? (enrolling ? 'Opening security key…' : 'Please wait…')
        : (enrolling
              ? 'Register security key'
              : (_otpRequested ? 'Verify code' : 'Send verification code'));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'ADMIN ACCESS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: _muted,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 32,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.8,
                  color: _slate,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.65,
                  color: _muted,
                ),
              ),
              const SizedBox(height: 30),
              if (_privateAdmin) ...[
                _SignInSteps(current: _step),
                const SizedBox(height: 30),
              ],
              if (_notice != null) ...[
                _MessageBanner(message: _notice!, success: true),
                const SizedBox(height: 22),
              ],
              if (!_otpRequested) ...[
                if (!_privateAdmin) ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Email')),
                      ButtonSegment(value: false, label: Text('Phone')),
                    ],
                    selected: {_useEmail},
                    onSelectionChanged: _loading
                        ? null
                        : (value) => setState(() => _useEmail = value.first),
                  ),
                  const SizedBox(height: 20),
                ],
                const _FieldLabel('Your account'),
                const SizedBox(height: 9),
                TextFormField(
                  key: const Key('admin-account'),
                  controller: _useEmail ? _emailController : _phoneController,
                  enabled: !_loading,
                  autofillHints: [
                    _useEmail
                        ? AutofillHints.email
                        : AutofillHints.telephoneNumber,
                  ],
                  keyboardType: _useEmail
                      ? TextInputType.emailAddress
                      : TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  enableSuggestions: false,
                  onFieldSubmitted: (_) => _submit(),
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    if (text.isEmpty) {
                      return _useEmail
                          ? 'Enter your account email.'
                          : 'Enter your phone number.';
                    }
                    if (_useEmail &&
                        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text)) {
                      return 'Enter a valid email address.';
                    }
                    return null;
                  },
                  decoration: InputDecoration(
                    labelText: _useEmail ? 'Account email' : 'Phone number',
                    hintText: _useEmail ? 'you@company.com' : '+91XXXXXXXXXX',
                    prefixIcon: Icon(
                      _useEmail
                          ? Icons.alternate_email_rounded
                          : Icons.phone_outlined,
                      size: 20,
                      color: _muted,
                    ),
                  ),
                ),
              ] else ...[
                _AccountSummary(
                  account: _useEmail
                      ? _emailController.text.trim()
                      : _phoneController.text.trim(),
                  verified: enrolling,
                ),
                const SizedBox(height: 24),
                if (enrolling) ...[
                  if (managedEnrollment)
                    const _MessageBanner(
                      message:
                          'Continue to create your passkey. Confirm the request on your iPhone, in your password manager, or with your security key.',
                      success: true,
                    )
                  else ...[
                    _FieldLabel(
                      needsBackup
                          ? 'Backup-key enrollment grant'
                          : 'One-use enrollment grant',
                    ),
                    const SizedBox(height: 9),
                    TextFormField(
                      key: const Key('admin-enrollment-grant'),
                      controller: _grantController,
                      enabled: !_loading,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      validator: PrivateAdminAuthApi.validateEnrollmentGrant,
                      decoration: const InputDecoration(
                        hintText: 'Paste your enrollment grant',
                        prefixIcon: Icon(
                          Icons.vpn_key_outlined,
                          size: 20,
                          color: _muted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Use the 43-character grant from local setup. It is single use and expires after 10 minutes. Finish this step within 1 minute of requesting your email code.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: _muted,
                      ),
                    ),
                  ],
                ] else ...[
                  const _FieldLabel('Verification code'),
                  const SizedBox(height: 9),
                  TextFormField(
                    key: const Key('admin-email-code'),
                    controller: _codeController,
                    enabled: !_loading,
                    autofocus: true,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLength: ref.read(authApiProvider).otpCodeLength,
                    style: const TextStyle(
                      fontSize: 23,
                      letterSpacing: 8,
                      color: _slate,
                    ),
                    onFieldSubmitted: (_) => _submit(),
                    validator: (value) =>
                        RegExp(
                          '^\\d{${ref.read(authApiProvider).otpCodeLength}}\$',
                        ).hasMatch(value ?? '')
                        ? null
                        : 'Enter the complete verification code.',
                    decoration: InputDecoration(
                      labelText:
                          '${ref.read(authApiProvider).otpCodeLength}-digit code',
                      hintText: '0' * ref.read(authApiProvider).otpCodeLength,
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'The code is valid for 1 minute.',
                    style: TextStyle(fontSize: 12, color: _muted),
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 20),
                _MessageBanner(message: _error!),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('admin-login-submit'),
                  onPressed: _loading ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: _slate,
                    foregroundColor: _lime,
                    disabledBackgroundColor: _slate.withValues(alpha: .7),
                    disabledForegroundColor: _lime,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_loading) ...[
                          const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _lime,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Flexible(
                          child: Text(
                            button,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (!_loading) ...[
                          const SizedBox(width: 12),
                          Icon(
                            enrolling
                                ? Icons.fingerprint_rounded
                                : Icons.arrow_forward_rounded,
                            size: 18,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (_otpRequested)
                Center(
                  child: TextButton(
                    onPressed: _loading ? null : _startAgain,
                    style: TextButton.styleFrom(foregroundColor: _muted),
                    child: Text(
                      enrolling ? 'Start again' : 'Use a different account',
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              const Divider(color: _line, height: 1),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 16,
                    color: _muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _privateAdmin
                          ? 'Email verification and a security key protect your workspace.'
                          : 'Access is limited to approved administrator accounts.',
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: _muted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEnrollmentNextStep(PrivateAdminAuthApi auth) {
    final activation = auth.awaitingActivation;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 42,
            color: Color(0xFF2F7854),
          ),
          const SizedBox(height: 20),
          Text(
            activation ? 'Ready for activation.' : 'Primary key registered.',
            style: const TextStyle(
              fontSize: 32,
              height: 1.15,
              fontWeight: FontWeight.w700,
              color: _slate,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            activation
                ? 'Both security keys are registered. Your account is awaiting activation before you can enter the console.'
                : 'Your key was saved successfully. Next, register an independent backup key and activate your account.',
            style: const TextStyle(fontSize: 14, height: 1.65, color: _muted),
          ),
          const SizedBox(height: 24),
          _AccountSummary(
            account: _emailController.text.trim(),
            verified: true,
          ),
          const SizedBox(height: 24),
          _MessageBanner(
            message: activation
                ? 'Open PandaPay Admin Setup on your Desktop. Choose option 3, review the local activation plan and type ACTIVATE. Then return here to sign in.'
                : (auth.approvedBrowserEnrollment
                      ? 'Return to sign in and verify a new email code to register your independent backup key here. After both keys are registered, use option 3 in PandaPay Admin Setup to activate the account.'
                      : 'Open PandaPay Admin Setup on your Desktop. Choose option 2 to prepare your backup key, then option 3 to activate the account. Your primary grant has already been used.'),
            success: true,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('admin-return-to-sign-in'),
              onPressed: _startAgain,
              style: FilledButton.styleFrom(
                backgroundColor: _slate,
                foregroundColor: _lime,
                minimumSize: const Size.fromHeight(54),
              ),
              child: const Text('Return to sign in'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _emailController.dispose();
    _codeController.dispose();
    _grantController.dispose();
    super.dispose();
  }
}

class _BrandHeader extends StatelessWidget {
  final bool compact;
  const _BrandHeader({required this.compact});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Image.asset(
        'assets/brand/pandapay_mark.png',
        width: 42,
        height: 42,
        excludeFromSemantics: true,
      ),
      const SizedBox(width: 11),
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PandaPay',
              style: TextStyle(
                fontSize: 21,
                letterSpacing: -.6,
                fontWeight: FontWeight.w700,
                color: _slate,
              ),
            ),
            SizedBox(height: 3),
            Text(
              'OPERATIONS CONSOLE',
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1.7,
                fontWeight: FontWeight.w500,
                color: _muted,
              ),
            ),
          ],
        ),
      ),
      if (!compact)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: _line),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded, size: 13, color: _muted),
              SizedBox(width: 7),
              Text(
                'Private workspace',
                style: TextStyle(fontSize: 11, color: _slate),
              ),
            ],
          ),
        ),
    ],
  );
}

class _WorkspacePanel extends StatelessWidget {
  const _WorkspacePanel();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('admin-workspace-panel'),
    color: _slate,
    padding: const EdgeInsets.all(40),
    child: const Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 7, color: _lime),
                SizedBox(width: 9),
                Text(
                  'THE PANDA BEHIND THE SCENES',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.4,
                    color: _lime,
                  ),
                ),
              ],
            ),
            SizedBox(height: 30),
            Text(
              'Better data.\nBetter decisions.',
              style: TextStyle(
                fontSize: 43,
                height: 1.13,
                letterSpacing: -1.4,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 19),
            Text(
              'Manage card rules, review incoming reports, and keep operations in view.',
              style: TextStyle(
                fontSize: 14,
                height: 1.7,
                color: Color(0xFFBBC1C8),
              ),
            ),
          ],
        ),
        SizedBox(height: 54),
        Column(
          children: [
            _WorkspaceFeature(
              Icons.credit_card_outlined,
              'Catalogue & policies',
              'Keep every card and reward rule in order.',
            ),
            SizedBox(height: 25),
            _WorkspaceFeature(
              Icons.fact_check_outlined,
              'Review & resolve',
              'Review reports and resolve conflicting data.',
            ),
            SizedBox(height: 25),
            _WorkspaceFeature(
              Icons.insights_rounded,
              'Learning & insights',
              'Keep a clear view of data quality and operations.',
            ),
          ],
        ),
        SizedBox(height: 48),
        Row(
          children: [
            Icon(Icons.shield_outlined, size: 16, color: Color(0xFFBBC1C8)),
            SizedBox(width: 9),
            Expanded(
              child: Text(
                'Access reserved for the PandaPay team.',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Color(0xFFBBC1C8),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _WorkspaceFeature extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  const _WorkspaceFeature(this.icon, this.title, this.description);

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: const Color(0xFF373E48),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: _lime, size: 20),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              description,
              style: const TextStyle(
                fontSize: 12,
                height: 1.55,
                color: Color(0xFFBBC1C8),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _SignInSteps extends StatelessWidget {
  final int current;
  const _SignInSteps({required this.current});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < 3; i++)
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i == 2 ? 0 : 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 2, color: i <= current ? _slate : _line),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      i < current
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 13,
                      color: i <= current ? _slate : const Color(0xFFBCC1C6),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        const ['Account', 'Email code', 'Security key'][i],
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: i == current
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: i <= current ? _slate : _muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: _slate,
    ),
  );
}

class _AccountSummary extends StatelessWidget {
  final String account;
  final bool verified;
  const _AccountSummary({required this.account, required this.verified});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFF5F7F2),
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: _line),
    ),
    child: Row(
      children: [
        Icon(
          verified
              ? Icons.check_circle_outline_rounded
              : Icons.mail_outline_rounded,
          size: 19,
          color: verified ? const Color(0xFF337451) : _muted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                verified ? 'Email verified' : 'Code sent to',
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
              const SizedBox(height: 3),
              Text(
                account,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _slate,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _MessageBanner extends StatelessWidget {
  final String message;
  final bool success;
  const _MessageBanner({required this.message, this.success = false});

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: success ? const Color(0xFFF0F7EF) : const Color(0xFFFFF3EF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            success
                ? Icons.check_circle_outline_rounded
                : Icons.info_outline_rounded,
            size: 18,
            color: success ? const Color(0xFF337451) : const Color(0xFFA34432),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: success
                    ? const Color(0xFF337451)
                    : const Color(0xFF963C2E),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

@Preview(name: 'Admin sign-in · Desktop', size: Size(1280, 900))
@Preview(name: 'Admin sign-in · Compact', size: Size(390, 844))
Widget adminLoginPreview() => ProviderScope(
  child: MaterialApp(
    theme: ThemeData(
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['Roboto'],
    ),
    home: const LoginScreen(),
  ),
);
