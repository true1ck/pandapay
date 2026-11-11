import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/account_recovery_api.dart';
import '../../data/api_exception.dart';
import '../settings/feedback_support_screen.dart';
import 'phone_input.dart';
import 'recovery_hold_store.dart';

/// Checks the one fact a person can give from their own account: the last four digits
/// of a card, or (with no cards) the month they signed up, as `11/2026` or `2026-11`.
/// The server decides which of the two it needs and is the only judge.
String? recoveryFactProblem(String raw) {
  final value = raw.trim();
  if (value.isEmpty) {
    return 'Enter the last four digits of a card, or your sign-up month.';
  }
  if (RegExp(r'^\d{4}$').hasMatch(value)) return null;
  final match = RegExp(
    r'^(?:(\d{4})[-/](\d{1,2})|(\d{1,2})[-/](\d{4}))$',
  ).firstMatch(value);
  if (match == null) return 'Enter 4 digits, or a month like 11/2026.';
  final year = int.parse(match.group(1) ?? match.group(4)!);
  final month = int.parse(match.group(2) ?? match.group(3)!);
  if (month < 1 || month > 12 || year < 2020 || year > 2100) {
    return 'That month doesn’t look right. Use a form like 11/2026.';
  }
  return null;
}

enum _Step { details, code, newEmail, newCode, waiting, done }

/// "Can't sign in?" The recovery that replaces guessing the last digits of a phone.
///
/// Four proofs are asked together: the sign-in email that was lost, the phone number
/// saved at sign-up, one fact from the person's own account, and, if the account has
/// a recovery email, a code sent there. The first step answers the same whether or
/// not anything matched, so this screen never says which part was wrong.
///
/// With a recovery email the person is back in at once, other devices are signed out,
/// and the old addresses get a link to undo it. Without one, the change waits 24
/// hours and the old address can cancel it; this screen then resumes from where it
/// was left, from a token kept in secure storage.
class CantSignInScreen extends ConsumerStatefulWidget {
  const CantSignInScreen({super.key});

  @override
  ConsumerState<CantSignInScreen> createState() => _CantSignInScreenState();
}

class _CantSignInScreenState extends ConsumerState<CantSignInScreen> {
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _factController = TextEditingController();
  final _codeController = TextEditingController();
  final _newEmailController = TextEditingController();
  final _newCodeController = TextEditingController();

