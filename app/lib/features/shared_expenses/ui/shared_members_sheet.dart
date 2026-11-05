import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../../../app/design/app_theme.dart';
import '../data/shared_commands.dart';
import '../composer/shared_editor.dart';
import '../data/shared_invitations.dart';
import '../runtime/shared_runtime.dart';
import '../data/shared_directory.dart';
import 'shared_add_friend_sheet.dart';
import 'shared_components.dart';
import 'shared_context_guard.dart';

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
  static Future<void> show(
    BuildContext context, {
    required SharedExpensesRuntime runtime,
    required String contextId,
    required String groupName,
  }) => showModalBottomSheet<void>(
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
  SharedPhoneLookup _lookup = SharedPhoneLookup.none;
  Map<String, SharedOwnerInvitation> _inv = const {};
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
      'awaiting_owner' => 'Wants to join',
      'declined' => 'Declined the invite',
      'expired' => 'Invite expired',
      'rejected' => 'Not invited right now',
      _ => 'Not on PandaPay · unclaimed',
    };
  }

  @override
  void dispose() {
    _nameField.dispose();
    _phoneField.dispose();
    super.dispose();
  }

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
        final cleaned = phone.isEmpty ? null : sharedCleanPhone(phone);
        if (phone.isNotEmpty && cleaned == null) {
          setState(
            () =>
                _formError = 'Enter a valid mobile number, or leave it empty.',
          );
          return;
        }
        if (_lookup.self) {
          setState(() => _formError = 'That is your own number.');
          return;
        }
        final name = text;
        _pendingPhone = cleaned;
        final current = await widget.runtime.contextRoster(widget.contextId);
        if (!current.canInvite) throw const SharedRuntimeUnavailable();
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
      if (!_authorized || !widget.runtime.proposalsEnabled) return;
      await widget.runtime.store.enqueue(_pending!);
      await widget.runtime.flushEditor();
      if (mounted && _authorized) {
        if (_pendingPhone != null && _pendingMemberId != null) {
          _phones[_pendingMemberId!] = _pendingPhone!;
        }
        setState(() {
          _adding = false;
          _formError = null;
          _nameField.clear();
          _phoneField.clear();
          _notice = widget.runtime.operationStatus(_pending!.operationId);
          _roster = widget.runtime.contextRoster(widget.contextId);
        });
        _loadInvitations();
      }
    } catch (_) {
      if (mounted) {
        _notice =
            'Could not save the person yet. It is kept on this phone. Try again.';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the system contact picker. Asks for contacts access only now; a
  /// refusal leaves manual name/number entry fully usable. Nothing is uploaded.
  Future<void> _fillFromContacts() async {
    final contact = await _pickContact();
    if (contact == null || !mounted) return;
    setState(() {
      _nameField.text = contact.$1;
      _phoneField.text = sharedCleanPhone(contact.$2) ?? '';
      _formError = null;
    });
  }

  Future<(String, String)?> _pickContact() async {
    try {
      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Contacts access was not granted. You can still type a name and number.',
              ),
            ),
          );
        }
        return null;
      }
      final picked = await FlutterContacts.native.showPicker(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      final name = picked?.displayName?.trim() ?? '';
      if (picked == null || name.isEmpty) return null;
      final number = picked.phones.isEmpty ? '' : picked.phones.first.number;
      final cleaned = number.replaceAll(RegExp(r'[^+0-9 ()-]'), '').trim();
      return (name, cleaned.length > 20 ? '' : cleaned);
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
        maxLength: 120,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        style: BambooFonts.ui(15),
        decoration: const InputDecoration(labelText: 'Name'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _phoneField,
        keyboardType: TextInputType.phone,
        maxLength: 20,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        textInputAction: TextInputAction.done,
        style: BambooFonts.ui(15),
        decoration: const InputDecoration(
          labelText: 'Mobile number (optional)',
        ),
      ),
      SharedPhoneLookupStatus(
        runtime: widget.runtime,
        controller: _phoneField,
        onResult: (r) {
          if (mounted) setState(() => _lookup = r);
        },
      ),
      const SizedBox(height: 8),
      Text(
        'With a number, only that person can join without your approval. Without one, you approve their request. Nothing is shared until you tap Invite.',
        style: BambooFonts.ui(12, color: BambooInk.ink700),
      ),
      if (_formError != null) ...[
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
                            if (!snapshot.hasData ||
                                snapshot.connectionState ==
                                    ConnectionState.waiting) {
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: BambooInk.slate,
                                ),
                              );
                            }
                            final roster = snapshot.data!;
                            return ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                const SharedNotice(
                                  'Adding a name records an unverified person. Tap Invite to share a join link; joining never accepts any expense or debt.',
                                ),
                                if (_notice != null) SharedNotice(_notice!),
                                for (final member in roster.members)
                                  ListTile(
                                    title: Text(
                                      member.id == roster.ownMemberId
                                          ? 'You'
                                          : member.name,
                                      style: BambooFonts.ui(
                                        14,
                                        weight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      switch (member.state) {
                                        'active' =>
                                          member.profileId == null
                                              ? 'Identity not verified'
                                              : 'Active member',
                                        'invited' =>
                                          member.profileId == null
                                              ? _statusLine(member)
                                              : 'Invitation pending',
                                        'removed' =>
                                          'Removed · history retained',
                                        'left' => 'Left · history retained',
                                        _ => 'Membership needs review',
                                      },
                                      style: BambooFonts.ui(
                                        12,
                                        color: BambooInk.ink700,
                                      ),
                                    ),
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
                                        ? TextButton.icon(
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
                                            label: Text(
                                              switch (_inv[member.id]?.status) {
                                                'declined' ||
                                                'expired' ||
                                                'rejected' => 'Invite again',
                                                'open' => 'Send link',
                                                _ => 'Invite',
                                              },
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
