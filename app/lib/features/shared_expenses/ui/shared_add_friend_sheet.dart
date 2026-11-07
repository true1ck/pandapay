import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import '../../../app/design/app_theme.dart';
import '../data/shared_directory.dart';
import '../data/shared_invitations.dart';
import '../data/shared_transport.dart';
import '../storage/shared_store.dart' show SharedNameException;
import '../runtime/shared_runtime.dart';
import 'shared_components.dart';

/// Live answer under a phone field: is this number already on PandaPay?
/// Checks only after the user finished typing or picked a contact, only that
/// one number, and a failed check never blocks adding the person.
class SharedPhoneLookupStatus extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final TextEditingController controller;
  final ValueChanged<SharedPhoneLookup> onResult;
  const SharedPhoneLookupStatus({
    super.key,
    required this.runtime,
    required this.controller,
    required this.onResult,
  });
  @override
  State<SharedPhoneLookupStatus> createState() => _LookupState();
}

class _LookupState extends State<SharedPhoneLookupStatus> {
  Timer? _debounce;
  String? _checked;
  bool _checking = false;
  SharedPhoneLookup? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    _debounce?.cancel();
    final phone = sharedCleanPhone(widget.controller.text);
    if (phone == _checked && phone != null) return;
    if (phone == null) {
      _checked = null;
      if (_result != null || _error != null || _checking) {
        setState(() {
          _result = null;
          _error = null;
          _checking = false;
        });
        widget.onResult(SharedPhoneLookup.none);
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () => _check(phone));
  }

  Future<void> _check(String phone) async {
    if (!mounted) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result = await widget.runtime.lookupPhone(phone);
      if (!mounted || sharedCleanPhone(widget.controller.text) != phone) {
        return;
      }
      _checked = phone;
      setState(() {
        _result = result;
        _checking = false;
      });
      widget.onResult(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _result = null;
        _error = sharedInviteIssueMessage(error);
      });
      widget.onResult(SharedPhoneLookup.none);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final (IconData icon, String text, Color color) = _checking
        ? (Icons.hourglass_empty_rounded, 'Checking…', BambooInk.ink700)
        : _error != null
        ? (Icons.info_outline_rounded, _error!, BambooInk.clayInk)
        : r == null
        ? (Icons.phone_outlined, '', BambooInk.ink700)
        : r.self
        ? (
            Icons.info_outline_rounded,
            'That is your own number.',
            BambooInk.clayInk,
          )
        : r.found
        ? (
            Icons.check_circle_outline_rounded,
            r.existingContextId != null
                ? 'You already split with ${r.displayName ?? 'this person'} on PandaPay.'
                : '${r.displayName ?? 'This person'} is on PandaPay. They will see your invite in the app.',
            BambooInk.slate,
          )
        : (
            Icons.share_outlined,
            'Not on PandaPay yet. You can share an invite link next.',
            BambooInk.ink700,
          );
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: BambooFonts.ui(12.5, color: color)),
          ),
        ],
      ),
    );
  }
}

/// Picks one contact. Asks for contacts access only when tapped; a refusal
/// leaves manual entry fully usable. Nothing is uploaded.
Future<(String, String)?> sharedPickContact(BuildContext context) async {
  try {
    final status = await Permission.contacts.request();
    if (!status.isGranted) {
      if (context.mounted) {
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
    final rawName = picked?.displayName?.trim() ?? '';
    if (picked == null || rawName.isEmpty) return null;
    final name = rawName.length > 40 ? rawName.substring(0, 40).trim() : rawName;
    final numbers = [
      for (final p in picked.phones)
        if (sharedCleanPhone(p.number) != null) sharedCleanPhone(p.number)!,
    ].toSet().toList();
    if (numbers.length > 1 && context.mounted) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text('Which number for $name?'),
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
    return (name, numbers.isEmpty ? '' : numbers.first);
  } catch (_) {
    return null;
  }
}

final class SharedAddFriendInput {
  final String name;
  final String? phone;
  final SharedPhoneLookup lookup;
  const SharedAddFriendInput(this.name, this.phone, this.lookup);
}

class SharedAddFriendSheet extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final String? initialName, initialPhone, initialError;
  const SharedAddFriendSheet({
    super.key,
    required this.runtime,
    this.initialName,
    this.initialPhone,
    this.initialError,
  });
  static Future<SharedAddFriendInput?> show(
    BuildContext context,
    SharedExpensesRuntime runtime, {
    String? initialName,
    String? initialPhone,
    String? initialError,
  }) => showModalBottomSheet<SharedAddFriendInput>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: BambooInk.paper,
    builder: (_) => SharedAddFriendSheet(
      runtime: runtime,
      initialName: initialName,
      initialPhone: initialPhone,
      initialError: initialError,
    ),
  );
  @override
  State<SharedAddFriendSheet> createState() => _AddFriendState();
}

