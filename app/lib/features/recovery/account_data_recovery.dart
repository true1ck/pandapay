import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../app/env.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/auth_api.dart';
import '../../data/portable_backup/account_recovery_coordinator.dart';
import '../../data/portable_backup/account_recovery_repository.dart';
import 'automatic_account_recovery.dart';

String _account(String token) {
  try {
    final b = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    );
    final value = b['sub'];
    if (value is String &&
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(value)) {
      return value.toLowerCase();
    }
  } catch (_) {}
  throw StateError('Please sign in again to manage recovery copies.');
}

// A UX hint only. The backend verifies signature/current session and its
// own five-minute proof window on every operation, including key downloads.
bool _hasRecentFactor(String token) {
  try {
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    );
    final verified = claims['factor_verified_at'];
    final age =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 -
        (verified is int ? verified : 0);
    return const ['phone', 'email'].contains(claims['verified_channel']) &&
        verified is int &&
        age >= 0 &&
        age <= 240;
  } catch (_) {
    return false;
  }
}

Future<AccountRecoveryCoordinator> _coordinator(
  BuildContext context,
  WidgetRef ref,
  String token, {
  required bool beforeSignIn,
  String? recentProof,
  void Function(String)? onVerified,
}) async {
  final account = _account(token), initial = ref.read(accessTokenProvider);
  void check() {
    if (!context.mounted) throw StateError('Please reopen account recovery.');
    final current = ref.read(accessTokenProvider);
    if (beforeSignIn
        ? current != initial
        : current == null || _account(current) != account) {
      throw StateError('Your account changed. Please reopen account recovery.');
    }
  }

  check();
  final database = await ref.read(appDatabaseProvider.future);
  final root = await getApplicationDocumentsDirectory();
  check();
  return AccountRecoveryCoordinator(
    database: database,
    accountId: account,
    attachmentsDirectory: Directory(
      path.join(root.path, 'transaction_attachments', 'recovered'),
    ),
    enabled: Env.accountDataRecoveryEnabled,
    checkAccountUnchanged: check,
    verifyExistingOtp: () async {
      if (beforeSignIn) return AccountRecoveryVerifiedSession(account, token);
      if (recentProof != null &&
          _account(recentProof) == account &&
          _hasRecentFactor(recentProof)) {
        return AccountRecoveryVerifiedSession(account, recentProof);
      }
      final current = ref.read(accessTokenProvider);
      if (current != null &&
          _account(current) == account &&
          _hasRecentFactor(current)) {
        return AccountRecoveryVerifiedSession(account, current);
      }
      final verified = await Navigator.of(context).push<AuthTokens>(
        MaterialPageRoute(
          builder: (_) => _RecoveryOtpScreen(accountId: account),
        ),
      );
      check();
      if (verified == null) return null;
      if (_account(verified.accessToken) != account) {
        throw StateError(
          'Use a sign-in contact belonging to your current account.',
        );
      }
      // Keep this recent-proof credential in this page's memory only. Account
      // recovery must not race refresh/logout by replacing durable credentials.
      onVerified?.call(verified.accessToken);
      return AccountRecoveryVerifiedSession(account, verified.accessToken);
    },
    repository: (session) => AccountRecoveryRepository(
      apiBaseUrl: Uri.parse(Env.apiBaseUrl),
      accountId: account,
      accessToken: () async => session.accessToken,
      client: http.Client(),
      enabled: Env.accountDataRecoveryEnabled,
    ),
  );
}

/// Called after existing OTP sign-in and before publishing the session. There
/// are no uploads on this path. Failure leaves sign-in available through Skip.
Future<void> offerAccountDataRecovery(
  BuildContext context,
  WidgetRef ref,
  String verifiedAccessToken,
) async {
  if (!Env.accountDataRecoveryEnabled) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          AccountDataRecoveryScreen(verifiedAccessToken: verifiedAccessToken),
    ),
  );
}

class AccountDataRecoveryScreen extends ConsumerStatefulWidget {
  final String? verifiedAccessToken;
  const AccountDataRecoveryScreen({super.key, this.verifiedAccessToken});
  @override
  ConsumerState<AccountDataRecoveryScreen> createState() =>
      _AccountDataRecoveryScreenState();
}

