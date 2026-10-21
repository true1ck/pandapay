import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/product_access_api.dart';

/// Captures invite links before authentication. The link itself grants
/// nothing; the code is only previewed and submitted after OTP verification.
class InviteLinkScreen extends ConsumerStatefulWidget {
  const InviteLinkScreen({required this.code, super.key});

  final String code;

  @override
  ConsumerState<InviteLinkScreen> createState() => _InviteLinkScreenState();
}

class _InviteLinkScreenState extends ConsumerState<InviteLinkScreen> {
  bool _loading = true;
  bool _conflict = false;
  String? _savedCode;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_capture());
  }

  Future<void> _capture() async {
    try {
      final store = await ref.read(pendingInvitationStoreProvider.future);
      final result = await store.capture(widget.code);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _conflict = result?.status == InvitationCaptureStatus.conflict;
        _savedCode = result?.existingCode ?? result?.code;
        _error = result == null ? 'This invite link is not valid.' : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'We couldn’t save this invite yet. Please try again.';
      });
    }
  }

  Future<void> _replaceWithLinkCode() async {
    final store = await ref.read(pendingInvitationStoreProvider.future);
    final code = await store.replace(widget.code);
    if (!mounted) return;
    setState(() {
      _conflict = false;
      _savedCode = code;
      _error = code == null ? 'This invite link is not valid.' : null;
    });
  }

  @override
  Widget build(BuildContext context) => AppBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'You’re invited',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(
                          Icons.redeem_outlined,
                          size: 52,
                          color: BambooInk.jade,
                        ),
                        const SizedBox(height: AppSpace.lg),
                        Text(
                          _conflict
                              ? 'Another invite is already saved'
                              : 'Your invite is saved on this device',
                          textAlign: TextAlign.center,
                          style: BambooFonts.heading(
                            24,
                            color: BambooInk.ink900,
                          ),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        Text(
                          _conflict
                              ? 'Saved code $_savedCode stays in place unless you choose to replace it with ${widget.code}.'
                              : _error ??
                                  'We’ll check this code after you verify your account. It does not activate access by itself.',
                          textAlign: TextAlign.center,
                          style: BambooFonts.ui(14, color: BambooInk.ink700),
                        ),
                        if (_conflict) ...[
                          const SizedBox(height: AppSpace.lg),
                          OutlinedButton(
                            onPressed: () => context.go(AppRoute.signUp),
                            child: Text('Keep $_savedCode'),
                          ),
                          FilledButton(
                            onPressed: _replaceWithLinkCode,
                            child: Text('Use ${widget.code} instead'),
                          ),
                        ] else if (_error != null) ...[
                          const SizedBox(height: AppSpace.lg),
                          OutlinedButton(
                            onPressed: () => context.go(AppRoute.signUp),
                            child: const Text('Enter an invite code'),
                          ),
                        ],
                        const Spacer(),
                        if (!_conflict)
                          FilledButton(
                            onPressed: _error == null
                                ? () => context.go(AppRoute.signUp)
                                : null,
                            child: const Text('Create account'),
                          ),
                        const SizedBox(height: AppSpace.sm),
                        TextButton(
                          onPressed: () => context.go(AppRoute.logIn),
                          child: const Text('Already have an account? Sign in'),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    ),
  );
}