  _Step _step = _Step.details;
  bool _busy = false;
  bool _loadingHold = true;
  String? _error;
  String? _attemptId;
  int _codeLength = 6;
  bool _canUseRecoveryEmail = false;
  bool _slowPath = false;
  String? _newEmailHint;
  RecoveryHold? _hold;
  bool _startOver = false;
  Timer? _ticker;
  int _secondsLeft = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_resumeSavedHold());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final c in [
      _emailController,
      _phoneController,
      _factController,
      _codeController,
      _newEmailController,
      _newCodeController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _resumeSavedHold() async {
    final hold = await ref.read(recoveryHoldStoreProvider).load();
    if (!mounted) return;
    setState(() {
      _loadingHold = false;
      if (hold != null) {
        _hold = hold;
        _step = _Step.waiting;
      }
    });
  }

  void _startCountdown(Duration lifetime) {
    _ticker?.cancel();
    final until = DateTime.now().add(lifetime);
    void tick() {
      final left = until.difference(DateTime.now()).inSeconds;
      if (!mounted) return;
      setState(() => _secondsLeft = left < 0 ? 0 : left);
      if (left <= 0) _ticker?.cancel();
    }

    tick();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  bool get _codeExpired =>
      (_step == _Step.code || _step == _Step.newCode) && _secondsLeft <= 0;

  Future<T?> _guard<T>(Future<T> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
      _startOver = false;
    });
    try {
      return await work();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = userFacingErrorMessage(error);
          _startOver = error is RecoveryFailure && error.startOver;
        });
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------- the steps

  Future<void> _submitDetails() async {
    final email = _emailController.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Enter the email address you used to sign in.');
      return;
    }
    final phone = indianMobileDigits(_phoneController.text);
    if (phone == null) {
      setState(() => _error = indianMobileError(_phoneController.text));
      return;
    }
    final factProblem = recoveryFactProblem(_factController.text);
    if (factProblem != null) {
      setState(() => _error = factProblem);
      return;
    }
    final started = await _guard(() async {
      final deviceId = await ref.read(accountDeviceIdProvider.future);
      return ref
          .read(accountRecoveryApiProvider)
          .start(
            lostEmail: email,
            phone: '+91$phone',
            fact: _factController.text,
            deviceId: deviceId,
          );
    });
    if (started == null || !mounted) return;
    setState(() {
      _attemptId = started.attemptId;
      _codeLength = started.codeLength;
      _codeController.clear();
      _step = _Step.code;
    });
    _startCountdown(started.codeLifetime);
  }

  Future<void> _submitCode() async {
    final code = _codeController.text.trim();
    if (code.length != _codeLength) {
      setState(() => _error = 'Enter the $_codeLength-digit code.');
      return;
    }
    final ok = await _guard(() async {
      await ref
          .read(accountRecoveryApiProvider)
          .verifyCode(
            attemptId: _attemptId!,
            code: code,
            deviceId: await ref.read(accountDeviceIdProvider.future),
          );
      return true;
    });
    if (ok != true || !mounted) return;
    _ticker?.cancel();
    setState(() {
      _canUseRecoveryEmail = true;
      _slowPath = false;
      _step = _Step.newEmail;
    });
  }

  Future<void> _noRecoveryEmail() async {
    final ok = await _guard(() async {
      await ref
          .read(accountRecoveryApiProvider)
          .noRecoveryEmail(
            attemptId: _attemptId!,
            deviceId: await ref.read(accountDeviceIdProvider.future),
          );
      return true;
    });
    if (ok != true || !mounted) return;
    _ticker?.cancel();
    setState(() {
      _canUseRecoveryEmail = false;
      _slowPath = true;
      _step = _Step.newEmail;
    });
  }

  Future<void> _submitNewEmail({bool useRecoveryEmail = false}) async {
    final email = _newEmailController.text.trim();
    if (!useRecoveryEmail &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(
        () => _error =
            'Enter the email address you want to sign in with from now on.',
      );
      return;
    }
    final result = await _guard(() async {
      final deviceId = await ref.read(accountDeviceIdProvider.future);
      final api = ref.read(accountRecoveryApiProvider);
      final set = await api.setNewEmail(
        attemptId: _attemptId!,
        deviceId: deviceId,
        newEmail: useRecoveryEmail ? null : email,
        useRecoveryEmail: useRecoveryEmail,
      );
      if (set.needsCode) return (set: set, outcome: null);
      return (
        set: set,
        outcome: await api.complete(attemptId: _attemptId!, deviceId: deviceId),
      );
    });
    if (result == null || !mounted) return;
    if (result.outcome != null) {
      await _finishWith(result.outcome!, hint: result.set.hint);
      return;
    }
    setState(() {
      _newEmailHint = result.set.hint ?? email;
      _newCodeController.clear();
      _step = _Step.newCode;
    });
    _startCountdown(const Duration(seconds: 60));
  }

  Future<void> _submitNewCode() async {
    final code = _newCodeController.text.trim();
    if (code.length != _codeLength) {
      setState(() => _error = 'Enter the $_codeLength-digit code.');
      return;
    }
    final outcome = await _guard(
      () async => ref
          .read(accountRecoveryApiProvider)
          .complete(
            attemptId: _attemptId!,
            deviceId: await ref.read(accountDeviceIdProvider.future),
            code: code,
          ),
    );
    if (outcome == null || !mounted) return;
    await _finishWith(outcome, hint: _newEmailHint);
  }

  Future<void> _finishHeldRecovery() async {
    final hold = _hold;
    if (hold == null) return;
    final outcome = await _guard(
      () async => ref
          .read(accountRecoveryApiProvider)
          .finish(
            attemptId: hold.attemptId,
            deviceId: await ref.read(accountDeviceIdProvider.future),
            resumeToken: hold.resumeToken,
          ),
    );
    if (!mounted) return;
    if (outcome == null) {
      // A refusal that means "this attempt is gone" ends the saved hold; "too early"
      // keeps it and the message already says when it ends.
      if (_startOver) {
        await ref.read(recoveryHoldStoreProvider).clear();
        if (mounted) setState(() => _hold = null);
      }
      return;
    }
    await _finishWith(outcome, hint: hold.newEmailHint);
  }

  /// A session means the person is back in; a hold means come back after it.
  Future<void> _finishWith(
    RecoveryOutcome outcome, {
    required String? hint,
  }) async {
    _ticker?.cancel();
    // Taken before any await: the container outlives this screen, `context` may not.
    final container = ProviderScope.containerOf(context, listen: false);
    final holdStore = ref.read(recoveryHoldStoreProvider);
    if (outcome.pending) {
      final hold = RecoveryHold(
        attemptId: _attemptId!,
        resumeToken: outcome.resumeToken!,
        holdUntil: outcome.holdUntil!,
        newEmailHint: hint ?? '',
      );
      await holdStore.save(hold);
      if (!mounted) return;
      setState(() {
        _hold = hold;
        _step = _Step.waiting;
      });
      return;
    }
    await holdStore.clear();
    final tokens = outcome.tokens!;
    final store = await container.read(tokenStoreProvider.future);
    await store.save(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    if (mounted) setState(() => _step = _Step.done);
    // Publishing the token swaps the signed-out screens for the app. The container
    // outlives this screen, so nothing after this line reads `ref`.
    container.read(accessTokenProvider.notifier).state = tokens.accessToken;
    container.invalidate(profileProvider);
  }

  void _restart() {
    _ticker?.cancel();
    setState(() {
      _step = _Step.details;
      _attemptId = null;
      _error = null;
      _startOver = false;
    });
  }

  Future<void> _forgetHold() async {
    await ref.read(recoveryHoldStoreProvider).clear();
    if (mounted) {
      setState(() {
        _hold = null;
        _step = _Step.details;
        _error = null;
      });
    }
  }

  // ------------------------------------------------------------------ build

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
          'Can’t sign in?',
          style: BambooFonts.heading(19, color: BambooInk.ink900),
        ),
      ),
      body: SafeArea(
        child: _loadingHold
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(AppSpace.xl),
                children: switch (_step) {
                  _Step.details => _detailsStep(),
                  _Step.code => _codeStep(),
                  _Step.newEmail => _newEmailStep(),
                  _Step.newCode => _newCodeStep(),
                  _Step.waiting => _waitingStep(),
                  _Step.done => _doneStep(),
                },
              ),
      ),
    );
  }

  Widget _intro(String text) => Text(
    text,
    style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
  );

  Widget _errorLine() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: AppSpace.md),
          child: Text(
            _error!,
            key: const Key('recovery-error'),
            style: BambooFonts.ui(13, color: BambooInk.clay, height: 1.4),
          ),
        );

  List<Widget> _detailsStep() => [
    _intro(
      'PandaPay has no password, so we check that you are you in four ways. '
      'Fill in what you have; we’ll ask for the rest on the next screens.',
    ),
    const SizedBox(height: AppSpace.xl),
    TextField(
      key: const Key('recovery-lost-email'),
      controller: _emailController,
      enabled: !_busy,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.email],
      decoration: const InputDecoration(
        labelText: 'Your sign-in email',
        helperText: 'The address you can no longer open.',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: AppSpace.lg),
    TextField(
      key: const Key('recovery-phone'),
      controller: _phoneController,
      enabled: !_busy,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.telephoneNumber],
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9 +().-]')),
        LengthLimitingTextInputFormatter(20),
      ],
      decoration: const InputDecoration(
        labelText: 'Mobile number on your account',
        prefixText: '+91  ',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: AppSpace.lg),
    TextField(
      key: const Key('recovery-fact'),
      controller: _factController,
      enabled: !_busy,
      keyboardType: TextInputType.datetime,
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9/-]')),
        LengthLimitingTextInputFormatter(7),
      ],
      onSubmitted: (_) => _busy ? null : _submitDetails(),
      decoration: const InputDecoration(
        labelText: 'Card last 4 digits, or sign-up month',
        helperText:
            'The last four digits of a card in your wallet. If you have no '
            'cards, the month you signed up, like 11/2026.',
        helperMaxLines: 3,
        border: OutlineInputBorder(),
      ),
    ),
    _errorLine(),
    const SizedBox(height: AppSpace.lg),
    _primary(_busy ? 'Checking…' : 'Continue', _busy ? null : _submitDetails),
    const SizedBox(height: AppSpace.md),
    TextButton(
      onPressed: _busy ? null : _contactSupport,
      child: const Text('I can’t answer these. Contact support'),
    ),
  ];

  void _contactSupport() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const FeedbackSupportScreen()),
  );

  List<Widget> _codeStep() => [
    _intro(
      'If you added a recovery email to your account, we sent a code to it. Enter it '
      'here. Check that inbox, including spam.',
    ),
    const SizedBox(height: AppSpace.sm),
    _countdownText(),
    const SizedBox(height: AppSpace.xl),
    _codeField(
      const Key('recovery-code'),
      _codeController,
      'Code from your recovery email',
      autofocus: true,
    ),
    _errorLine(),
    const SizedBox(height: AppSpace.lg),
    if (_codeExpired)
      _primary('Start again', _busy ? null : _restart)
    else
      _primary(_busy ? 'Checking…' : 'Continue', _busy ? null : _submitCode),
    const SizedBox(height: AppSpace.md),
    TextButton(
      key: const Key('recovery-no-recovery-email'),
      onPressed: _busy ? null : _noRecoveryEmail,
      child: const Text('I don’t have a recovery email'),
    ),
    if (_startOver)
      TextButton(onPressed: _restart, child: const Text('Start over')),
  ];

  List<Widget> _newEmailStep() => [
    _intro(
      _slowPath
          ? 'Which email should you sign in with from now on? For your safety, without '
                'a recovery email this takes 24 hours. We’ll email your old address so '
                'its owner can cancel it.'
          : 'You’re verified. Which email should you sign in with from now on?',
    ),
    const SizedBox(height: AppSpace.xl),
    TextField(
      key: const Key('recovery-new-email'),
      controller: _newEmailController,
      enabled: !_busy,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.email],
      onSubmitted: (_) => _busy ? null : _submitNewEmail(),
      decoration: const InputDecoration(
        labelText: 'New sign-in email',
        border: OutlineInputBorder(),
      ),
    ),
    _errorLine(),
    const SizedBox(height: AppSpace.lg),
    _primary(
      _busy ? 'Sending…' : 'Send code',
      _busy ? null : () => _submitNewEmail(),
    ),
    if (_canUseRecoveryEmail) ...[
      const SizedBox(height: AppSpace.md),
      TextButton(
        key: const Key('recovery-use-recovery-email'),
        onPressed: _busy ? null : () => _submitNewEmail(useRecoveryEmail: true),
        child: const Text('Use my recovery email to sign in'),
      ),
    ],
    if (_startOver)
      TextButton(onPressed: _restart, child: const Text('Start over')),
  ];

  List<Widget> _newCodeStep() => [
    _intro('We sent a code to $_newEmailHint. Enter it to finish.'),
    const SizedBox(height: AppSpace.sm),
    _countdownText(),
    const SizedBox(height: AppSpace.xl),
    _codeField(
      const Key('recovery-new-code'),
      _newCodeController,
      'Code sent to $_newEmailHint',
      autofocus: true,
    ),
    _errorLine(),
    const SizedBox(height: AppSpace.lg),
    if (_codeExpired)
      _primary(
        'Use a different email',
        _busy
            ? null
            : () => setState(() {
                _step = _Step.newEmail;
                _error = null;
              }),
      )
    else
      _primary(_busy ? 'Finishing…' : 'Finish', _busy ? null : _submitNewCode),
    if (_startOver)
      TextButton(onPressed: _restart, child: const Text('Start over')),
  ];

  List<Widget> _waitingStep() {
    final hold = _hold;
    if (hold == null) {
      return [
        _intro(
          'That recovery is no longer waiting. It may have been cancelled from your old email.',
        ),
        const SizedBox(height: AppSpace.xl),
        _primary('Start again', _forgetHold),
      ];
    }
    final over = hold.isOver(DateTime.now());
    final when = _formatWhen(context, hold.holdUntil);
    return [
      const SizedBox(height: AppSpace.lg),
      const Icon(
        Icons.hourglass_top_rounded,
        size: 48,
        color: BambooInk.ink700,
      ),
      const SizedBox(height: AppSpace.lg),
      Text(
        over ? 'Ready to finish' : 'Your recovery is waiting',
        textAlign: TextAlign.center,
        style: BambooFonts.heading(22, color: BambooInk.ink900),
      ),
      const SizedBox(height: AppSpace.sm),
      Text(
        over
            ? 'The 24 hours are up. Finish now to sign in with ${hold.newEmailHint}.'
            : 'For your safety it finishes at $when. We emailed your old address so its '
                  'owner can cancel it. Come back to this screen then and finish.',
        key: const Key('recovery-waiting-text'),
        textAlign: TextAlign.center,
        style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
      ),
      _errorLine(),
      const SizedBox(height: AppSpace.xl),
      _primary(
        _busy ? 'Finishing…' : 'Finish recovery',
        _busy || !over ? null : _finishHeldRecovery,
      ),
      const SizedBox(height: AppSpace.md),
      TextButton(
        onPressed: _busy ? null : _forgetHold,
        child: const Text('Forget this and start again'),
      ),
    ];
  }

  List<Widget> _doneStep() => [
    const SizedBox(height: AppSpace.xl),
    const Icon(Icons.verified_rounded, size: 54, color: BambooInk.jade),
    const SizedBox(height: AppSpace.lg),
    Text(
      'You’re back in',
      textAlign: TextAlign.center,
      style: BambooFonts.heading(22, color: BambooInk.ink900),
    ),
    const SizedBox(height: AppSpace.sm),
    Text(
      'Your other devices were signed out, and your old email was told. Sign in with '
      'your new email next time.',
      textAlign: TextAlign.center,
      style: BambooFonts.ui(14, color: BambooInk.ink500, height: 1.5),
    ),
  ];

  Widget _countdownText() => Text(
    _codeExpired
        ? 'The code has expired.'
        : 'Code expires in 0:${_secondsLeft.toString().padLeft(2, '0')}',
    key: const Key('recovery-countdown'),
    style: BambooFonts.ui(
      13,
      weight: FontWeight.w600,
      color: _codeExpired ? BambooInk.clay : BambooInk.ink700,
    ),
  );

  Widget _codeField(
    Key key,
    TextEditingController controller,
    String label, {
    bool autofocus = false,
  }) {
    return TextField(
      key: key,
      controller: controller,
      enabled: !_busy,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(_codeLength),
      ],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _primary(String label, VoidCallback? onPressed) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: BambooInk.slate,
      foregroundColor: BambooInk.lime,
      minimumSize: const Size.fromHeight(52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}

/// "Mon, 10 Nov, 3:20 PM" in the person's own clock and locale.
String _formatWhen(BuildContext context, DateTime when) {
  final l10n = MaterialLocalizations.of(context);
  return '${l10n.formatMediumDate(when)}, ${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(when))}';
}
