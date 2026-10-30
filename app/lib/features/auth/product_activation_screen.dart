import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/product_access_api.dart';
import '../onboarding/onboarding_back.dart';

/// Server-backed account activation after OTP verification. The route is also
/// the cold-start gate for signed-in accounts whose local onboarding is not
/// complete, so a process restart cannot skip invitation activation.
class ProductActivationScreen extends ConsumerStatefulWidget {
  const ProductActivationScreen({super.key});

  @override
  ConsumerState<ProductActivationScreen> createState() =>
      _ProductActivationScreenState();
}

class _ProductActivationScreenState
    extends ConsumerState<ProductActivationScreen> {
  final _codeController = TextEditingController();

  ProductAccessPolicy? _policy;
  ProductAccessState? _access;
  InvitationPreview? _preview;
  PendingSignupChoices? _signupChoices;
  bool _loading = true;
  bool _working = false;
  bool _productTermsAccepted = false;
  String? _selectedRewardChoice;
  String? _error;
  String? _codeConflict;
  String? _pendingCode;
  String? _activatedCode;

  ProductAccessRepository? get _api => ref.read(productAccessApiProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = _api;
      if (api == null) throw StateError('Please sign in to continue.');
      final invitationStore = await ref.read(
        pendingInvitationStoreProvider.future,
      );
      final signupStore = await ref.read(
        pendingSignupChoicesStoreProvider.future,
      );
      final pendingCode = await invitationStore.read();
      final signupChoices = await signupStore.read();
      final policy = await api.loadPolicy();
      final access = await api.loadAccess();
      if (!mounted) return;
      setState(() {
        _policy = policy;
        _access = access;
        _signupChoices = signupChoices;
        _productTermsAccepted = signupChoices?.acceptProductTerms ?? false;
        _pendingCode = pendingCode;
        _codeController.text = pendingCode ?? '';
        _loading = false;
        _error = null;
      });

      if (access.isActive) {
        if (signupChoices != null) {
          // The server may have committed activation just before the app was
          // closed. Only finish the saved A4 audit writes; never replay an
          // invite against an already-active account.
          await _finishActivation(invitationApplied: pendingCode != null);
        } else {
          final consents = ref.read(consentsApiProvider);
          if (consents != null) {
            try {
              final latest = await consents.fetchLatest();
              final hasTerms = latest.any(
                (c) => c.purpose == 'terms' && c.granted && c.revokedAt == null,
              );
              if (!hasTerms) {
                await consents.submit(
                  purpose: 'terms',
                  granted: true,
                  policyVersion: appProductTermsVersion,
                  sourceScreen: 'product_activation',
                );
              }
            } catch (_) {}
          }
          _markGateAndContinue();
        }
        return;
      }
      if (pendingCode != null) await _previewCode(pendingCode);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingErrorMessage(error);
      });
    }
  }

  Future<void> _retry() async {
    if (_working) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _load();
  }

  Future<void> _previewCode([String? suppliedCode]) async {
    final raw = suppliedCode ?? _codeController.text;
    final code = PendingInvitationStore.normalizeCode(raw);
    if (code == null) {
      setState(() {
        _preview = null;
        _selectedRewardChoice = null;
        _error = 'Enter the invite code from your link.';
      });
      return;
    }

    setState(() {
      _working = true;
      _error = null;
      _preview = null;
      _selectedRewardChoice = null;
      _codeConflict = null;
    });
    try {
      final store = await ref.read(pendingInvitationStoreProvider.future);
      final captured = await store.capture(code);
      if (captured == null) {
        throw const FormatException('Enter a valid invite code.');
      }
      if (captured.status == InvitationCaptureStatus.conflict) {
        setState(() {
          _codeConflict = captured.existingCode;
          _pendingCode = captured.existingCode;
          _error = null;
        });
        return;
      }

      final api = _api;
      if (api == null) throw StateError('Please sign in to continue.');
      final preview = await api.validateInvitation(code);
      if (!mounted) return;
      setState(() {
        _pendingCode = code;
        _codeController.text = code;
        _preview = preview;
        _error = preview == null
            ? 'We couldn’t verify that invite code. Check it and try again.'
            : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _useSavedCode() async {
    final saved = _codeConflict;
    if (saved == null) return;
    setState(() {
      _codeController.text = saved;
      _pendingCode = saved;
      _codeConflict = null;
    });
    await _previewCode(saved);
  }

  Future<void> _replaceSavedCode() async {
    final code = PendingInvitationStore.normalizeCode(_codeController.text);
    if (code == null) {
      setState(() => _error = 'Enter a valid invite code.');
      return;
    }
    final store = await ref.read(pendingInvitationStoreProvider.future);
    await store.replace(
      code,
    ); // Explicit user choice; never an implicit overwrite.
    setState(() {
      _codeConflict = null;
      _pendingCode = code;
    });
    await _previewCode(code);
  }

  bool get _canActivate {
    if (_working || !_productTermsAccepted) return false;
    if (_preview != null) return _selectedRewardChoice != null;
    return _pendingCode == null && _policy?.isOpen == true;
  }

  Future<void> _activate() async {
    if (!_canActivate) return;
    final api = _api;
    if (api == null) {
      setState(() => _error = 'Please sign in to continue.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final preview = _preview;
      final choice = _selectedRewardChoice;
      final choices = _signupChoices;
      final termsVersion =
          choices?.productTermsVersion ?? appProductTermsVersion;
      await api.activate(
        invitationCode: preview?.code,
        invitationPreviewToken: preview?.previewToken,
        // False and unselected are not serialized as consent. The server
        // receives only the explicit choice made on this screen.
        acceptRewardTerms: choice == 'rewards' ? true : null,
        acceptAccessOnly: choice == 'access_only' ? true : null,
        acceptProductTerms: _productTermsAccepted ? true : null,
        productTermsVersion: _productTermsAccepted ? termsVersion : null,
      );
      _activatedCode = preview?.code;
      final access = await api.loadAccess();
      if (!access.isActive) {
        throw StateError('Your account is not active yet. Please try again.');
      }
      if (!mounted) return;
      setState(() => _access = access);
      await _finishActivation(invitationApplied: preview != null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _finishActivation({required bool invitationApplied}) async {
    if (_signupChoices != null) {
      await _recordA4Consents(_signupChoices!);
    }
    if (invitationApplied && _activatedCode != null) {
      final store = await ref.read(pendingInvitationStoreProvider.future);
      await store.clearIfMatches(_activatedCode!);
    } else if (invitationApplied && _pendingCode != null) {
      final store = await ref.read(pendingInvitationStoreProvider.future);
      await store.clearIfMatches(_pendingCode!);
    }
    _markGateAndContinue();
  }

  Future<void> _recordA4Consents(PendingSignupChoices initial) async {
    final store = await ref.read(pendingSignupChoicesStoreProvider.future);
    var choices = await store.read() ?? initial;
    final consents = ref.read(consentsApiProvider);
    if (consents == null) {
      throw StateError('We couldn’t save your sign-up choices. Please retry.');
    }
    final records = <(String, bool)>[
      ('terms', choices.acceptProductTerms),
      ('crowdsource', choices.optInCrowdsource),
      ('marketing', choices.optInMarketing),
    ];
    for (final (purpose, granted) in records) {
      if (choices.recordedPurposes.contains(purpose)) continue;
      await consents.submit(
        purpose: purpose,
        granted: granted,
        policyVersion: choices.productTermsVersion,
        sourceScreen: 'A4',
      );
      await store.markPurposeRecorded(purpose);
      choices = choices.withRecordedPurpose(purpose);
      _signupChoices = choices;
    }
    if (choices.optInCrowdsource &&
        !choices.recordedPurposes.contains('crowdsource_live_flag')) {
      final cardsRepository = ref.read(userCardsRepositoryProvider);
      if (cardsRepository == null) {
        throw StateError(
          'We couldn’t save your merchant-data choice. Please retry.',
        );
      }
      await cardsRepository.setContributionsOptIn(true);
      await store.markPurposeRecorded('crowdsource_live_flag');
      choices = choices.withRecordedPurpose('crowdsource_live_flag');
      _signupChoices = choices;
    }
    await store.clear();
    _signupChoices = null;
  }

  void _markGateAndContinue() {
    if (!mounted) return;
    ref.read(activationVerifiedNamespaceProvider.notifier).state = ref.read(
      cacheNamespaceProvider,
    );
    ref.invalidate(profileProvider);
    if (mounted) context.go(AppRoute.permissions);
  }

  @override
  Widget build(BuildContext context) => OnboardingBackScope(
    onBack: () => context.go(AppRoute.welcome),
    child: AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            onPressed: () => context.go(AppRoute.welcome),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          title: Text(
            'Account access',
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
                    : _buildContent(),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildContent() {
    final access = _access;
    final policy = _policy;
    if (_error != null && access == null) {
      return _messagePanel(
        title: 'We couldn’t check access',
        message: _error!,
        action: 'Try again',
        onPressed: _retry,
      );
    }
    if (access?.isPaused == true &&
        policy?.isPaused == true &&
        _pendingCode == null) {
      return _messagePanel(
        title: 'Invites are temporarily paused',
        message:
            'Your verified sign-in is saved. Try again later or use an invite code if you have one.',
        action: 'Check again',
        onPressed: _retry,
      );
    }
    if (policy == null || policy.admissionMode == 'unavailable') {
      return _messagePanel(
        title: 'Access is temporarily unavailable',
        message: _error ?? 'Please try again in a moment.',
        action: 'Try again',
        onPressed: _retry,
      );
    }

    final needsInvite =
        policy.isInviteOnly ||
        policy.isPaused ||
        (access?.requiresInvitation == true && !policy.isOpen);
    final showCodeEntry = needsInvite || _pendingCode != null;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const Icon(Icons.lock_open_rounded, size: 44, color: BambooInk.jade),
        const SizedBox(height: AppSpace.md),
        Text(
          'One quick step to get started',
          textAlign: TextAlign.center,
          style: BambooFonts.heading(24, color: BambooInk.ink900),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          showCodeEntry
              ? 'Enter or confirm your invite. We’ll show what it includes before you activate.'
              : 'Your sign-in is verified. Confirm account access to finish setup.',
          textAlign: TextAlign.center,
          style: BambooFonts.ui(14, color: BambooInk.ink700),
        ),
        const SizedBox(height: AppSpace.lg),
        if (showCodeEntry) ...[
          TextField(
            key: const Key('activation_invitation_code'),
            controller: _codeController,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Invite code',
              hintText: 'ABC123',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              suffixIcon: IconButton(
                tooltip: 'Check invite',
                onPressed: _working ? null : () => _previewCode(),
                icon: const Icon(Icons.check_circle_outline),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          OutlinedButton(
            onPressed: _working ? null : () => _previewCode(),
            child: Text(_working ? 'Checking…' : 'Check invite'),
          ),
          if (_codeConflict != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              'Saved code $_codeConflict is being kept. Choose which code to use.',
              textAlign: TextAlign.center,
              style: BambooFonts.ui(13, color: BambooInk.ink700),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpace.sm,
              children: [
                TextButton(
                  onPressed: _working ? null : _useSavedCode,
                  child: const Text('Use saved code'),
                ),
                TextButton(
                  onPressed: _working ? null : _replaceSavedCode,
                  child: const Text('Replace with this code'),
                ),
              ],
            ),
          ],
          if (_preview != null) ...[
            const SizedBox(height: AppSpace.md),
            _previewCard(_preview!),
            const SizedBox(height: AppSpace.md),
            if (_preview!.rewardAvailable) ...[
              Text(
                'Choose how to use this invite',
                style: BambooFonts.ui(14, weight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpace.xs),
              ChoiceChip(
                label: Text(
                  _preview!.requiredConsecutiveDays == null
                      ? 'Join referral rewards'
                      : 'Join rewards · ${_preview!.requiredConsecutiveDays}-day Bamboo streak',
                ),
                selected: _selectedRewardChoice == 'rewards',
                onSelected: _working
                    ? null
                    : (selected) => setState(() {
                        _selectedRewardChoice = selected ? 'rewards' : null;
                      }),
              ),
              const SizedBox(height: AppSpace.xs),
              ChoiceChip(
                label: const Text('Access only, no referral rewards'),
                selected: _selectedRewardChoice == 'access_only',
                onSelected: _working
                    ? null
                    : (selected) => setState(() {
                        _selectedRewardChoice = selected ? 'access_only' : null;
                      }),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Reward terms version: ${_preview!.termsVersion}',
                style: BambooFonts.ui(11.5, color: BambooInk.ink500),
              ),
            ] else ...[
              CheckboxListTile(
                key: const Key('activation_access_only_choice'),
                contentPadding: EdgeInsets.zero,
                value: _selectedRewardChoice == 'access_only',
                onChanged: _working
                    ? null
                    : (selected) => setState(
                        () => _selectedRewardChoice = selected == true
                            ? 'access_only'
                            : null,
                      ),
                title: const Text('Continue with access only'),
                subtitle: const Text(
                  'This invite has no referral reward available.',
                ),
              ),
            ],
          ],
        ] else if (policy.isOpen) ...[
          const _InfoCard(
            icon: Icons.verified_user_outlined,
            text:
                'PandaPay is open. No invite code is needed for this account.',
          ),
        ] else if (policy.isPaused) ...[
          const _InfoCard(
            icon: Icons.hourglass_empty_rounded,
            text:
                'New access is paused right now. If you have an invite, enter it above.',
          ),
        ],
        if (!_productTermsAccepted) ...[
          const SizedBox(height: AppSpace.md),
          CheckboxListTile(
            key: const Key('activation_product_terms'),
            contentPadding: EdgeInsets.zero,
            value: _productTermsAccepted,
            onChanged: _working
                ? null
                : (value) =>
                      setState(() => _productTermsAccepted = value ?? false),
            title: const Text('I agree to the Terms & Privacy Policy'),
            subtitle: Text('Required to activate · $appProductTermsVersion'),
          ),
        ] else ...[
          const SizedBox(height: AppSpace.md),
          Text(
            'Terms & Privacy Policy accepted during sign-up.',
            textAlign: TextAlign.center,
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            _error!,
            key: const Key('activation_error'),
            textAlign: TextAlign.center,
            style: BambooFonts.ui(13, color: Colors.red.shade700),
          ),
          TextButton(
            onPressed: _working ? null : _retry,
            child: const Text('Retry'),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        FilledButton(
          key: const Key('activate_account'),
          onPressed: _canActivate ? _activate : null,
          child: Text(_working ? 'Activating…' : 'Activate account'),
        ),
      ],
    );
  }

  Widget _previewCard(InvitationPreview preview) => Container(
    padding: const EdgeInsets.all(AppSpace.md),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .85),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Invite ${preview.code}',
          style: BambooFonts.ui(15, weight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          preview.rewardAvailable
              ? 'This invitation includes a chance to earn referral rewards after the stated activity milestone. Any reward is shown before you spin.'
              : 'This invitation currently provides account access only.',
          style: BambooFonts.ui(13, color: BambooInk.ink700),
        ),
        if (preview.qualificationWindowDays != null) ...[
          const SizedBox(height: AppSpace.xs),
          Text(
            'Complete the milestone within ${preview.qualificationWindowDays} days.',
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
        ],
      ],
    ),
  );

  Widget _messagePanel({
    required String title,
    required String message,
    required String action,
    required VoidCallback onPressed,
  }) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        title,
        textAlign: TextAlign.center,
        style: BambooFonts.heading(22, color: BambooInk.ink900),
      ),
      const SizedBox(height: AppSpace.sm),
      Text(
        message,
        textAlign: TextAlign.center,
        style: BambooFonts.ui(14, color: BambooInk.ink700),
      ),
      const SizedBox(height: AppSpace.lg),
      FilledButton(onPressed: onPressed, child: Text(action)),
    ],
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.md),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .85),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Icon(icon, color: BambooInk.jade),
        const SizedBox(width: AppSpace.sm),
        Expanded(child: Text(text, style: BambooFonts.ui(13))),
      ],
    ),
  );
}
