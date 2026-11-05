import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../app/design/app_theme.dart';
import '../ui/shared_components.dart';
import '../../../app/design/widgets.dart';
import '../data/pending_split_invite.dart';
import '../data/shared_directory.dart';
import '../data/shared_invitations.dart';
import '../data/shared_transport.dart';
import 'shared_providers.dart';
import 'shared_runtime.dart';

/// Landing page for `https://pandapay.app/split/join/<token>`. Opening the link
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
  final _operationId = const Uuid().v4();
  Future<SharedInvitePreview>? _preview;
  SharedExpensesRuntime? _runtime;
  String? _result, _error;
  bool _busy = false;

  Future<SharedInvitePreview> _load(SharedExpensesRuntime runtime) async {
    await runtime.refresh(maxPullPages: 1);
    return runtime.previewInvite(widget.token);
  }

  Future<void> _join() async {
    final runtime = _runtime;
    if (runtime == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await runtime.claimInvite(widget.token, _operationId);
      await PendingSplitInviteStore().clear();
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
          loading: () => const Center(
            child: CircularProgressIndicator(color: BambooInk.slate),
          ),
          error: (_, _) => _message(
            'Shared expenses are not available yet. Try again later.',
            action: ('Close', widget.onDone),
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
                  final offline =
                      error is SharedTransportException &&
                      (error.code == 'network_unavailable' ||
                          error.code == 'account_changed' ||
                          (error.statusCode != null &&
                              error.statusCode! >= 500));
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
                      Text(
                        'Join ${preview.contextName}?',
                        style: BambooFonts.heading(22),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        preview.isGroupLink
                            ? 'You are asking to join this group. Joining '
                                  'does not accept any expense or debt — you '
                                  'can review each one before it counts.'
                            : 'You were added as "${preview.memberName}". '
                                  'Joining does not accept any expense or '
                                  'debt — you can review each one before it '
                                  'counts.',
                        style: BambooFonts.ui(14, color: BambooInk.ink700),
                      ),
                      if (!preview.phoneBound) ...[
                        const SizedBox(height: 8),
                        Text(
                          'The person who invited you will be asked to approve your request.',
                          style: BambooFonts.ui(13, color: BambooInk.ink700),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: BambooFonts.ui(13, color: BambooInk.clayInk),
                        ),
                      ],
                      const Spacer(),
                      FilledButton(
                        style: sharedPrimaryButtonStyle(),
                        onPressed: _busy ? null : _join,
                        child: Text(
                          _busy ? 'Joining…' : 'Join',
                          style: BambooFonts.ui(14, weight: FontWeight.w600),
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : widget.onDone,
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
