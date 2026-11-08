import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';
import '../data/shared_directory.dart';
import '../runtime/shared_runtime.dart';
import 'shared_join_requests_summary.dart';

/// Invitations waiting for this account's verified phone number, plus one
/// summary row when people have asked to join. Loaded when the screen opens
/// and when the app returns to the foreground, so there is no push dependency.
/// Joining accepts no expense and posts no money. The requests themselves are
/// reviewed on their own page ([onReviewRequests]).
class SharedInviteInbox extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final VoidCallback? onJoined;

  /// Opens the join-requests page; the inbox reloads when it comes back.
  final Future<void> Function()? onReviewRequests;
  const SharedInviteInbox({
    super.key,
    required this.runtime,
    this.onJoined,
    this.onReviewRequests,
  });
  @override
  State<SharedInviteInbox> createState() => _InboxState();
}

class _InboxState extends State<SharedInviteInbox> with WidgetsBindingObserver {
  List<SharedInboxInvite> _items = const [];
  List<SharedJoinRequest> _requests = const [];
  final _busy = <String>{};
  String? _message;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.addListener(_runtimeChanged);
    _load();
  }

  /// Capabilities arrive after the runtime is created; the first load can run
  /// before proposals are known to be on. Load again once they are.
  void _runtimeChanged() {
    if (!_loaded && widget.runtime.proposalsEnabled) _load();
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_runtimeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (!widget.runtime.proposalsEnabled) return;
    _loaded = true;
    try {
      final items = await widget.runtime.inviteInbox();
      var requests = const <SharedJoinRequest>[];
      try {
        requests = await widget.runtime.joinRequests();
      } catch (_) {
        // Requests are an extra; invites still show.
      }
      if (mounted) {
        setState(() {
          _items = items;
          _requests = requests;
        });
      }
    } catch (_) {
      _loaded = false;
      // Quiet: the inbox is an extra. Reopening or resuming the app retries.
    }
  }

  Future<void> _respond(SharedInboxInvite invite, bool accept) async {
    if (!_busy.add(invite.invitationId)) return;
    setState(() => _message = null);
    try {
      final status = await widget.runtime.respondToInboxInvite(
        invite,
        accept: accept,
      );
      if (!mounted) return;
      setState(() {
        _items = [
          for (final i in _items)
            if (i.invitationId != invite.invitationId) i,
        ];
        _message = switch (status) {
          'joined' => 'Joined. It is now in your splits.',
          'awaiting_owner' => 'Request sent. The split owner will confirm.',
          _ => 'Declined.',
        };
      });
      if (status == 'joined') widget.onJoined?.call();
    } catch (error) {
      if (mounted) {
        setState(() => _message = sharedInviteIssueMessage(error));
        await _load();
      }
    } finally {
      _busy.remove(invite.invitationId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _review() async {
    await widget.onReviewRequests?.call();
    if (mounted) await _load();
    if (mounted) widget.onJoined?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty && _requests.isEmpty && _message == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    // The inbox sits above the tabs, so it scrolls inside a capped height
    // rather than pushing the lists off screen.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .4,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SharedJoinRequestsSummary(requests: _requests, onReview: _review),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final invite in _items)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            invite.headline,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(14, weight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'The split owner will confirm your request. You approve your own share of each expense.',
                            style: BambooFonts.ui(
                              12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          Wrap(
                            alignment: WrapAlignment.end,
                            children: [
                              TextButton(
                                onPressed: _busy.contains(invite.invitationId)
                                    ? null
                                    : () => _respond(invite, false),
                                child: Text(
                                  'Decline',
                                  style: BambooFonts.ui(13),
                                ),
                              ),
                              TextButton(
                                onPressed: _busy.contains(invite.invitationId)
                                    ? null
                                    : () => _respond(invite, true),
                                child: Text(
                                  _busy.contains(invite.invitationId)
                                      ? 'Please wait…'
                                      : 'Request to join',
                                  style: BambooFonts.ui(
                                    13,
                                    weight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _message!,
                        style: BambooFonts.ui(
                          12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
