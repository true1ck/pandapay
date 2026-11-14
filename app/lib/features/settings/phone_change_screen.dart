import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/needs_internet.dart';
import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../app/required_field.dart';
import '../../data/api_exception.dart';
import '../../data/phone_api.dart';
import '../auth/phone_input.dart';

/// Add or change the phone number on the account.
///
/// A 6-digit code goes to the sign-in EMAIL and the number is saved only when it
/// is entered. That code proves the person controls the email; it does not prove
/// they own the phone (nothing is sent to the number), so this screen never
/// calls the number "verified". Real phone verification is a later feature.
class PhoneChangeScreen extends ConsumerStatefulWidget {
  const PhoneChangeScreen({super.key, this.changing = false});

  /// True when a number is already on the account and is being replaced.
  final bool changing;

  @override
  ConsumerState<PhoneChangeScreen> createState() => _PhoneChangeScreenState();
}

enum _Step { enterPhone, enterCode, done }

class _PhoneChangeScreenState extends ConsumerState<PhoneChangeScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  _Step _step = _Step.enterPhone;
  bool _busy = false;
  bool _submitted = false;
  String? _error;
  PhoneChangeChallenge? _challenge;
  String? _savedHint;
  Timer? _ticker;
  int _secondsLeft = 0;

  @override
  void dispose() {
    _ticker?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startCountdown(DateTime expiresAt) {
    _ticker?.cancel();
    void tick() {
      final left = expiresAt.difference(DateTime.now()).inSeconds;
      if (!mounted) return;
      setState(() => _secondsLeft = left < 0 ? 0 : left);
      if (left <= 0) _ticker?.cancel();
    }

    tick();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  bool get _expired => _step == _Step.enterCode && _secondsLeft <= 0;

  String _clock(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  void _changed(String _) {
    if (_submitted) setState(() {});
  }

  Future<void> _sendCode() async {
    setState(() => _submitted = true);
    if (_phoneController.text.trim().isEmpty) return;
    final problem = indianMobileError(_phoneController.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final api = ref.read(phoneApiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final deviceId = await ref.read(localDeviceIdProvider.future);
      final challenge = await api.requestChange(
        indianMobileDigits(_phoneController.text)!,
        deviceId: deviceId,
      );
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _step = _Step.enterCode;
        _submitted = false;
        _codeController.clear();
      });
      _startCountdown(challenge.expiresAt);
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _submitted = true);
    if (_codeController.text.trim().isEmpty) return;
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    final api = ref.read(phoneApiProvider);
    final challenge = _challenge;
    if (api == null || challenge == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final deviceId = await ref.read(localDeviceIdProvider.future);
      final hint = await api.confirmChange(
        challenge,
        code: code,
        deviceId: deviceId,
      );
      ref.invalidate(phoneStatusProvider);
      ref.invalidate(profileProvider);
      _ticker?.cancel();
      if (!mounted) return;
      setState(() {
        _savedHint = hint ?? challenge.phoneHint;
        _step = _Step.done;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userFacingErrorMessage(error);
          _codeController.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startOver() {
    _ticker?.cancel();
    setState(() {
      _step = _Step.enterPhone;
      _submitted = false;
      _challenge = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          widget.changing ? 'Change phone number' : 'Add phone number',
          style: BambooFonts.heading(19, color: BambooInk.ink900),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.xl),
          children: switch (_step) {
            _Step.enterPhone => _phoneStep(),
            _Step.enterCode => _codeStep(),
            _Step.done => _doneStep(),
          },
        ),
      ),
    );
  }

  List<Widget> _phoneStep() => [
    Text(
      widget.changing
          ? 'Enter your new mobile number. To confirm it’s you, we’ll email a code '
                'to your sign-in email. The old number is released as soon as the new '
                'one is saved.'
          : 'Enter your mobile number. To confirm it’s you, we’ll email a code to '
                'your sign-in email. We won’t text or call the number.',
      style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
    ),
    const SizedBox(height: AppSpace.xl),
    TextField(
      key: const Key('phone-change-field'),
      controller: _phoneController,
      enabled: !_busy,
      autofocus: true,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.telephoneNumber],
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9 +().-]')),
        LengthLimitingTextInputFormatter(20),
      ],
      onChanged: _changed,
      onSubmitted: (_) => _busy ? null : _sendCode(),
      style: BambooFonts.ui(16, color: BambooInk.ink900),
      decoration: InputDecoration(
        label: requiredLabel(
          widget.changing ? 'New mobile number' : 'Mobile number',
        ),
        prefixText: '+91  ',
        errorText: requiredError(_submitted, _phoneController.text) ?? _error,
        errorMaxLines: 4,
        border: const OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: AppSpace.lg),
    _primary(_busy ? 'Sending…' : 'Email me a code', _busy ? null : _sendCode),
  ];

  List<Widget> _codeStep() {
    final challenge = _challenge!;
    return [
      Text(
        'We emailed a 6-digit code to ${challenge.emailHint}. Enter it to save '
        '${challenge.phoneHint} on your account.',
        style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
      ),
      const SizedBox(height: AppSpace.sm),
      Text(
        _expired
            ? 'The code has expired.'
            : 'Code expires in ${_clock(_secondsLeft)}',
        key: const Key('phone-change-countdown'),
        style: BambooFonts.ui(
          13,
          weight: FontWeight.w600,
          color: _expired ? BambooInk.clay : BambooInk.ink700,
        ),
      ),
      const SizedBox(height: AppSpace.xl),
      TextField(
        key: const Key('phone-change-code'),
        controller: _codeController,
        enabled: !_busy,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        onChanged: _changed,
        onSubmitted: (_) => _busy || _expired ? null : _save(),
        decoration: InputDecoration(
          label: requiredLabel('Code from your email'),
          errorText: requiredError(_submitted, _codeController.text),
          border: const OutlineInputBorder(),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: AppSpace.md),
        Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clay)),
      ],
      const SizedBox(height: AppSpace.lg),
      if (_expired)
        _primary('Send a new code', _busy ? null : _startOver)
      else
        _primary(_busy ? 'Saving…' : 'Save number', _busy ? null : _save),
      TextButton(
        onPressed: _busy ? null : _startOver,
        child: const Text('Use a different number'),
      ),
    ];
  }

  List<Widget> _doneStep() => [
    const SizedBox(height: AppSpace.xl),
    const Icon(Icons.check_circle_rounded, size: 54, color: BambooInk.jade),
    const SizedBox(height: AppSpace.lg),
    Text(
      widget.changing ? 'Phone number changed' : 'Phone number saved',
      textAlign: TextAlign.center,
      style: BambooFonts.heading(22, color: BambooInk.ink900),
    ),
    const SizedBox(height: AppSpace.sm),
    Text(
      '$_savedHint is now on your account. We’ve emailed your sign-in address '
      'to let you know.',
      textAlign: TextAlign.center,
      style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
    ),
    const SizedBox(height: AppSpace.xl),
    _primary('Done', () => Navigator.of(context).pop(true)),
  ];

  Widget _primary(String label, VoidCallback? onPressed) {
    // 'Done' only closes the screen; every other step talks to the server.
    final offline = label != 'Done' && ref.watch(needsInternetProvider);
    return withNeedsInternetHint(
      offline,
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: BambooInk.slate,
          foregroundColor: BambooInk.lime,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        onPressed: offline ? null : onPressed,
        child: Text(label),
      ),
    );
  }
}
