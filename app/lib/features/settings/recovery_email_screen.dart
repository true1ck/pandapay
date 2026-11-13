import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/needs_internet.dart';
import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/recovery_email_api.dart';
import '../auth/recovery_email_reminder.dart';

/// Add or change the recovery email: a second address that can get the person back
/// into the account if they lose their sign-in email.
///
/// Two codes are needed. One goes to the sign-in email, so a stolen session alone
/// cannot add its own recovery address; one goes to the new address, which proves
/// the person controls it. It is active as soon as both are right.
class RecoveryEmailScreen extends ConsumerStatefulWidget {
  const RecoveryEmailScreen({super.key, this.changing = false});

  /// True when an address already exists and is being replaced.
  final bool changing;

  @override
  ConsumerState<RecoveryEmailScreen> createState() => _RecoveryEmailScreenState();
}

enum _Step { enterEmail, enterCodes, done }

class _RecoveryEmailScreenState extends ConsumerState<RecoveryEmailScreen> {
  final _emailController = TextEditingController();
  final _signInCodeController = TextEditingController();
  final _recoveryCodeController = TextEditingController();
  _Step _step = _Step.enterEmail;
  bool _busy = false;
  String? _error;
  RecoveryEmailChallenge? _challenge;
  String? _savedHint;
  Timer? _ticker;
  int _secondsLeft = 0;

  @override
  void dispose() {
    _ticker?.cancel();
    _emailController.dispose();
    _signInCodeController.dispose();
    _recoveryCodeController.dispose();
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

  bool get _expired => _step == _Step.enterCodes && _secondsLeft <= 0;

  String? _emailProblem(String value) {
    final email = value.trim();
    if (email.isEmpty) return 'Enter an email address.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'That email address doesn’t look right.';
    }
    return null;
  }

  Future<void> _sendCodes() async {
    final problem = _emailProblem(_emailController.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final api = ref.read(recoveryEmailApiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final deviceId = await ref.read(accountDeviceIdProvider.future);
      final challenge = await api.requestChange(
        _emailController.text,
        deviceId: deviceId,
      );
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _step = _Step.enterCodes;
        _signInCodeController.clear();
        _recoveryCodeController.clear();
      });
      _startCountdown(challenge.expiresAt);
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final signIn = _signInCodeController.text.trim();
    final recovery = _recoveryCodeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(signIn) || !RegExp(r'^\d{6}$').hasMatch(recovery)) {
      setState(() => _error = 'Enter both 6-digit codes.');
      return;
    }
    final api = ref.read(recoveryEmailApiProvider);
    final challenge = _challenge;
    if (api == null || challenge == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final deviceId = await ref.read(accountDeviceIdProvider.future);
      final hint = await api.confirm(
        challenge,
        signInCode: signIn,
        recoveryCode: recovery,
        deviceId: deviceId,
      );
      ref.invalidate(recoveryEmailStatusProvider);
      await ref.read(recoveryEmailReminderStoreProvider).markAdded();
      _ticker?.cancel();
      if (!mounted) return;
      setState(() {
        _savedHint = hint ?? challenge.contactHint;
        _step = _Step.done;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userFacingErrorMessage(error);
          _signInCodeController.clear();
          _recoveryCodeController.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startOver() {
    _ticker?.cancel();
    setState(() {
      _step = _Step.enterEmail;
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
          widget.changing ? 'Change recovery email' : 'Add a recovery email',
          style: BambooFonts.heading(19, color: BambooInk.ink900),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.xl),
          children: switch (_step) {
            _Step.enterEmail => _emailStep(),
            _Step.enterCodes => _codesStep(),
            _Step.done => _doneStep(),
          },
        ),
      ),
    );
  }

  List<Widget> _emailStep() => [
    Text(
      'If you ever lose access to your sign-in email, this is how you get back in. '
      'We’ll send one code to your sign-in email, to confirm it’s you, and one to '
      'the address you enter here.',
      style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
    ),
    const SizedBox(height: AppSpace.xl),
    TextField(
      key: const Key('recovery-email-field'),
      controller: _emailController,
      enabled: !_busy,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.email],
      onSubmitted: (_) => _busy ? null : _sendCodes(),
      decoration: InputDecoration(
        labelText: 'Recovery email address',
        errorText: _error,
        errorMaxLines: 4,
        border: const OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: AppSpace.lg),
    _primary(_busy ? 'Sending…' : 'Send codes', _busy ? null : _sendCodes),
  ];

  List<Widget> _codesStep() {
    final challenge = _challenge!;
    return [
      Text(
        'Enter both codes. One went to your sign-in email, and one to '
        '${challenge.contactHint}.',
        style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
      ),
      const SizedBox(height: AppSpace.sm),
      Text(
        _expired
            ? 'The codes have expired.'
            : 'Codes expire in 0:${_secondsLeft.toString().padLeft(2, '0')}',
        key: const Key('recovery-email-countdown'),
        style: BambooFonts.ui(
          13,
          weight: FontWeight.w600,
          color: _expired ? BambooInk.clay : BambooInk.ink700,
        ),
      ),
      const SizedBox(height: AppSpace.xl),
      _codeField(
        const Key('recovery-signin-code'),
        _signInCodeController,
        'Code sent to your sign-in email',
        autofocus: true,
      ),
      const SizedBox(height: AppSpace.md),
      _codeField(
        const Key('recovery-new-code'),
        _recoveryCodeController,
        'Code sent to ${challenge.contactHint}',
      ),
      if (_error != null) ...[
        const SizedBox(height: AppSpace.md),
        Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clay)),
      ],
      const SizedBox(height: AppSpace.lg),
      if (_expired)
        _primary('Send new codes', _busy ? null : _startOver)
      else
        _primary(_busy ? 'Saving…' : 'Save recovery email', _busy ? null : _save),
      TextButton(
        onPressed: _busy ? null : _startOver,
        child: const Text('Use a different address'),
      ),
    ];
  }

  List<Widget> _doneStep() => [
    const SizedBox(height: AppSpace.xl),
    const Icon(Icons.verified_rounded, size: 54, color: BambooInk.jade),
    const SizedBox(height: AppSpace.lg),
    Text(
      'Recovery email saved',
      textAlign: TextAlign.center,
      style: BambooFonts.heading(22, color: BambooInk.ink900),
    ),
    const SizedBox(height: AppSpace.sm),
    Text(
      '$_savedHint is now your recovery email. We’ve emailed your sign-in address '
      'to let you know.',
      textAlign: TextAlign.center,
      style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
    ),
    const SizedBox(height: AppSpace.xl),
    _primary('Done', () => Navigator.of(context).pop(true)),
  ];

  Widget _codeField(Key key, TextEditingController controller, String label, {bool autofocus = false}) {
    return TextField(
      key: key,
      controller: controller,
      enabled: !_busy,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(6),
      ],
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }

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