class _AccountDataRecoveryScreenState
    extends ConsumerState<AccountDataRecoveryScreen> {
  bool _busy = false, _pendingConsent = false, _receipts = false;
  String? _message;
  String? _recentProof;
  List<AccountRecoverySnapshotInfo> _copies = const [];
  bool get _beforeSignIn => widget.verifiedAccessToken != null;
  Future<void> _run(
    Future<String?> Function(AccountRecoveryCoordinator) operation,
  ) async {
    if (_busy || !Env.accountDataRecoveryEnabled) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final token = widget.verifiedAccessToken ?? ref.read(accessTokenProvider);
      if (token == null) {
        throw StateError('Please sign in to manage recovery copies.');
      }
      final coordinator = await _coordinator(
        context,
        ref,
        token,
        beforeSignIn: _beforeSignIn,
        recentProof: _recentProof,
        onVerified: (value) {
          if (mounted) _recentProof = value;
        },
      );
      final result = await operation(coordinator);
      if (mounted && result != null) setState(() => _message = result);
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is StateError
              ? error.message
              : 'Recovery could not finish. Your existing local data and saved copies remain available.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Account data recovery'),
      automaticallyImplyLeading: !_busy,
    ),
    body: PopScope(
      canPop: !_busy,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Keep an encrypted recovery copy of data saved on this phone. Recover it using your existing phone or email sign-in. No new password is needed.',
          ),
          const SizedBox(height: 12),
          if (!Env.accountDataRecoveryEnabled)
            const Text('Account data recovery is not enabled for this release.')
          else ...[
            const Text(
              'Copies are limited in size and include data up to the time they are created. New changes need a new copy. Restore requires a fresh local account; it never replaces history already on this phone.',
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run((c) async {
                      final copies = await c.list();
                      if (copies == null) return null;
                      if (mounted) setState(() => _copies = copies);
                      return copies.isEmpty
                          ? 'No recovery copies are saved for this account.'
                          : '${copies.length} encrypted recovery copies available.';
                    }),
              child: const Text('Find my recovery copies'),
            ),
            if (!_beforeSignIn) ...[
              CheckboxListTile(
                value: _pendingConsent,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _pendingConsent = v ?? false),
                title: const Text(
                  'Include my account data and pending unsynced changes',
                ),
                subtitle: const Text(
                  'I agree to store this encrypted copy under my account.',
                ),
              ),
              CheckboxListTile(
                value: _receipts,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _receipts = v ?? false),
                title: const Text('Also include receipt files'),
              ),
              FilledButton(
                onPressed: _busy || !_pendingConsent
                    ? null
                    : () => _run((c) async {
                        final id = await c.create(
                          AccountRecoveryConsent(
                            includeReceipts: _receipts,
                            includeUnsynced: true,
                            explicitlyApproved: _pendingConsent,
                          ),
                        );
                        return id == null
                            ? null
                            : 'Recovery copy encrypted, uploaded and verified.';
                      }),
                child: const Text('Create encrypted recovery copy'),
              ),
              FilledButton.tonal(
                onPressed: _busy || !_pendingConsent
                    ? null
                    : () => _run((c) async {
                        final approved = await c.setAutomatic(
                          enabled: true,
                          includeReceipts: _receipts,
                        );
                        if (approved != true) return null;
                        ref.invalidate(automaticAccountRecoveryProvider);
                        return 'Automatic encrypted recovery enabled on this device. Updates run when the app is open and online, at most once every 15 minutes. No extra password is needed.';
                      }),
                child: const Text('Enable automatic recovery updates'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run((c) async {
                        final stopped = await c.setAutomatic(
                          enabled: false,
                          includeReceipts: false,
                        );
                        if (stopped != true) return null;
                        ref.invalidate(automaticAccountRecoveryProvider);
                        return 'Automatic recovery stopped on this device. Existing copies are kept.';
                      }),
                child: const Text('Stop automatic recovery updates'),
              ),
            ],
            for (final copy in _copies)
              Card(
                child: ListTile(
                  title: Text(copy.createdAt.toLocal().toString()),
                  subtitle: Text(
                    '${copy.encryptedBytes} encrypted bytes${copy.includeReceipts ? ' · receipts included' : ''}',
                  ),
                  trailing: TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            if (!await _confirm(
                              'Restore this copy?',
                              'Restore pending changes and saved account data into a fresh local account. Keep this screen open until recovery finishes.',
                            )) {
                              return;
                            }
                            if (!mounted) return;
                            await _run((c) async {
                              final restored = await c.restore(
                                copy.snapshotId,
                                explicitlyApproved: true,
                              );
                              return restored == true
                                  ? 'Recovery finished. Continue signing in.'
                                  : null;
                            });
                          },
                    child: const Text('Restore'),
                  ),
                ),
              ),
            if (!_beforeSignIn)
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        if (!await _confirm(
                          'Discard recovery copies?',
                          'Stop automatic recovery on all devices and remove encrypted recovery copies saved under this account. Data on this phone stays saved.',
                        )) {
                          return;
                        }
                        if (!mounted) return;
                        await _run((c) async {
                          final n = await c.discard(explicitlyApproved: true);
                          if (n != null && mounted) {
                            setState(() => _copies = const []);
                          }
                          return n == null
                              ? null
                              : 'Removed $n recovery copies.';
                        });
                      },
                child: const Text('Discard saved recovery copies'),
              ),
          ],
          if (_busy)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(_message!),
            ),
          if (_beforeSignIn)
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Continue signing in'),
            ),
        ],
      ),
    ),
  );
}

