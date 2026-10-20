import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Sign-in uses the existing phone or email OTP routes. Whether the resulting
/// session is an operator is decided by api/'s requireAdmin server-side, not
/// by any client-side role flag.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  bool _useEmail = true;
  bool _otpRequested = false;
  bool _loading = false;
  String? _error;

  Future<void> _requestOtp() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_useEmail) {
        await ref.read(authApiProvider).requestEmailOtp(_emailController.text.trim());
      } else {
        await ref.read(authApiProvider).requestOtp(_phoneController.text.trim());
      }
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
      final authApi = ref.read(authApiProvider);
      final tokens = _useEmail
          ? await authApi.verifyEmailOtp(
              _emailController.text.trim(),
              _codeController.text.trim(),
              'console-web',
            )
          : await authApi.verifyOtp(
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
                if (!_otpRequested)
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Email')),
                      ButtonSegment(value: false, label: Text('Phone')),
                    ],
                    selected: {_useEmail},
                    onSelectionChanged: (selection) =>
                        setState(() => _useEmail = selection.first),
                  ),
                if (!_otpRequested) const SizedBox(height: 12),
                TextField(
                  controller: _useEmail ? _emailController : _phoneController,
                  enabled: !_otpRequested,
                  keyboardType: _useEmail
                      ? TextInputType.emailAddress
                      : TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: _useEmail ? 'Account email' : 'Phone number',
                    hintText: _useEmail ? 'you@example.com' : '+91XXXXXXXXXX',
                  ),
                ),
                if (_otpRequested) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Enter the code sent to your ${_useEmail ? 'email' : 'phone'}.',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  TextField(
                    controller: _codeController,
                    decoration: const InputDecoration(labelText: 'OTP code'),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => setState(() {
                              _otpRequested = false;
                              _codeController.clear();
                              _error = null;
                            }),
                    child: const Text('Use a different account'),
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

  @override
  void dispose() {
    _phoneController.dispose();
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }
}
