import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// UA-3: phone+OTP sign-in against the real auth/ service — same flow as
/// console/lib/features/auth/login_screen.dart, same underlying service.
/// On success, ensures a profiles row exists (api/'s POST /profile is an
/// upsert) so UA-3's "signed in" state always has something for
/// profileProvider to actually fetch.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  bool _otpRequested = false;
  bool _loading = false;
  String? _error;

  Future<void> _requestOtp() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authApiProvider).requestOtp(_phoneController.text.trim());
      setState(() => _otpRequested = true);
    } catch (e) {
      setState(() => _error = e.toString());
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
      final tokens = await ref.read(authApiProvider).verifyOtp(
            _phoneController.text.trim(),
            _codeController.text.trim(),
            'app-mobile',
          );
      final store = await ref.read(tokenStoreProvider.future);
      await store.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
      ref.read(accessTokenProvider.notifier).state = tokens.accessToken;

      // Ensure a profiles row exists — see class doc.
      await ref.read(profileApiProvider)!.ensureProfile();
      ref.invalidate(profileProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Sign in', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            controller: _phoneController,
            enabled: !_otpRequested,
            decoration: const InputDecoration(labelText: 'Phone number', hintText: '+91XXXXXXXXXX'),
          ),
          if (_otpRequested) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(labelText: 'OTP code'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _loading ? null : (_otpRequested ? _verifyOtp : _requestOtp),
            child: Text(_loading ? 'Working...' : (_otpRequested ? 'Verify' : 'Send OTP')),
          ),
        ],
      ),
    );
  }
}
