import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-0.3.1: email+password in the plan; this build uses the same OTP flow
/// as the user app instead, since that's what auth/ actually implements —
/// whether the resulting session is an operator is decided entirely by
/// api/'s requireAdmin server-side (see providers.dart isAdminProvider),
/// there is no separate admin login path or elevated trust client-side.
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
      setState(() => _loading = false);
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
            'console-web',
          );
      final store = await ref.read(tokenStoreProvider.future);
      await store.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
      ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('PandaPay Console', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Internal only. No public signup path exists.',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 24),
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
          ),
        ),
      ),
    );
  }
}