class _RecoveryOtpScreen extends ConsumerStatefulWidget {
  final String accountId;
  const _RecoveryOtpScreen({required this.accountId});
  @override
  ConsumerState<_RecoveryOtpScreen> createState() => _RecoveryOtpScreenState();
}

class _RecoveryOtpScreenState extends ConsumerState<_RecoveryOtpScreen> {
  final _contact = TextEditingController(), _code = TextEditingController();
  bool _sent = false, _busy = false, _email = true;
  OtpChallenge? _challenge;
  String? _error;
  Future<void> _request() async {
    if (_contact.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(authApiProvider),
          id = await ref.read(localDeviceIdProvider.future);
      final contact = _contact.text.trim();
      _email = contact.contains('@');
      _challenge = _email
          ? await api.requestEmailOtp(contact, deviceId: id, recoveryOnly: true)
          : await api.requestOtp(contact, deviceId: id, recoveryOnly: true);
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(authApiProvider),
          id = await ref.read(localDeviceIdProvider.future),
          info = await ref.read(deviceMetadataProvider.future);
      final tokens = _email
          ? await api.verifyEmailOtp(
              _contact.text.trim(),
              _code.text.trim(),
              id,
              recoveryOnly: true,
              challenge: _challenge,
              deviceInfo: info,
            )
          : await api.verifyOtp(
              _contact.text.trim(),
              _code.text.trim(),
              id,
              recoveryOnly: true,
              challenge: _challenge,
              deviceInfo: info,
            );
      if (_account(tokens.accessToken) != widget.accountId) {
        throw StateError('Use a contact belonging to your current account.');
      }
      if (mounted) Navigator.pop(context, tokens);
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _contact.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Verify your account')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Use your existing email or phone sign-in to manage encrypted recovery copies.',
        ),
        TextField(
          controller: _contact,
          enabled: !_sent && !_busy,
          decoration: const InputDecoration(
            labelText: 'Email address or phone number',
          ),
        ),
        if (_sent)
          TextField(
            controller: _code,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(
                ref.read(authApiProvider).otpCodeLength,
              ),
            ],
            decoration: const InputDecoration(labelText: 'Sign-in code'),
          ),
        FilledButton(
          onPressed: _busy ? null : (_sent ? _verify : _request),
          child: Text(_sent ? 'Verify code' : 'Send sign-in code'),
        ),
        if (_sent)
          TextButton(
            onPressed: _busy ? null : _request,
            child: const Text('Request another code'),
          ),
        if (_error != null) Text(_error!),
      ],
    ),
  );
}
