import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../../app/design/app_theme.dart';
import '../ui/shared_components.dart';
import '../../../app/design/widgets.dart';
import '../data/pending_split_invite.dart';
import '../data/shared_directory.dart';
import '../data/shared_invitations.dart';
import '../data/shared_transport.dart';
import '../ui/shared_phone_consent.dart';
import 'shared_providers.dart';
import 'shared_runtime.dart';

/// Landing page for `https://pandapay.pandapath.live/split/join/<token>`. Opening the link
/// only previews the group; nothing is joined until the person taps Join, and
/// joining never accepts an expense or debt (those stay in explicit review).
class SharedJoinRoute extends ConsumerStatefulWidget {
  final String token;
  final VoidCallback onDone;
  const SharedJoinRoute({super.key, required this.token, required this.onDone});
  @override
  ConsumerState<SharedJoinRoute> createState() => _SharedJoinRouteState();
}

class _SharedJoinRouteState extends ConsumerState<SharedJoinRoute> {
  // One operation ID per screen so a retry after a dropped response replays
  // the same claim instead of creating a second one.
  String _operationId = const Uuid().v4();
  bool _attempted = false;
  Future<SharedInvitePreview>? _preview;
  SharedExpensesRuntime? _runtime;
  String? _result, _error;
  bool _busy = false;

  /// The claimant's choice; null until they pick (neither is preselected).
  bool? _sharePhone;
  bool _wantsChoice = false;

  static const _choiceKey = 'pandapay_app.split_phone_share_choice_v1';

  @override
  void initState() {
    super.initState();
    // The last answer is offered again, still changeable on this screen: one
    // less thing to decide on every link. Never applied over a choice just made.
    unawaited(() async {
      try {
        final saved = (await SharedPreferences.getInstance()).getBool(
          _choiceKey,
        );
        if (saved != null && mounted && _sharePhone == null) {
          setState(() => _sharePhone = saved);
        }
      } catch (_) {}
    }());
  }

  Future<SharedInvitePreview> _load(SharedExpensesRuntime runtime) async {
    await runtime.refresh(maxPullPages: 1);
    // A link that opens the app from cold can reach the server before the
    // signed-in session has finished refreshing, which reads as "unavailable".
    // Retry once after a short wait before telling the person the link is dead.
    try {
      return await runtime.previewInvite(widget.token);
    } on SharedTransportException catch (error) {
      final transient =
          error.code == 'invitation_unavailable' ||
          error.statusCode == 401 ||
          error.statusCode == 403;
      if (!transient) rethrow;
      await Future<void>.delayed(const Duration(seconds: 3));
      await runtime.refresh(maxPullPages: 1);
      return runtime.previewInvite(widget.token);
    }
  }

