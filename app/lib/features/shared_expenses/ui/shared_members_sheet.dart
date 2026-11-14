import 'dart:async';
import '../storage/shared_store.dart'
    show SharedCommandState, SharedNameException;
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/required_field.dart';
import '../data/shared_commands.dart';
import '../composer/shared_editor.dart';
import '../data/shared_invitations.dart';
import '../runtime/shared_runtime.dart';
import '../data/shared_directory.dart';
import '../data/shared_transport.dart';
import 'shared_add_friend_sheet.dart';
import 'shared_components.dart';
import 'shared_context_guard.dart';
import 'shared_rename_member_dialog.dart';
import '../../../app/design/bamboo_components.dart';
import 'shared_settle_sheet.dart';
import '../../account/member_avatar.dart';

/// Existing context's membership. A name records a shadow member; it neither
/// sends an invitation nor verifies identity or accepts debt.
class SharedMembersSheet extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final String contextId, groupName;
  const SharedMembersSheet({
    super.key,
    required this.runtime,
    required this.contextId,
    required this.groupName,
  });

  /// Completes with true when the person left the split from this sheet.
  static Future<bool?> show(
    BuildContext context, {
    required SharedExpensesRuntime runtime,
    required String contextId,
    required String groupName,
  }) => showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BambooInk.paper,
    builder: (_) => SharedMembersSheet(
      runtime: runtime,
      contextId: contextId,
      groupName: groupName,
    ),
  );
  @override
  State<SharedMembersSheet> createState() => _SharedMembersSheetState();
}

class _SharedMembersSheetState extends State<SharedMembersSheet> {
  late Future<SharedRoster> _roster;
  bool _busy = false;
  String? _notice;
  SharedCommand? _pending;
  final _links = <String, SharedInviteLink>{};
  final _phones = <String, String>{};
  String? _pendingPhone, _pendingMemberId, _formError;
  // Add-person is an inline step of this sheet, not a dialog on top of it.
  bool _adding = false;
  Map<String, SharedOwnerInvitation> _inv = const {};
  SharedGroupLinkStatus? _groupLink;
  SharedInviteLink? _groupLinkNow;
  final _nameField = TextEditingController();
  final _phoneField = TextEditingController();
  bool get _authorized =>
      widget.runtime.isCurrent() &&
      !widget.runtime.store.isContextRevoked(widget.contextId);
  @override
  void initState() {
    super.initState();
    _roster = widget.runtime.contextRoster(widget.contextId);
    _loadInvitations();
    _loadGroupLink();
    _loadPendingPhones();
    _nameField.addListener(_onFieldChanged);
    _phoneField.addListener(_onFieldChanged);
  }

  // Controllers also notify on cursor and focus moves; only a real edit of
  // the text should dismiss a validation message.
  String _seenName = '', _seenPhone = '';
  void _onFieldChanged() {
    final changed =
        _nameField.text != _seenName || _phoneField.text != _seenPhone;
    _seenName = _nameField.text;
    _seenPhone = _phoneField.text;
    if (changed && _formError != null) {
      setState(() => _formError = null);
    }
  }

  Future<void> _loadPendingPhones() async {
    try {
      final roster = await _roster;
      for (final m in roster.members) {
        if (_phones.containsKey(m.id)) continue;
        final phone = await widget.runtime.pendingPhones.phoneFor(m.id);
        if (phone != null && mounted) {
          _phones[m.id] = phone;
        }
      }
    } catch (_) {}
  }

  /// A person without a saved name (no verified phone) still reads clearly.
  String _displayName(SharedEditorMember m) {
    if (m.name != 'Member') return m.name;
    return switch ((m.role, m.state)) {
      ('owner', _) => 'Group owner',
      (_, 'left') => 'Someone who left',
      _ => m.name,
    };
  }

  /// True while a dialog or picker opened from this sheet is on screen. A
  /// second tap must not stack a second one (two rename dialogs, two confirms).
  bool _modal = false, _picking = false;

  Future<bool> _confirm(String title, String body, String action) async {
    if (_modal) return false;
    _modal = true;
    try {
      return await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(title),
              content: Text(body),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(action),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      _modal = false;
    }
  }

