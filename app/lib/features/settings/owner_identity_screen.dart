import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/required_field.dart';
import '../sms_v2/personal/owner_identity_store.dart';
import '../sms_v2/ui/owner_identity_actions.dart';

/// "Your names & accounts": who PandaPay treats as you, so a payment between
/// your own accounts is a transfer and not spending or income.
class OwnerIdentityScreen extends ConsumerStatefulWidget {
  const OwnerIdentityScreen({super.key});

  @override
  ConsumerState<OwnerIdentityScreen> createState() =>
      _OwnerIdentityScreenState();
}

class _OwnerIdentityScreenState extends ConsumerState<OwnerIdentityScreen> {
  final _first = TextEditingController();
  final _middle = TextEditingController();
  final _last = TextEditingController();
  List<OwnerEntry> _entries = const [];
  final Map<String, String> _paymentText = {};
  String? _profileName;
  bool _loading = true;
  bool _busy = false;
  bool _submitted = false;
  String? _error;

  OwnerIdentityActions get _actions => OwnerIdentityActions(ref);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _first.dispose();
    _middle.dispose();
    _last.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final entries = await _actions.entries();
      final name = await _actions.profileName();
      // The single payments the person marked, in words they recognise.
      final text = <String, String>{};
      for (final e in entries) {
        final key = _onceKey(e.entry);
        if (key != null) {
          final line = await _actions.describePayment(key);
          if (line != null) text[e.entry] = line;
        }
      }
      if (mounted) {
        setState(() {
          _paymentText
            ..clear()
            ..addAll(text);
          _entries = entries;
          _profileName = OwnerName.parse(name) == null ? null : name;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String _changed(int n) => n == 0
      ? 'Saved.'
      : n == 1
      ? 'Saved. 1 earlier transaction was updated.'
      : 'Saved. $n earlier transactions were updated.';

  Future<void> _run(Future<int> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final n = await action();
      await _load();
      _say(_changed(n));
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = e.message.toString());
    } catch (_) {
      if (mounted) setState(() => _error = 'That did not work. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    setState(() => _submitted = true);
    if (_first.text.trim().isEmpty || _last.text.trim().isEmpty) return;
    await _addName();
    if (mounted) setState(() => _submitted = false);
  }

  Future<void> _addName() => _run(() async {
    final n = await _actions.addName(
      first: _first.text,
      middle: _middle.text.trim().isEmpty ? null : _middle.text,
      last: _last.text,
    );
    _first.clear();
    _middle.clear();
    _last.clear();
    return n;
  });

  List<OwnerEntry> _where(bool Function(OwnerEntry) test) => [
    for (final e in _entries)
      if (test(e)) e,
  ];

  /// The message a single-payment mark points at, or null for other entries.
  static String? _onceKey(String entry) {
    for (final prefix in [OwnerIdentity.onceSelfPrefix, OwnerIdentity.onceFamilyPrefix]) {
      if (entry.startsWith(prefix)) return entry.substring(prefix.length);
    }
    return null;
  }

  String _pretty(String entry) {
    if (_onceKey(entry) != null) {
      final what = entry.startsWith(OwnerIdentity.onceFamilyPrefix)
          ? 'Family transfer'
          : 'Self transfer';
      return _paymentText[entry] ?? 'One payment ($what)';
    }
    if (entry.startsWith(OwnerIdentity.familyPayeePrefix)) {
      return entry.substring(OwnerIdentity.familyPayeePrefix.length);
    }
    if (entry.startsWith(OwnerIdentity.familyVpaPrefix)) {
      return 'UPI ID ${entry.substring(OwnerIdentity.familyVpaPrefix.length)}';
    }
    if (entry.startsWith(OwnerIdentity.familyMaskPrefix)) {
      return 'Account ending ${entry.substring(OwnerIdentity.familyMaskPrefix.length)}';
    }
    if (entry.startsWith(OwnerIdentity.payeePrefix)) {
      return entry.substring(OwnerIdentity.payeePrefix.length);
    }
    if (entry.startsWith(OwnerIdentity.vpaPrefix)) {
      return 'UPI ID ${entry.substring(OwnerIdentity.vpaPrefix.length)}';
    }
    if (entry.startsWith(OwnerIdentity.maskPrefix)) {
      return 'Account ending ${entry.substring(OwnerIdentity.maskPrefix.length)}';
    }
    if (entry.startsWith(OwnerIdentity.notNamePrefix)) {
      return entry.substring(OwnerIdentity.notNamePrefix.length);
    }
    if (entry.startsWith(OwnerIdentity.notVpaPrefix)) {
      return 'UPI ID ${entry.substring(OwnerIdentity.notVpaPrefix.length)}';
    }
    if (entry.startsWith(OwnerIdentity.notMaskPrefix)) {
      return 'Account ending ${entry.substring(OwnerIdentity.notMaskPrefix.length)}';
    }
    return entry;
  }

  String _why(OwnerEntry e) => switch (e.source) {
    OwnerEntrySource.user => 'You added this',
    OwnerEntrySource.inferred => 'Learned from your messages',
    OwnerEntrySource.marked => 'You marked this',
    OwnerEntrySource.dismissed => 'Removed',
  };

  Widget _row(String title, String subtitle, {VoidCallback? onRemove}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: BambooInk.glassFillOnPaper,
        child: ListTile(
          title: Text(
            title,
            style: BambooFonts.ui(14.5, color: BambooInk.ink900, weight: FontWeight.w700),
          ),
          subtitle: Text(subtitle, style: BambooFonts.ui(12, color: BambooInk.ink500)),
          trailing: onRemove == null
              ? null
              : IconButton(
                  tooltip: 'Remove',
                  onPressed: _busy ? null : onRemove,
                  icon: const Icon(Icons.close_rounded),
                ),
        ),
      ),
    );
  }

  Widget _section(String title, String? help, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: BambooFonts.heading(17, color: BambooInk.ink900)),
        if (help != null) ...[
          const SizedBox(height: 2),
          Text(help, style: BambooFonts.ui(12.5, color: BambooInk.ink700)),
        ],
        const SizedBox(height: AppSpace.sm),
        ...children,
        const SizedBox(height: AppSpace.lg),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final names = _where((e) => e.isName && e.source != OwnerEntrySource.dismissed);
    bool isFamily(OwnerEntry e) => e.entry.startsWith('family:');
    bool isOnce(OwnerEntry e) => e.entry.startsWith('once:');
    final marked = _where(
      (e) =>
          !e.isName &&
          !e.entry.startsWith('not:') &&
          !isFamily(e) &&
          !isOnce(e) &&
          e.source != OwnerEntrySource.dismissed,
    );
    final family = _where(isFamily);
    final once = _where(isOnce);
    final notMine = _where((e) => e.entry.startsWith('not:'));
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Your names & accounts', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  Text(
                    'When money moves between your own accounts, it is a transfer: '
                    'not spending and not money in. PandaPay recognises your own '
                    'accounts by the names the banks print for you.',
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  _section(
                    'Names we treat as yours',
                    'A first name and a last name are enough. Middle names the bank '
                    'prints are fine.',
                    [
                      if (_profileName != null)
                        _row(_profileName!, 'From your profile'),
                      for (final e in names)
                        _row(_pretty(e.entry), _why(e), onRemove: () => _run(() => _actions.remove(e.entry))),
                      if (_profileName == null && names.isEmpty)
                        Text(
                          'None yet. Add your name below. PandaPay also learns it '
                          'from the messages you receive.',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                    ],
                  ),
                  _section('Add your name', null, [
                    TextField(
                      controller: _first,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) {
                        if (_submitted) setState(() {});
                      },
                      decoration: InputDecoration(
                        label: requiredLabel('First name'),
                        errorText: requiredError(_submitted, _first.text),
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    TextField(
                      controller: _middle,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Middle name (optional)'),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    TextField(
                      controller: _last,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) {
                        if (_submitted) setState(() {});
                      },
                      decoration: InputDecoration(
                        label: requiredLabel('Last name'),
                        errorText: requiredError(_submitted, _last.text),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpace.sm),
                      Text(_error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
                    ],
                    const SizedBox(height: AppSpace.md),
                    FilledButton(
                      onPressed: _busy ? null : _add,
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Add name'),
                    ),
                  ]),
                  if (marked.isNotEmpty)
                    _section(
                      'Payees you marked as your own',
                      'Payments to these are transfers. You can mark one from any '
                      'transaction.',
                      [
                        for (final e in marked)
                          _row(_pretty(e.entry), _why(e), onRemove: () => _run(() => _actions.remove(e.entry))),
                      ],
                    ),
                  if (family.isNotEmpty)
                    _section(
                      'Family members you marked',
                      'Payments to or from these are transfers between people, not '
                      'spending or money in. You can mark one from any transaction.',
                      [
                        for (final e in family)
                          _row(_pretty(e.entry), _why(e), onRemove: () => _run(() => _actions.remove(e.entry))),
                      ],
                    ),
                  if (once.isNotEmpty)
                    _section(
                      'Single payments you marked',
                      'You marked these one at a time. Other payments to the same '
                      'payee are not affected.',
                      [
                        for (final e in once)
                          _row(
                            _pretty(e.entry),
                            e.entry.startsWith(OwnerIdentity.onceFamilyPrefix)
                                ? 'Family transfer'
                                : 'Self transfer',
                            onRemove: () => _run(() => _actions.remove(e.entry)),
                          ),
                      ],
                    ),
                  if (notMine.isNotEmpty)
                    _section(
                      'Marked as not yours',
                      'Payments to these are never treated as transfers, even if the '
                      'name looks like yours.',
                      [
                        for (final e in notMine)
                          _row(_pretty(e.entry), _why(e), onRemove: () => _run(() => _actions.remove(e.entry))),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}