class _AddFriendState extends State<SharedAddFriendSheet> {
  late final _name = TextEditingController(text: widget.initialName),
      _phone = TextEditingController(text: widget.initialPhone);
  SharedPhoneLookup _lookup = SharedPhoneLookup.none;
  late String? _error = widget.initialError;

  @override
  void initState() {
    super.initState();
    _name.addListener(_onFieldChanged);
    _phone.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    if (_error != null) {
      setState(() => _error = null);
    }
  }

  @override
  void dispose() {
    _name.removeListener(_onFieldChanged);
    _phone.removeListener(_onFieldChanged);
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final contact = await sharedPickContact(context);
    if (contact == null || !mounted) return;
    final pickedName = contact.$1;
    final pickedPhone = sharedCleanPhone(contact.$2);
    String? error;
    final lower = pickedName.trim().toLowerCase();
    if (lower == 'you' || lower == 'me' || lower == 'myself') {
      error = 'That name cannot be used. Please choose a different one.';
    }
    setState(() {
      _name.text = pickedName;
      _phone.text = pickedPhone ?? '';
      _error = error;
    });
  }

  void _submit() {
    final name = _name.text.trim(), raw = _phone.text.trim();
    if (name.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    if (name.length > 40) {
      setState(() => _error = 'Use 40 characters or fewer.');
      return;
    }
    final lower = name.toLowerCase();
    if (lower == 'you' || lower == 'me' || lower == 'myself') {
      setState(
        () => _error =
            'That name cannot be used. Please choose a different one.',
      );
      return;
    }
    final phone = sharedCleanPhone(raw);
    if (raw.isNotEmpty && phone == null) {
      setState(
        () => _error = 'Enter a valid mobile number, or leave it empty.',
      );
      return;
    }
    if (_lookup.self) {
      setState(() => _error = 'That is your own number.');
      return;
    }
    Navigator.pop(context, SharedAddFriendInput(name, phone, _lookup));
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      16,
      12,
      16,
      MediaQuery.viewInsetsOf(context).bottom + 16,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Add friend', style: BambooFonts.heading(18))),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            foregroundColor: BambooInk.slate,
            side: const BorderSide(color: BambooInk.ink300),
          ),
          onPressed: _pick,
          icon: const Icon(Icons.contacts_outlined, size: 20),
          label: Text('Pick from contacts', style: BambooFonts.ui(14)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          maxLength: 40,
          buildCounter:
              (_, {required currentLength, required isFocused, maxLength}) =>
                  null,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          style: BambooFonts.ui(15),
          decoration: const InputDecoration(labelText: 'Friend name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          maxLength: 20,
          buildCounter:
              (_, {required currentLength, required isFocused, maxLength}) =>
                  null,
          style: BambooFonts.ui(15),
          decoration: const InputDecoration(
            labelText: 'Mobile number (optional)',
          ),
        ),
        SharedPhoneLookupStatus(
          runtime: widget.runtime,
          controller: _phone,
          onResult: (r) {
            if (!mounted) return;
            setState(() {
              _lookup = r;
              if (r.found && _name.text.trim().isEmpty) {
                _name.text = r.displayName ?? '';
              }
            });
          },
        ),
        const SizedBox(height: 8),
        Text(
          'With a number, we check if they are on PandaPay and send the invite to them. Without one, you can share a link later.',
          style: BambooFonts.ui(12, color: BambooInk.ink700),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clayInk)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          style: sharedPrimaryButtonStyle(),
          onPressed: _submit,
          child: Text(
            _lookup.existingContextId != null
                ? 'Open existing split'
                : 'Add friend',
            style: BambooFonts.ui(
              15,
              weight: FontWeight.w600,
              color: BambooInk.lime,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The whole add-friend journey for Quick Add and the Splits hub. Returns the
/// context to open, or null if cancelled or nothing was created.
Future<String?> runAddFriendFlow(
  BuildContext context,
  SharedExpensesRuntime runtime,
) async {
  final messenger = ScaffoldMessenger.of(context);
  String? name0, phone0, error0;
  late SharedAddFriendInput input;
  late SharedFriendAdded added;
  while (true) {
    if (!context.mounted) return null;
    final got = await SharedAddFriendSheet.show(
      context,
      runtime,
      initialName: name0,
      initialPhone: phone0,
      initialError: error0,
    );
    if (got == null || !context.mounted) return null;
    input = got;
    name0 = input.name;
    phone0 = input.phone;
    error0 = null;
    final existing = input.lookup.existingContextId;
    if (existing != null) return existing;
    final same = await runtime.sameNameFriend(input.name);
    if (same != null && context.mounted) {
      final open = await showSharedFriendNameTakenDialog(context, input.name);
      if (open == true) return same;
      if (open == null) return null;
      continue; // Edit name
    }
    try {
      added = await runtime.addFriend(name: input.name, phone: input.phone);
      break;
    } on SharedNameException catch (error) {
      if (!context.mounted) return null;
      if (error.code == 'friend_name_taken') {
        final open = await showSharedFriendNameTakenDialog(context, input.name);
        if (open == true && error.existingContextId != null) {
          return error.existingContextId;
        }
        if (open == null) return null;
      }
      error0 = sharedInviteIssueMessage(
        SharedTransportException(code: error.code),
      );
    } catch (error) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not save the friend yet. Try again in a moment.',
          ),
        ),
      );
      return null;
    }
  }
  try {
    if (added.link != null && !input.lookup.found) {
      await SharePlus.instance.share(
        ShareParams(
          subject: 'Join me on PandaPay',
          text: sharedInviteMessage(
            groupName: input.name,
            personName: input.name,
            url: added.link!.url,
            direct: true,
          ),
        ),
      );
    } else if (added.link != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${input.name} will see your invite next time they open PandaPay.',
          ),
        ),
      );
    } else if (added.inviteIssue != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Friend saved. ${added.inviteIssue}'),
          duration: const Duration(seconds: 8),
          action: added.phone == null
              ? null
              : SnackBarAction(
                  label: 'Try again',
                  onPressed: () async {
                    try {
                      final link = await runtime.inviteLink(
                        contextId: added.contextId,
                        memberId: added.memberId,
                        phoneNumber: added.phone,
                      );
                      await SharePlus.instance.share(
                        ShareParams(
                          subject: 'Join me on PandaPay',
                          text: sharedInviteMessage(
                            groupName: input.name,
                            personName: input.name,
                            url: link.url,
                            direct: true,
                          ),
                        ),
                      );
                    } catch (e) {
                      messenger.showSnackBar(
                        SnackBar(content: Text(sharedInviteIssueMessage(e))),
                      );
                    }
                  },
                ),
        ),
      );
    }
    return added.contextId;
  } catch (error) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Could not save the friend yet. Try again in a moment.'),
      ),
    );
    return null;
  }
}

/// Same-name friend: open the chat they already have, or change the name.
/// There is deliberately no "add anyway". Returns true to open the existing
/// chat, false to edit the name, null if dismissed.
Future<bool?> showSharedFriendNameTakenDialog(
  BuildContext context,
  String name,
) => showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text('You already have a friend called $name'),
    content: const Text(
      'Open that chat or use a different name (add a surname).',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(ctx, false),
        child: const Text('Edit name'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(ctx, true),
        child: const Text('Open existing'),
      ),
    ],
  ),
);