  Future<void> _remove(SharedEditorMember member) async {
    if (_busy || !_authorized) return;
    final ok = await _confirm(
      'Remove ${member.name}?',
      'They have not joined and have no expenses here. You can add them again later.',
      'Remove',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.runtime.removeMember(widget.contextId, member.id);
      if (!mounted) return;
      setState(() {
        _notice = '${member.name} was removed.';
        _roster = widget.runtime.contextRoster(widget.contextId);
      });
      await _loadInvitations();
    } catch (error) {
      if (mounted) setState(() => _notice = sharedInviteIssueMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _stateLine(SharedEditorMember member) => switch (member.state) {
    'active' =>
      member.profileId == null
          ? 'Account no longer active · history kept'
          : member.role == 'owner'
          ? 'Owner'
          : 'Active member',
    'invited' =>
      member.profileId == null ? _statusLine(member) : 'Invitation pending',
    'removed' => 'Removed · history retained',
    'left' => 'Left · history retained',
    _ => 'Membership needs review',
  };

  /// Number endings for people who would otherwise look identical.
  Map<String, String> _sameNameHints(SharedRoster roster) =>
      sharedSameNameHints([
        for (final m in roster.members)
          (
            id: m.id,
            label: m.id == roster.ownMemberId ? 'You' : _displayName(m),
            suffix: m.phoneSuffix ?? _inv[m.id]?.phoneSuffix,
          ),
      ]);

  Widget _subtitle(
    SharedRoster roster,
    SharedEditorMember member,
    Map<String, String> hints,
  ) {
    final style = BambooFonts.ui(12, color: BambooInk.ink700);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _stateLine(member),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
        if (hints[member.id] != null)
          Text(
            hints[member.id]!,
            key: ValueKey('member-hint-${member.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        // The name this person gave themselves, when it differs from the name
        // saved for them (the saved name stays the main one).
        if (member.profileId != null && member.id != roster.ownMemberId)
          MemberProfileNameLine(
            profileId: member.profileId,
            savedName: _displayName(member),
            style: style,
          ),
        if (_canRename(roster, member))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('edit-name-${member.id}'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(48, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.centerLeft,
              ),
              onPressed: _busy ? null : () => _rename(roster, member),
              child: Text('Edit name', style: BambooFonts.ui(12.5)),
            ),
          ),
      ],
    );
  }

  /// The server lets the owner rename anyone who is still around and everyone
  /// rename themselves; it refuses people who left or were removed.
  bool _canRename(SharedRoster roster, SharedEditorMember member) {
    if (!widget.runtime.canQueueProposals) return false;
    final self = member.id == roster.ownMemberId;
    final owner = roster.members.any(
      (m) => m.id == roster.ownMemberId && m.role == 'owner',
    );
    final live =
        (member.state == 'active' && member.profileId != null) ||
        (member.state == 'invited' && owner);
    return live && (owner || self);
  }

  Future<void> _rename(SharedRoster roster, SharedEditorMember member) async {
    if (_busy || _modal || !_authorized) return;
    final self = member.id == roster.ownMemberId;
    String? opId;
    _modal = true;
    final String? name;
    try {
      name = await _showRename(roster, member, self, (id) => opId = id);
    } finally {
      _modal = false;
    }
    if (name == null || opId == null || !mounted || !_authorized) return;
    setState(() {
      _notice = widget.runtime.operationStatus(opId!);
      _roster = widget.runtime.contextRoster(widget.contextId);
    });
  }

  Future<String?> _showRename(
    SharedRoster roster,
    SharedEditorMember member,
    bool self,
    void Function(String) saved,
  ) {
    return showSharedRenameMemberDialog(
      context,
      title: self ? 'Edit your name' : 'Edit name',
      initialName: member.rawName ?? (self ? '' : _displayName(member)),
      onSave: (typed) async {
        try {
          saved(
            await widget.runtime.renameMember(
              contextId: widget.contextId,
              memberId: member.id,
              name: typed,
              directCounterpart: roster.direct && !self,
            ),
          );
          return null;
        } on SharedNameException catch (error) {
          return sharedInviteIssueMessage(
            SharedTransportException(code: error.code),
          );
        } on FormatException {
          return 'Enter a name up to $sharedMemberNameMax characters.';
        } catch (error) {
          return error is SharedTransportException
              ? sharedInviteIssueMessage(error)
              : 'Could not save the name yet. Try again.';
        }
      },
    );
  }

  /// Rare on purpose: a split stays after everyone settles and can be used for
  /// the next expense. Leaving only works when nothing is owed or waiting.
  Future<void> _leave() async {
    if (_busy || !_authorized) return;
    final ok = await _confirm(
      'Leave ${widget.groupName}?',
      'You will stop seeing this split. Past expenses stay for the others. '
          'You can only leave when nothing is owed and nothing is waiting. '
          'Someone can add you again later.',
      'Leave',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.runtime.leaveContext(widget.contextId);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        final isSettleFirst =
            (error is SharedTransportException && error.code == 'settle_first') ||
            error.toString().contains('settle_first');
        if (isSettleFirst) {
          setState(() => _busy = false);
          _showCannotLeaveSheet();
        } else {
          setState(() {
            _notice = sharedInviteIssueMessage(error);
            _busy = false;
          });
        }
      }
    }
  }

  void _showCannotLeaveSheet() {
    var handled = false; // a double tap must not pop twice or open two forms
    showBambooSheet(
      context: context,
      builder: (ctx) => BambooSheet(
        title: 'Settle up before leaving',
        subtitle:
            'You have unsettled balances in "${widget.groupName}". Clear your balances first, then you can leave cleanly.',
        actions: [
          FilledButton.icon(
            icon: const Icon(Icons.payments_outlined, size: 18),
            label: const Text('Settle up'),
            onPressed: () {
              if (handled) return;
              handled = true;
              Navigator.pop(ctx);
              SharedSettleSheet.show(
                context,
                runtime: widget.runtime,
                contextId: widget.contextId,
              );
            },
          ),
          OutlinedButton(
            onPressed: () {
              if (handled) return;
              handled = true;
              Navigator.pop(ctx);
            },
            child: const Text('Stay in split'),
          ),
        ],
        children: const [],
      ),
    );
  }

  Future<void> _makeOwner(SharedEditorMember member) async {
    if (_busy || !_authorized) return;
    final ok = await _confirm(
      'Make ${member.name} the owner?',
      'They will approve people and manage this split. You stay a member and can leave later.',
      'Make owner',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.runtime.transferOwner(widget.contextId, member.id);
      if (!mounted) return;
      setState(() {
        _notice = '${member.name} is now the owner.';
        _roster = widget.runtime.contextRoster(widget.contextId);
      });
    } catch (error) {
      if (mounted) setState(() => _notice = sharedInviteIssueMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takeOver() async {
    if (_busy || !_authorized) return;
    final ok = await _confirm(
      'Take over this split?',
      'The owner account no longer exists. You will become the owner.',
      'Take over',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.runtime.takeOverOwnership(widget.contextId);
      if (!mounted) return;
      setState(() {
        _notice = 'You are now the owner.';
        _roster = widget.runtime.contextRoster(widget.contextId);
      });
    } catch (error) {
      if (mounted) setState(() => _notice = sharedInviteIssueMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadGroupLink() async {
    try {
      final status = await widget.runtime.groupLinkStatus(widget.contextId);
      if (mounted) setState(() => _groupLink = status);
    } catch (_) {
      if (mounted) setState(() => _groupLink = null);
    }
  }

  /// One link per group. Creating a new one replaces the old, so a link is only
  /// re-shared in the session that made it.
  Future<void> _shareGroupLink({bool reuse = false}) async {
    if (_busy || _modal || !_authorized || !widget.runtime.proposalsEnabled) {
      return;
    }
    final resharing = reuse && _groupLinkNow != null;
    // Making a link asks who may join with it; sharing the one just made
    // does not ask again.
    var auto = _groupLink?.autoJoin ?? true;
    if (!resharing) {
      final choice = await _askJoinMode();
      if (choice == null || !mounted) return;
      auto = choice;
    }
    setState(() => _busy = true);
    try {
      final link = resharing
          ? _groupLinkNow!
          : await widget.runtime.createGroupLink(
              widget.contextId,
              autoJoin: auto,
            );
      if (!mounted || !_authorized) return;
      setState(() => _groupLinkNow = link);
      await _loadGroupLink();
      await SharePlus.instance.share(
        ShareParams(
          subject: 'Join ${widget.groupName} on PandaPay',
          text: auto
              ? 'Join "${widget.groupName}" on PandaPay to keep shared '
                    'expenses in one place. Open the link to join: ${link.url}'
              : 'Join "${widget.groupName}" on PandaPay to keep shared '
                    'expenses in one place. Open the link and ask to join; '
                    'the group owner approves each person: ${link.url}',
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _notice = sharedInviteIssueMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Who can join with this link?" True: anyone with the link joins at once
  /// (the default, and what most groups want). False: the owner approves each
  /// person. Null: cancelled.
  Future<bool?> _askJoinMode() async {
    if (_modal) return null;
    _modal = true;
    try {
      return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Who can join with this link?'),
          content: const Text(
            'Anyone with the link joins right away. If you would rather '
            'approve each person, choose that instead. Joining never adds any '
            'expense or debt.',
          ),
          actions: [
            TextButton(
              key: const Key('link-mode-approve'),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('I approve each person'),
            ),
            FilledButton(
              key: const Key('link-mode-open'),
              style: sharedPrimaryButtonStyle(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'Anyone with the link joins',
                style: BambooFonts.ui(14, color: BambooInk.lime),
              ),
            ),
          ],
        ),
      );
    } finally {
      _modal = false;
    }
  }

  Future<void> _turnOffGroupLink() async {
    if (_busy || !_authorized) return;
    setState(() => _busy = true);
    try {
      await widget.runtime.revokeGroupLink(widget.contextId);
      if (!mounted) return;
      setState(() {
        _groupLinkNow = null;
        _notice =
            'The group link is off. People who already asked stay in the list.';
      });
      await _loadGroupLink();
    } catch (error) {
      if (mounted) setState(() => _notice = sharedInviteIssueMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _groupLinkCard() {
    final link = _groupLink;
    final active = link?.active == true;
    final until = link?.expiresAt;
    final dateText = until == null
        ? ''
        : ' until ${until.toLocal().day}/${until.toLocal().month}/${until.toLocal().year}';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
            'Group link',
            style: BambooFonts.ui(14, weight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            active
                ? (link!.autoJoin
                      ? 'Anyone with the link joins right away$dateText. Turn it off any time.'
                      : 'Anyone with the link can ask to join$dateText. You approve each person.')
                : link?.expired == true
                ? 'The last link expired. Create a new one to invite people.'
                : 'Share one link with the whole group. You choose whether people join right away or need your approval.',
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              if (active)
                TextButton(
                  onPressed: _busy ? null : _turnOffGroupLink,
                  child: Text('Turn off', style: BambooFonts.ui(13)),
                ),
              TextButton.icon(
                onPressed: _busy ? null : () => _shareGroupLink(reuse: active),
                icon: const Icon(Icons.share_outlined, size: 18),
                label: Text(
                  !active
                      ? 'Create link'
                      : _groupLinkNow != null
                      ? 'Share link'
                      : 'New link',
                  style: BambooFonts.ui(13, weight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (active && _groupLinkNow == null)
            Text(
              'A new link replaces the old one, so earlier copies stop working.',
              style: BambooFonts.ui(11.5, color: BambooInk.ink700),
            ),
        ],
      ),
    );
  }

  Future<void> _loadInvitations() async {
    try {
      final inv = await widget.runtime.ownerInvitations(widget.contextId);
      if (mounted) setState(() => _inv = inv);
    } catch (_) {
      // Roster still works without invitation details.
    }
  }

  /// Owner decision on someone who joined through a shared link.
  Future<void> _decide(SharedOwnerInvitation invite, bool approve) async {
    if (_busy || !_authorized) return;
    setState(() => _busy = true);
    try {
      await widget.runtime.respondToJoinRequest(
        invite.invitationId,
        approve: approve,
      );
      if (!mounted) return;
      setState(() {
        _notice = approve ? 'They have joined.' : 'Request declined.';
        _roster = widget.runtime.contextRoster(widget.contextId);
      });
      await _loadInvitations();
    } catch (error) {
      if (mounted) setState(() => _notice = sharedInviteIssueMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusLine(SharedEditorMember member) {
    final inv = _inv[member.id];
    return switch (inv?.status) {
      'open' when inv!.phoneBound => 'Invite sent · waiting for them to join',
      'open' => 'Link shared · waiting for them to join',
      'awaiting_owner' =>
        'Wants to join · ${sharedSignedInAs(label: member.name, profileName: inv!.claimantName, phoneSuffix: inv.phoneSuffix) ?? 'PandaPay user'}',
      'declined' => 'Declined the invite',
      'expired' => 'Invite expired',
      'rejected' => 'Not invited right now',
      _ => 'Not on PandaPay · unclaimed',
    };
  }

  @override
  void dispose() {
    _nameField.removeListener(_onFieldChanged);
    _phoneField.removeListener(_onFieldChanged);
    _nameField.dispose();
    _phoneField.dispose();
    super.dispose();
  }

  static bool _phonesMatch(String? a, String? b) {
    if (a == null || b == null) return false;
    final da = a.replaceAll(RegExp(r'[^0-9]'), '');
    final db = b.replaceAll(RegExp(r'[^0-9]'), '');
    if (da == db && da.isNotEmpty) return true;
    if (da.length >= 10 && db.length >= 10) {
      return da.substring(da.length - 10) == db.substring(db.length - 10);
    }
    return false;
  }

  static String _normalizeName(String s) =>
      s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  Future<void> _add() async {
    if (_busy || !_authorized) return;
    setState(() => _busy = true);
    try {
      if (_pending == null) {
        final text = _nameField.text.trim(), phone = _phoneField.text.trim();
        if (text.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
          setState(() => _formError = 'Enter the person\'s name.');
          return;
        }
        if (text.length > 40) {
          setState(
            () => _formError = 'Name cannot be more than 40 characters.',
          );
          return;
        }
        final lower = text.toLowerCase();
        if (lower == "you" || lower == "me" || lower == "myself") {
          setState(
            () => _formError =
                "That name cannot be used. Please choose a different one.",
          );
          return;
        }
        final cleaned = phone.isEmpty ? null : sharedCleanPhone(phone);
        if (phone.isNotEmpty && cleaned == null) {
          setState(
            () =>
                _formError = 'Enter a valid mobile number, or leave it empty.',
          );
          return;
        }
        // Never trust the answer for a number that has since been edited.
        var lookup = SharedPhoneLookup.none;
        if (phone.isNotEmpty && cleaned != null) {
          try {
            lookup = await widget.runtime.lookupPhone(cleaned);
          } catch (_) {}
          if (!mounted) return;
          if (lookup.self) {
            setState(() => _formError = 'That is your own number.');
            return;
          }
        }
        final name = text;
        _pendingPhone = cleaned;
        final current = await widget.runtime.contextRoster(widget.contextId);
        if (!mounted) return;
        if (!current.canInvite) throw const SharedRuntimeUnavailable();
        final norm = _normalizeName(name);
        final duplicateName = current.members.any(
          (m) =>
              m.state != 'left' &&
              (_normalizeName(m.name) == norm ||
                  (m.rawName != null && _normalizeName(m.rawName!) == norm)),
        );
        if (duplicateName) {
          setState(
            () => _formError =
                'Someone in this split already has that name. Add a surname or initial.',
          );
          return;
        }
        if (cleaned != null &&
            _phones.values.any((p) => _phonesMatch(p, cleaned))) {
          setState(
            () => _formError =
                'Someone in this split is already invited with that number.',
          );
          return;
        }
        _pendingMemberId = const Uuid().v4();
        _pending = SharedCommand(
          operationId: const Uuid().v4(),
          kind: 'member.invite',
          payload: {
            'contextId': widget.contextId,
            'memberId': _pendingMemberId,
            'displayName': name,
          },
        );
      }
      if (!_authorized || !widget.runtime.canQueueProposals) return;
      await widget.runtime.store.enqueue(_pending!);
      await widget.runtime.flushEditor();
      final refused = widget.runtime.nameFailure(_pending!.operationId);
      if (refused != null) {
        // Roll back: nothing was added, so let them change the name. The
        // refusal is explained here, so it is not also left as "not synced".
        await widget.runtime.acknowledgeRefusal(_pending!.operationId);
        if (mounted) {
          final message = sharedInviteIssueMessage(
            SharedTransportException(code: refused.code),
          );
          // The number saved for this person belongs to nobody now.
          final gone = _pendingMemberId;
          if (gone != null) {
            _phones.remove(gone);
            unawaited(widget.runtime.pendingPhones.forget(gone));
          }
          setState(() {
            _formError = message;
            // Found through "Check status" the form is closed: say it where
            // the person is looking, and bring the form back to fix the name.
            _notice = message;
            _adding = true;
            _pending = null;
            _pendingMemberId = null;
            _pendingPhone = null;
          });
        }
        return;
      }
      if (mounted && _authorized) {
        if (_pendingPhone != null && _pendingMemberId != null) {
          _phones[_pendingMemberId!] = _pendingPhone!;
          unawaited(
            widget.runtime.pendingPhones.remember(
              _pendingMemberId!,
              _pendingPhone!,
            ),
          );
        }
        final opId = _pending!.operationId;
        final confirmed =
            widget.runtime.store.operation(opId)?.state ==
            SharedCommandState.committed;
        setState(() {
          _adding = false;
          _formError = null;
          _nameField.clear();
          _phoneField.clear();
          _notice = widget.runtime.operationStatus(opId);
          // Confirmed by the server: nothing left to check.
          if (confirmed) _pending = null;
          _roster = widget.runtime.contextRoster(widget.contextId);
        });
        _loadInvitations();
      }
    } on SharedRuntimeUnavailable {
      if (mounted) {
        setState(() {
          _formError = 'Adding people is not available right now.';
        });
      }
    } catch (_) {
      if (mounted) {
        // Shown in the form too: the error used to land in a notice that is
        // only drawn on the list, so the person saw nothing happen.
        setState(() {
          _notice =
              'Could not save the person yet. It is kept on this phone. Try again.';
          if (_adding) _formError = _notice;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the system contact picker. Asks for contacts access only now; a
  /// refusal leaves manual name/number entry fully usable. Nothing is uploaded.
  Future<void> _fillFromContacts() async {
    if (_picking || _busy) return;
    _picking = true;
    final (String, String)? contact;
    try {
      contact = await _pickContact();
    } finally {
      _picking = false;
    }
    if (contact == null || !mounted) return;
    final pickedName = contact.$1;
    final pickedPhone = sharedCleanPhone(contact.$2);

    String? error;
    try {
      final lower = pickedName.trim().toLowerCase();
      if (lower == "you" || lower == "me" || lower == "myself") {
        error = "That name cannot be used. Please choose a different one.";
      } else {
        final current = await _roster;
        final norm = _normalizeName(pickedName);
        if (current.members.any((m) =>
            m.state != 'left' &&
            (_normalizeName(m.name) == norm ||
                (m.rawName != null && _normalizeName(m.rawName!) == norm)))) {
          error =
              'Someone in this split already has that name. Add a surname or initial.';
        } else if (pickedPhone != null &&
            _phones.values.any((p) => _phonesMatch(p, pickedPhone))) {
          error = 'Someone in this split is already invited with that number.';
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _nameField.text = pickedName;
      _phoneField.text = pickedPhone ?? "";
      _formError = error;
    });
  }

  Future<(String, String)?> _pickContact() async {
    try {
      if (!await sharedEnsureContactsAccess(context)) return null;
      final picked = await FlutterContacts.native.showPicker(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      final rawName = picked?.displayName?.trim() ?? "";
      if (picked == null || rawName.isEmpty) return null;
      final name = rawName.length > 40 ? rawName.substring(0, 40).trim() : rawName;
      final numbers = [
        for (final p in picked.phones)
          if (sharedCleanPhone(p.number) != null) sharedCleanPhone(p.number)!,
      ].toSet().toList();
      if (numbers.length > 1 && mounted) {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text("Which number for $name?"),
            children: [
              for (final n in numbers)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, n),
                  child: Text(n),
                ),
            ],
          ),
        );
        if (choice == null) return null;
        return (name, choice);
      }
      final number = numbers.isNotEmpty
          ? numbers.first
          : (picked.phones.isEmpty ? "" : picked.phones.first.number);
      final cleaned = number.replaceAll(RegExp(r"[^+0-9 ()-]"), "").trim();
      return (name, cleaned.length > 20 ? "" : cleaned);
    } catch (_) {
      return null;
    }
  }

  /// Sends the join link through the system share sheet (WhatsApp, SMS, any
  /// app). The link only lets the person ask to join; it accepts no expense.
  Future<void> _share(SharedEditorMember member, {bool direct = false}) async {
    if (_busy || !_authorized || !widget.runtime.proposalsEnabled) return;
    setState(() => _busy = true);
    try {
      final link = _links[member.id] ??= await widget.runtime.inviteLink(
        contextId: widget.contextId,
        memberId: member.id,
        phoneNumber: _phones[member.id],
      );
      if (!mounted || !_authorized) return;
      _loadInvitations();
      await SharePlus.instance.share(
        ShareParams(
          subject: direct
              ? 'Join me on PandaPay'
              : 'Join ${widget.groupName} on PandaPay',
          text: sharedInviteMessage(
            groupName: widget.groupName,
            personName: member.name,
            url: link.url,
            direct: direct,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice =
              'Could not create the invite link. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _form() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    children: [
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          foregroundColor: BambooInk.slate,
          side: const BorderSide(color: BambooInk.ink300),
        ),
        onPressed: _busy ? null : _fillFromContacts,
        icon: const Icon(Icons.contacts_outlined, size: 20),
        label: Text('Pick from contacts', style: BambooFonts.ui(14)),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _nameField,
        autofocus: true,
        maxLength: 40,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        // Once a person is saved on this phone, the name is fixed until the
        // server answers; a different name would add a second person.
        readOnly: _busy || _pending != null,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        style: BambooFonts.ui(15),
        decoration: InputDecoration(
          label: requiredLabel('Name'),
          errorText: requiredError(_formError != null, _nameField.text),
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _phoneField,
        keyboardType: TextInputType.phone,
        maxLength: 20,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        readOnly: _busy || _pending != null,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _add(),
        style: BambooFonts.ui(15),
        decoration: const InputDecoration(
          labelText: 'Mobile number (optional)',
        ),
      ),
      SharedPhoneLookupStatus(
        runtime: widget.runtime,
        controller: _phoneField,
        // The status line shows the answer itself; submit re-checks the number.
        onResult: (_) {},
      ),
      const SizedBox(height: 8),
      Text(
        'With a number, only that person can join without your approval. Without one, you approve their request. Nothing is shared until you tap Invite.',
        style: BambooFonts.ui(12, color: BambooInk.ink700),
      ),
      if (_formError != null && _nameField.text.trim().isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(_formError!, style: BambooFonts.ui(13, color: BambooInk.clayInk)),
      ],
      const SizedBox(height: 20),
      FilledButton(
        style: sharedPrimaryButtonStyle(),
        onPressed: _busy ? null : _add,
        child: Text(
          _busy ? 'Saving…' : 'Add person',
          style: BambooFonts.ui(
            15,
            weight: FontWeight.w600,
            color: BambooInk.lime,
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => SharedContextGuard(
    runtime: widget.runtime,
    contextId: widget.contextId,
    builder: (context) {
      final media = MediaQuery.of(context);
      return SafeArea(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SizedBox(
            height: (media.size.height * .75).clamp(
              0.0,
              media.size.height - media.viewInsets.bottom - 96,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      if (_adding)
                        IconButton(
                          tooltip: 'Back to members',
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _adding = false;
                                  _formError = null;
                                }),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      Expanded(
                        child: Text(
                          _adding
                              ? 'Add person'
                              : '${widget.groupName} · Members',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: BambooFonts.heading(18),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _adding
                      ? _form()
                      : FutureBuilder<SharedRoster>(
                          future: _roster,
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Center(
                                child: TextButton(
                                  onPressed: () => setState(() {
                                    _roster = widget.runtime.contextRoster(
                                      widget.contextId,
                                    );
                                  }),
                                  child: const Text('Try again'),
                                ),
                              );
                            }
                            // While a newer roster loads, keep showing the last
                            // one: a spinner here threw away the scroll position
                            // and the notice after every action.
                            if (!snapshot.hasData) {
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: BambooInk.slate,
                                ),
                              );
                            }
                            final roster = snapshot.data!;
                            final hints = _sameNameHints(roster);
                            return ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                const SharedNotice(
                                  'Adding a name records an unverified person. Tap Invite to share a join link; joining never accepts any expense or debt.',
                                ),
                                if (_notice != null) SharedNotice(_notice!),
                                if (!roster.direct &&
                                    roster.canShareLink &&
                                    widget.runtime.proposalsEnabled)
                                  _groupLinkCard(),
                                for (final member in roster.members)
                                  ListTile(
                                    key: ValueKey('member-${member.id}'),
                                    // Only joined people have an avatar to show;
                                    // invited rows keep their old layout.
                                    leading: member.profileId == null
                                        ? null
                                        : MemberAvatar(
                                            profileId: member.profileId,
                                            name: member.id == roster.ownMemberId
                                                ? 'You'
                                                : _displayName(member),
                                            self:
                                                member.id == roster.ownMemberId,
                                          ),
                                    title: Text(
                                      member.id == roster.ownMemberId
                                          ? 'You'
                                          : _displayName(member),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: BambooFonts.ui(
                                        14,
                                        weight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: _subtitle(roster, member, hints),
                                    // TextButton, not FilledButton: the app theme
                                    // forces filled buttons full width in a trailing.
                                    trailing:
                                        roster.canShareLink &&
                                            _inv[member.id]?.status ==
                                                'awaiting_owner'
                                        ? Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              TextButton(
                                                onPressed: _busy
                                                    ? null
                                                    : () => _decide(
                                                        _inv[member.id]!,
                                                        false,
                                                      ),
                                                child: Text(
                                                  'Decline',
                                                  style: BambooFonts.ui(13),
                                                ),
                                              ),
                                              TextButton(
                                                onPressed: _busy
                                                    ? null
                                                    : () => _decide(
                                                        _inv[member.id]!,
                                                        true,
                                                      ),
                                                child: Text(
                                                  'Approve',
                                                  style: BambooFonts.ui(
                                                    13,
                                                    weight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          )
                                        : roster.canShareLink &&
                                              widget.runtime.proposalsEnabled &&
                                              member.state == 'invited' &&
                                              member.profileId == null
                                        ? Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              TextButton(
                                                onPressed: _busy
                                                    ? null
                                                    : () => _remove(member),
                                                child: Text(
                                                  'Remove',
                                                  style: BambooFonts.ui(13),
                                                ),
                                              ),
                                              TextButton.icon(
                                                onPressed: _busy
                                                    ? null
                                                    : () => _share(
                                                        member,
                                                        direct: roster.direct,
                                                      ),
                                                icon: const Icon(
                                                  Icons.share_outlined,
                                                  size: 18,
                                                ),
                                                label: Text(switch (_inv[member
                                                        .id]
                                                    ?.status) {
                                                  'declined' ||
                                                  'expired' ||
                                                  'rejected' => 'Invite again',
                                                  'open' => 'Send link',
                                                  _ => 'Invite',
                                                }, style: BambooFonts.ui(13)),
                                              ),
                                            ],
                                          )
                                        : roster.canShareLink &&
                                              widget.runtime.proposalsEnabled &&
                                              member.state == 'active' &&
                                              member.profileId != null &&
                                              member.id != roster.ownMemberId
                                        ? TextButton(
                                            onPressed: _busy
                                                ? null
                                                : () => _makeOwner(member),
                                            child: Text(
                                              'Make owner',
                                              style: BambooFonts.ui(13),
                                            ),
                                          )
                                        : null,
                                  ),
                                if (roster.canInvite &&
                                    widget.runtime.proposalsEnabled &&
                                    _pending == null)
                                  FilledButton.icon(
                                    style: sharedPrimaryButtonStyle(),
                                    onPressed: _busy
                                        ? null
                                        : () => setState(() => _adding = true),
                                    icon: const Icon(Icons.person_add_outlined),
                                    label: Text(
                                      _busy ? 'Saving…' : 'Add person',
                                      style: BambooFonts.ui(
                                        14,
                                        color: BambooInk.lime,
                                      ),
                                    ),
                                  ),
                                if (roster.ownerGone &&
                                    !roster.canShareLink &&
                                    roster.ownMemberId.isNotEmpty)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton(
                                      onPressed: _busy ? null : _takeOver,
                                      child: Text(
                                        'The owner is gone · Take over as owner',
                                        style: BambooFonts.ui(
                                          13,
                                          weight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (!roster.canShareLink &&
                                    roster.ownMemberId.isNotEmpty)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton(
                                      onPressed: _busy ? null : _leave,
                                      child: Text(
                                        'Leave this split',
                                        style: BambooFonts.ui(
                                          13,
                                          color: BambooInk.ink700,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (_pending != null)
                                  TextButton(
                                    onPressed: _busy ? null : _add,
                                    child: Text(
                                      _busy ? 'Checking…' : 'Check status',
                                      style: BambooFonts.ui(14),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