  Future<void> _join() async {
    final runtime = _runtime;
    if (runtime == null || _busy) return;
    if (_wantsChoice && _sharePhone == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _attempted = true;
      String status;
      try {
        status = await runtime.claimInvite(
          widget.token,
          _operationId,
          sharePhone: _wantsChoice ? _sharePhone : null,
        );
      } on SharedTransportException catch (error) {
        // The same operation id was used with a different answer: start over
        // with a fresh one rather than failing.
        if (error.code != 'operation_conflict') rethrow;
        _operationId = const Uuid().v4();
        status = await runtime.claimInvite(
          widget.token,
          _operationId,
          sharePhone: _wantsChoice ? _sharePhone : null,
        );
      }
      // The claim is done; a storage hiccup clearing the reminder is not a
      // failed join (a retry would only replay the same claim).
      try {
        await PendingSplitInviteStore().clear();
        final choice = _sharePhone;
        if (_wantsChoice && choice != null) {
          await (await SharedPreferences.getInstance()).setBool(
            _choiceKey,
            choice,
          );
        }
      } catch (_) {}
      if (mounted) setState(() => _result = status);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = switch (error) {
            SharedTransportException(code: 'invitation_phone_mismatch') =>
              'This invite was made for a different mobile number. Ask the sender to invite your verified number.',
            SharedTransportException(code: 'invitation_unavailable') =>
              'This invite has expired or was replaced. Ask the sender for a new link.',
            SharedTransportException(code: 'phone_not_verified') =>
              sharedInviteIssueMessage(error),
            SharedTransportException(statusCode: 429) =>
              'Too many tries for now. Please wait a while and try again.',
            SharedTransportException(code: 'network_unavailable') =>
              'No connection. Nothing was sent; try again when online.',
            SharedTransportException(:final code?)
                when code.startsWith('join_') ||
                    code == 'membership_conflict' ||
                    code == 'context_member_limit' ||
                    code == 'invitation_rate_limited' =>
              sharedInviteIssueMessage(error),
            _ =>
              'Could not join right now. Check your connection and try again.',
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(sharedExpensesRuntimeProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(title: Text('Join', style: BambooFonts.heading(17))),
      body: AppBackground(
        child: runtime.when(
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => const Center(
            child: CircularProgressIndicator(color: BambooInk.slate),
          ),
          error: (_, _) => _message(
            'Shared expenses are not ready yet. Give it a moment and try again.',
            action: (
              'Try again',
              () => ref.invalidate(sharedExpensesRuntimeProvider),
            ),
          ),
          data: (value) {
            if (!identical(_runtime, value)) {
              _runtime = value;
              _preview = _load(value);
            }
            return FutureBuilder<SharedInvitePreview>(
              future: _preview,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  final error = snapshot.error;
                  // Only a definite answer from the server ("no such invite")
                  // kills the link. Anything else (no connection, the shared
                  // module not loaded yet on a fresh install, a server error)
                  // is transient: keep the saved invite and let them retry.
                  final offline =
                      error is! SharedTransportException ||
                      error.code == 'network_unavailable' ||
                      error.code == 'account_changed' ||
                      (error.statusCode != null && error.statusCode! >= 500);
                  if (offline) {
                    // Keep the saved invite: nothing is wrong with the link.
                    return _message(
                      'Could not load this invite. Check your connection and try again.',
                      action: (
                        'Try again',
                        () => setState(() => _preview = _load(value)),
                      ),
                    );
                  }
                  // A dead invite must not linger and reopen on every launch.
                  PendingSplitInviteStore().clear();
                  return _message(
                    'This invite is not available. It may have expired, been replaced, or it is your own link. Ask the sender for a new one.',
                    action: ('Close', widget.onDone),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: BambooInk.slate),
                  );
                }
                final preview = snapshot.data!;
                // An open link needs no owner decision, so there is nothing to
                // share a number for: no choice, no extra step.
                _wantsChoice =
                    preview.phoneSharing &&
                    !preview.phoneBound &&
                    !preview.autoJoin &&
                    preview.ownPhoneMask != null;
                if (_result != null) {
                  return _message(
                    _result == 'joined'
                        ? 'You joined ${preview.contextName}.'
                        : 'Request sent. The person who invited you needs to approve you before you can see shared expenses.',
                    action: ('Done', widget.onDone),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Join ${preview.contextName}?',
                                style: BambooFonts.heading(22),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                preview.autoJoin
                                    ? 'You will join right away. Joining never '
                                          'adds any expense or debt to you.'
                                    : 'The split owner will confirm your request. '
                                          'You approve your own share of each expense.',
                                style: BambooFonts.ui(
                                  14,
                                  color: BambooInk.ink700,
                                ),
                              ),
                              if (preview.ownerName != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Owner: ${preview.ownerName}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: BambooFonts.ui(
                                    13,
                                    color: BambooInk.ink700,
                                  ),
                                ),
                              ],
                              if (preview.phoneSharing &&
                                  !preview.phoneBound &&
                                  !preview.autoJoin)
                                SharedPhoneConsent(
                                  ownerName: preview.ownerName,
                                  ownMask: preview.ownPhoneMask,
                                  value: _sharePhone,
                                  enabled: !_busy,
                                  onChanged: (v) => setState(() {
                                    // A changed answer must not replay the
                                    // old claim.
                                    if (_attempted && v != _sharePhone) {
                                      _operationId = const Uuid().v4();
                                    }
                                    _sharePhone = v;
                                  }),
                                ),
                              if (_error != null) ...[
                                const SizedBox(height: 12),
                                Text(
                                  _error!,
                                  style: BambooFonts.ui(
                                    13,
                                    color: BambooInk.clayInk,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (_wantsChoice && _sharePhone == null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Choose one option above to continue.',
                            textAlign: TextAlign.center,
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink700,
                            ),
                          ),
                        ),
                      FilledButton(
                        style: sharedPrimaryButtonStyle(),
                        onPressed:
                            _busy || (_wantsChoice && _sharePhone == null)
                            ? null
                            : _join,
                        child: Text(
                          _busy ? 'Joining…' : 'Join',
                          style: BambooFonts.ui(
                            14,
                            weight: FontWeight.w600,
                            color: BambooInk.lime,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                // Declined for now: do not bring it back at
                                // every launch for a week.
                                try {
                                  await PendingSplitInviteStore().clear();
                                } catch (_) {}
                                widget.onDone();
                              },
                        child: const Text('Not now'),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _message(String text, {(String, VoidCallback)? action}) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(text, style: BambooFonts.ui(15), textAlign: TextAlign.center),
        if (action != null) ...[
          const SizedBox(height: 16),
          FilledButton(
            style: sharedPrimaryButtonStyle(),
            onPressed: action.$2,
            child: Text(action.$1),
          ),
        ],
      ],
    ),
  );
}
