import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';
import '../data/shared_directory.dart';
import '../runtime/shared_runtime.dart';

/// Invitations waiting for this account's verified phone number. Loaded when
/// the screen opens and when the app returns to the foreground, so there is no
/// push dependency. Joining accepts no expense and posts no money.
class SharedInviteInbox extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final VoidCallback? onJoined;
  const SharedInviteInbox({super.key, required this.runtime, this.onJoined});
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
      await widget.runtime.respondToInboxInvite(invite, accept: accept);
      if (!mounted) return;
      setState(() {
        _items = [
          for (final i in _items)
            if (i.invitationId != invite.invitationId) i,
        ];
        _message = accept ? 'Joined. It is now in your splits.' : 'Declined.';
      });
      if (accept) widget.onJoined?.call();
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

  Future<void> _decide(SharedJoinRequest request, bool approve) async {
    if (!_busy.add(request.invitationId)) return;
    setState(() => _message = null);
    try {
      await widget.runtime.respondToJoinRequest(
        request.invitationId,
        approve: approve,
      );
      if (!mounted) return;
      setState(() {
        _requests = [
          for (final r in _requests)
            if (r.invitationId != request.invitationId) r,
        ];
        _message = approve ? 'They have joined.' : 'Request declined.';
      });
      if (approve) widget.onJoined?.call();
    } catch (error) {
      if (mounted) {
        setState(() => _message = sharedInviteIssueMessage(error));
        await _load();
      }
    } finally {
      _busy.remove(request.invitationId);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty && _requests.isEmpty && _message == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final request in _requests)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: BambooInk.ink300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    request.headline,
                    style: BambooFonts.ui(14, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'They opened the link you shared. Approving only adds them; they cannot approve expenses for anyone else.',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _busy.contains(request.invitationId)
                            ? null
                            : () => _decide(request, false),
                        child: Text('Decline', style: BambooFonts.ui(13)),
                      ),
                      TextButton(
                        onPressed: _busy.contains(request.invitationId)
                            ? null
                            : () => _decide(request, true),
                        child: Text(
                          'Approve',
                          style: BambooFonts.ui(13, weight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          for (final invite in _items)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: BambooInk.ink300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    invite.headline,
                    style: BambooFonts.ui(14, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Joining only lets you see and add shared expenses. You approve every expense yourself.',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _busy.contains(invite.invitationId)
                            ? null
                            : () => _respond(invite, false),
                        child: Text('Decline', style: BambooFonts.ui(13)),
                      ),
                      TextButton(
                        onPressed: _busy.contains(invite.invitationId)
                            ? null
                            : () => _respond(invite, true),
                        child: Text(
                          _busy.contains(invite.invitationId)
                              ? 'Please wait…'
                              : 'Join',
                          style: BambooFonts.ui(13, weight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_message != null)
            Text(
              _message!,
              style: BambooFonts.ui(12.5, color: BambooInk.ink700),
            ),
        ],
      ),
    );
  }
}
