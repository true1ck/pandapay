import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/user_cards_repository.dart'
    show TransactionEntry, TransactionSplit;
import '../shared_expenses/storage/shared_store.dart' show SharedCommandState;
import '../shared_expenses/composer/shared_draft.dart'
    show SharedDraftBlocker, SharedDraftPreview;
import '../shared_expenses/composer/shared_editor.dart';
import '../shared_expenses/composer/shared_source_seed.dart';
import '../shared_expenses/runtime/shared_providers.dart';
import '../shared_expenses/runtime/shared_runtime.dart';
import '../shared_expenses/ui/shared_add_friend_sheet.dart';

/// Which way the payment is being split.
enum SplitScreenMode { friends, justMe }

/// A dedicated "Split expense" page opened from a transaction, laid out like
/// Splitwise: the bill on top, who it is split with, how (equally / exact /
/// percent / shares), and a running "you get back" summary.
///
/// It never creates a second bank transaction. The original payment stays as
/// it is; a split records who owes whom.
///
///  * **With friends** reuses [SharedEditor], the same engine the Splits tab
///    uses, so every amount is validated by the one shared-expense rule set and
///    submitted through the same outbox.
///  * **Just for me** keeps private labelled allocations ("₹400 was Priya's").
class SplitExpenseScreen extends ConsumerStatefulWidget {
  final TransactionEntry entry;
  final String? note;

  /// Private allocations that already exist on this payment.
  final List<TransactionSplit> initialPrivate;

  /// Saves private allocations. An empty list clears them.
  final Future<void> Function(List<TransactionSplit> shares) onSavePrivate;
  final SplitScreenMode initialMode;

  const SplitExpenseScreen({
    super.key,
    required this.entry,
    required this.onSavePrivate,
    this.note,
    this.initialPrivate = const [],
    this.initialMode = SplitScreenMode.friends,
  });

  @override
  ConsumerState<SplitExpenseScreen> createState() => _SplitExpenseScreenState();
}

class _SplitExpenseScreenState extends ConsumerState<SplitExpenseScreen> {
  late SplitScreenMode _mode = widget.initialMode;

  // ── With friends ────────────────────────────────────────────────────
  SharedExpensesRuntime? _runtime;
  SharedEditor? _editor;
  List<Map<String, Object?>> _contexts = const [];
  String? _friendsError;
  bool _loadingFriends = true;
  bool _busy = false;
  bool _sealedDone = false;

  // ── Just for me ─────────────────────────────────────────────────────
  late final List<TextEditingController> _amounts;
  late final List<TextEditingController> _labels;
  final _original = <TextEditingController, TransactionSplit>{};
  String? _privateError;

  String? get _accountId {
    final ns = ref.read(cacheNamespaceProvider);
    return ns.startsWith('user:') ? ns.substring(5) : null;
  }

  @override
  void initState() {
    super.initState();
    final seed = widget.initialPrivate.isEmpty
        ? const [TransactionSplit(amount: Money.zero())]
        : widget.initialPrivate;
    _amounts = [
      for (final s in seed)
        TextEditingController(
          text: s.amount.isZero ? '' : s.amount.rupees.toStringAsFixed(2),
        ),
    ];
    _labels = [for (final s in seed) TextEditingController(text: s.note ?? '')];
    for (var i = 0; i < seed.length; i++) {
      _original[_amounts[i]] = seed[i];
    }
    unawaited(_startFriends());
  }

  @override
  void dispose() {
    _editor?.removeListener(_editorChanged);
    _editor?.dispose();
    for (final c in [..._amounts, ..._labels]) {
      c.dispose();
    }
    super.dispose();
  }

  void _editorChanged() {
    if (mounted) setState(() {});
  }

  // ═════════════════ friends: loading ═════════════════

  Future<void> _startFriends() async {
    setState(() {
      _loadingFriends = true;
      _friendsError = null;
    });
    try {
      final account = _accountId;
      if (account == null) {
        throw const _Friendly('Sign in to split with friends.');
      }
      final runtime = await ref.read(sharedExpensesRuntimeProvider.future);
      if (!mounted || !runtime.isCurrent()) return;
      if (!runtime.proposalsEnabled) {
        throw const _Friendly('Splitting with friends is not available yet.');
      }
      final SharedSourceSeed seed;
      try {
        seed = SharedSourceSeed.fromTransaction(account, widget.entry);
      } on FormatException {
        throw const _Friendly(
          'This payment is still being matched. Try again in a moment, or use Just for me.',
        );
      }
      final editor = SharedEditor(
        store: runtime.store,
        accountId: account,
        expenseId: seed.expenseId,
      );
      editor.attachSourceIntent(seed.reference, widget.entry.amount);
      editor.setBill(seed.amountText);
      editor.setTitle(_title);
      editor.setDate(widget.entry.occurredAt);
      editor.setPrivateFields({
        'categoryId': widget.entry.categoryId,
        'tagIds': widget.entry.tags.map((t) => t.id).toList(),
        'note': widget.note ?? widget.entry.note ?? '',
      });
      editor.addListener(_editorChanged);
      _editor?.removeListener(_editorChanged);
      _editor?.dispose();
      _runtime = runtime;
      _editor = editor;
      await _loadContexts(runtime);
      // One friend or group: nothing to choose, so don't make them.
      if (_contexts.length == 1 && mounted) {
        await _selectContext(_contexts.single['contextId'] as String);
      }
    } on _Friendly catch (e) {
      _friendsError = e.message;
    } catch (_) {
      _friendsError = 'Could not load your friends and groups. Try again.';
    } finally {
      if (mounted) setState(() => _loadingFriends = false);
    }
  }

  String get _title {
    final name = widget.entry.merchantName?.trim();
    return name == null || name.isEmpty ? 'Expense' : name;
  }

  Future<void> _loadContexts(SharedExpensesRuntime runtime) async {
    final page = await runtime.contexts();
    final rows = (page['items'] as List? ?? const [])
        .whereType<Map>()
        .where((r) => r['membershipState'] == 'active')
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    if (mounted) setState(() => _contexts = rows);
  }

  Future<void> _selectContext(String id) async {
    final runtime = _runtime, editor = _editor;
    if (runtime == null || editor == null || editor.sealed) return;
    setState(() {
      _loadingFriends = true;
      _friendsError = null;
    });
    try {
      final value = await runtime.editorContext(id);
      if (!mounted || !runtime.isCurrent() || _editor != editor) return;
      editor.selectContext(id, value.name, value.members, value.ownMemberId);
    } catch (_) {
      _friendsError = 'Could not load the people in this split. Try again.';
    } finally {
      if (mounted) setState(() => _loadingFriends = false);
    }
  }

  Future<void> _addFriend() async {
    final runtime = _runtime;
    if (runtime == null || _busy) return;
    try {
      final id = await runAddFriendFlow(context, runtime);
      if (id == null || !mounted) return;
      await _loadContexts(runtime);
      await _selectContext(id);
    } catch (_) {
      if (mounted) {
        setState(() => _friendsError = 'Could not save the friend. Try again.');
      }
    }
  }

  // ═════════════════ friends: submit ═════════════════

  Future<void> _submitFriends() async {
    final editor = _editor, runtime = _runtime;
    if (editor == null || runtime == null || _busy || !runtime.isCurrent()) {
      return;
    }
    if (!editor.sealed && !editor.canSubmit) return;
    setState(() {
      _busy = true;
      _friendsError = null;
    });
    try {
      final command = await editor.seal();
      await runtime.flushEditor();
      final queued = runtime.store.operation(command.operationId);
      final receipt = runtime.store.receipt(command.operationId);
      final result = receipt?.result;
      final accepted = result is Map && result['status'] == 'accepted';
      final message = accepted
          ? 'Split saved'
          : queued?.state == SharedCommandState.rejected
          ? 'Split saved locally but not accepted. Review it in Splits.'
          : receipt != null
          ? 'Sent for approval. Balances change once they approve.'
          : 'Saved on this phone · will sync when you are online';
      if (!mounted) return;
      _sealedDone = true;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (mounted) {
        setState(
          () => _friendsError = editor.sealed
              ? 'Saved on this phone. Check Splits before trying again.'
              : 'Could not submit the split. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ═════════════════ just for me ═════════════════

  Money _amount(TextEditingController c) {
    final parsed = double.tryParse(c.text.trim());
    return parsed == null || !parsed.isFinite || parsed <= 0
        ? const Money.zero()
        : Money.fromRupees(parsed);
  }

  int get _enteredPaise => _amounts.fold(0, (sum, c) => sum + _amount(c).paise);
  bool get _over => _enteredPaise > widget.entry.amount.paise;
  bool get _invalid => _amounts.any((c) {
    final t = c.text.trim();
    return t.isNotEmpty &&
        (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(t) || _amount(c).isZero);
  });
  bool get _hasShares => _amounts.any((c) => !_amount(c).isZero);
  bool get _canSavePrivate =>
      !_busy &&
      !_over &&
      !_invalid &&
      (_hasShares || widget.initialPrivate.isNotEmpty);

  Future<void> _savePrivate({bool clear = false}) async {
    if (_busy || (!clear && !_canSavePrivate)) return;
    final shares = <TransactionSplit>[];
    if (!clear) {
      for (var i = 0; i < _amounts.length; i++) {
        final amount = _amount(_amounts[i]);
        if (amount.isZero) continue;
        final note = _labels[i].text.trim();
        shares.add(
          TransactionSplit(
            amount: amount,
            note: note.isEmpty ? null : note,
            userCardId: _original[_amounts[i]]?.userCardId,
            categoryId: _original[_amounts[i]]?.categoryId,
          ),
        );
      }
    }
    setState(() {
      _busy = true;
      _privateError = null;
    });
    try {
      await widget.onSavePrivate(shares);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(content: Text(clear ? 'Split cleared' : 'Split saved')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _privateError = 'Could not save the split. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ═════════════════ build ═════════════════

  @override
  Widget build(BuildContext context) {
    // Keeps the auto-disposing runtime alive while this page is open.
    if (ref.read(cacheNamespaceProvider).startsWith('user:')) {
      ref.watch(sharedExpensesRuntimeProvider);
    }
    final friends = _mode == SplitScreenMode.friends;
    return PopScope(
      canPop: !_busy || _sealedDone,
      child: Scaffold(
        backgroundColor: BambooInk.paper,
        appBar: AppBar(
          backgroundColor: BambooInk.paper,
          foregroundColor: BambooInk.ink900,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text('Split expense', style: BambooFonts.heading(18)),
        ),
        body: AppBackground(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                      children: [
                        _billCard(),
                        const SizedBox(height: AppSpace.md),
                        _modeToggle(),
                        const SizedBox(height: AppSpace.md),
                        if (friends) ..._friendsBody() else ..._privateBody(),
                      ],
                    ),
                  ),
                  _bottomBar(friends),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(AppSpace.lg),
    decoration: BoxDecoration(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: child,
  );

  Widget _billCard() {
    final e = widget.entry;
    final d = e.occurredAt.toLocal();
    final date =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return _card(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: BambooInk.lime.withValues(alpha: .35),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.receipt_long_rounded,
              color: BambooInk.slate,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.heading(17, color: BambooInk.ink900),
                ),
                const SizedBox(height: 2),
                Text(
                  'Paid by you · $date',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
          Text(
            e.amount.format(hidePaise: false),
            style: BambooFonts.money(20, color: BambooInk.ink900),
          ),
        ],
      ),
    );
  }

  Widget _modeToggle() {
    Widget tab(SplitScreenMode m, String label, IconData icon) {
      final on = _mode == m;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          label: label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _busy ? null : () => setState(() => _mode = m),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 44,
              decoration: BoxDecoration(
                color: on ? BambooInk.slate : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: on ? BambooInk.lime : BambooInk.ink700,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      style: BambooFonts.ui(
                        14,
                        weight: FontWeight.w700,
                        color: on ? BambooInk.onSlate : BambooInk.ink900,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          tab(
            SplitScreenMode.friends,
            'With friends',
            Icons.people_outline_rounded,
          ),
          tab(
            SplitScreenMode.justMe,
            'Just for me',
            Icons.person_outline_rounded,
          ),
        ],
      ),
    );
  }

  // ───────────── With friends ─────────────

  List<Widget> _friendsBody() {
    final editor = _editor;
    if (_loadingFriends && editor == null) {
      return const [
        Padding(
          padding: EdgeInsets.all(AppSpace.xl),
          child: Center(
            child: CircularProgressIndicator(color: BambooInk.slate),
          ),
        ),
      ];
    }
    if (editor == null) {
      return [
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _friendsError ?? 'Splitting is not available right now.',
                style: BambooFonts.ui(14, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.sm),
              TextButton(
                onPressed: _startFriends,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ];
    }
    final preview = editor.evaluation.preview;
    return [
      _sectionLabel('SPLIT WITH'),
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final c in _contexts)
              Padding(
                padding: const EdgeInsets.only(right: AppSpace.sm),
                child: ChoiceChip(
                  key: ValueKey('split-context-${c['contextId']}'),
                  avatar: Icon(
                    c['kind'] == 'direct'
                        ? Icons.person_outline_rounded
                        : Icons.groups_2_outlined,
                    size: 18,
                    color: editor.contextId == c['contextId']
                        ? BambooInk.lime
                        : BambooInk.ink700,
                  ),
                  label: Text(
                    c['name'] as String? ?? 'Unnamed',
                    style: BambooFonts.ui(
                      13,
                      weight: FontWeight.w600,
                      color: editor.contextId == c['contextId']
                          ? BambooInk.onSlate
                          : BambooInk.ink900,
                    ),
                  ),
                  selected: editor.contextId == c['contextId'],
                  selectedColor: BambooInk.slate,
                  showCheckmark: false,
                  onSelected: editor.sealed || _busy
                      ? null
                      : (_) => _selectContext(c['contextId'] as String),
                ),
              ),
            ActionChip(
              key: const ValueKey('split-add-friend'),
              avatar: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: Text(
                'Add friend',
                style: BambooFonts.ui(13, weight: FontWeight.w600),
              ),
              onPressed: _addFriend,
            ),
          ],
        ),
      ),
      if (_loadingFriends)
        const Padding(
          padding: EdgeInsets.only(top: AppSpace.sm),
          child: LinearProgressIndicator(color: BambooInk.slate),
        ),
      if (_friendsError != null)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Text(
            _friendsError!,
            style: BambooFonts.ui(12.5, color: BambooInk.clayInk),
          ),
        ),
      if (editor.contextId == null && !_loadingFriends)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.md),
          child: _card(
            child: Text(
              _contexts.isEmpty
                  ? 'You have no friends or groups yet. Tap “Add friend” to split this with someone.'
                  : 'Pick a friend or group above to see how this splits.',
              style: BambooFonts.ui(14, color: BambooInk.ink500),
            ),
          ),
        ),
      if (editor.contextId != null) ...[
        const SizedBox(height: AppSpace.md),
        _sectionLabel('SPLIT'),
        _splitTypeRow(editor),
        const SizedBox(height: AppSpace.sm),
        _card(
          child: Column(
            children: [
              for (final m in editor.members) _personRow(editor, m, preview),
            ],
          ),
        ),
        if (editor.mode != SharedSplitMode.equal && preview == null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              editor.evaluation.errors.values.firstOrNull ??
                  'Fill in each person’s share.',
              style: BambooFonts.ui(12.5, color: BambooInk.clayInk),
            ),
          ),
        const SizedBox(height: AppSpace.md),
        _summaryCard(preview),
      ],
    ];
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Text(
      text,
      style: BambooFonts.ui(
        12,
        weight: FontWeight.w700,
        color: BambooInk.ink500,
      ),
    ),
  );

  Widget _splitTypeRow(SharedEditor editor) {
    String label(SharedSplitMode m) => switch (m) {
      SharedSplitMode.equal => 'Equally',
      SharedSplitMode.exact => '₹ Exact',
      SharedSplitMode.percentage => '% Percent',
      SharedSplitMode.shares => 'Shares',
    };
    return Wrap(
      spacing: 8,
      children: [
        for (final m in SharedSplitMode.values)
          ChoiceChip(
            key: ValueKey('split-mode-${m.name}'),
            label: Text(
              label(m),
              style: BambooFonts.ui(
                13,
                weight: FontWeight.w600,
                color: editor.mode == m ? BambooInk.onSlate : BambooInk.ink900,
              ),
            ),
            selected: editor.mode == m,
            selectedColor: BambooInk.slate,
            showCheckmark: false,
            onSelected: editor.sealed || _busy
                ? null
                : (_) => editor.setMode(m),
          ),
      ],
    );
  }

  Widget _personRow(
    SharedEditor editor,
    SharedEditorMember m,
    SharedDraftPreview? preview,
  ) {
    final on = editor.participants.contains(m.id);
    final isMe = m.id == editor.ownMemberId;
    final share = preview?.shares[m.id];
    final unit = switch (editor.mode) {
      SharedSplitMode.exact => '₹',
      SharedSplitMode.percentage => '%',
      SharedSplitMode.shares => 'x',
      SharedSplitMode.equal => '',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Checkbox(
            key: ValueKey('split-person-${m.id}'),
            value: on,
            activeColor: BambooInk.slate,
            checkColor: BambooInk.lime,
            onChanged: editor.sealed || _busy
                ? null
                : (v) => editor.toggleParticipant(m.id, v ?? false),
          ),
          CircleAvatar(
            radius: 16,
            backgroundColor: BambooInk.lime.withValues(alpha: .35),
            foregroundColor: BambooInk.slate,
            child: Text(
              m.name.trim().isEmpty ? '?' : m.name.trim()[0].toUpperCase(),
              style: BambooFonts.ui(13, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              isMe ? '${m.label} (you)' : m.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
            ),
          ),
          if (on && editor.mode != SharedSplitMode.equal)
            SizedBox(
              width: 84,
              child: TextFormField(
                key: ValueKey('split-input-${editor.mode.name}-${m.id}'),
                initialValue: editor.splitInputs[m.id] ?? '',
                readOnly: editor.sealed || _busy,
                textAlign: TextAlign.end,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: BambooFonts.money(14, color: BambooInk.ink900),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '0',
                  suffixText: unit,
                ),
                onChanged: (v) => editor.setSplit(m.id, v),
              ),
            )
          else if (on && share != null)
            Text(
              share.format(hidePaise: false),
              style: BambooFonts.money(14, color: BambooInk.ink900),
            ),
        ],
      ),
    );
  }

  Widget _summaryCard(SharedDraftPreview? preview) {
    if (preview == null) return const SizedBox.shrink();
    final balance = preview.yourBalance.paise;
    return _card(
      child: Column(
        children: [
          _line('You paid', preview.yourFullPaid),
          _line('Your share', preview.yourShare),
          const Divider(color: BambooInk.hairlineOnPaper),
          if (balance > 0)
            _line('You get back', Money.fromPaise(balance), strong: true)
          else if (balance < 0)
            _line('You will owe', Money.fromPaise(-balance), strong: true)
          else
            _line('All settled', const Money.zero(), strong: true),
          const SizedBox(height: 2),
          Text(
            'The original payment stays as it is. No second transaction is created.',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }

  Widget _line(String label, Money amount, {bool strong = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: BambooFonts.ui(
              strong ? 14.5 : 13.5,
              weight: strong ? FontWeight.w700 : FontWeight.w500,
              color: strong ? BambooInk.ink900 : BambooInk.ink500,
            ),
          ),
        ),
        Text(
          amount.format(hidePaise: false),
          style: BambooFonts.money(strong ? 17 : 14, color: BambooInk.ink900),
        ),
      ],
    ),
  );

  // ───────────── Just for me ─────────────

  List<Widget> _privateBody() {
    final remaining = Money.fromPaise(
      widget.entry.amount.paise - _enteredPaise,
    );
    return [
      _sectionLabel('WHO OWED WHAT'),
      _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Note who each part of this payment was for. Only you see this; it does not change the card charged or what it earned.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            for (var i = 0; i < _amounts.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        key: ValueKey('private-amount-$i'),
                        controller: _amounts[i],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => setState(() {}),
                        style: BambooFonts.money(15, color: BambooInk.ink900),
                        decoration: const InputDecoration(
                          prefixText: '₹ ',
                          hintText: '0',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: TextField(
                        key: ValueKey('private-label-$i'),
                        controller: _labels[i],
                        maxLength: 2000,
                        style: BambooFonts.ui(14, color: BambooInk.ink900),
                        decoration: const InputDecoration(
                          hintText: 'Who / what for',
                          counterText: '',
                        ),
                      ),
                    ),
                    if (_amounts.length > 1)
                      IconButton(
                        tooltip: 'Remove this share',
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: BambooInk.ink500,
                        ),
                        onPressed: () => setState(() {
                          _original.remove(_amounts[i]);
                          _amounts.removeAt(i).dispose();
                          _labels.removeAt(i).dispose();
                        }),
                      ),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: _amounts.length >= 20
                  ? null
                  : () => setState(() {
                      _amounts.add(TextEditingController());
                      _labels.add(TextEditingController());
                    }),
              style: TextButton.styleFrom(
                foregroundColor: BambooInk.ink900,
                minimumSize: const Size(44, 44),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add a share'),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              _invalid
                  ? 'Enter a positive amount with at most two decimal places for each share.'
                  : _over
                  ? 'That is ${(-remaining).format()} more than the payment.'
                  : 'Unallocated: ${remaining.format()} — still yours.',
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w600,
                color: _over ? BambooInk.clayInk : BambooInk.ink500,
              ),
            ),
            if (_privateError != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.xs),
                child: Text(
                  _privateError!,
                  style: BambooFonts.ui(12.5, color: BambooInk.clayInk),
                ),
              ),
          ],
        ),
      ),
      if (widget.initialPrivate.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('private-clear'),
            onPressed: _busy ? null : () => _savePrivate(clear: true),
            child: const Text('Clear split'),
          ),
        ),
    ];
  }

  // ───────────── bottom bar ─────────────

  Widget _bottomBar(bool friends) {
    final editor = _editor;
    final bool enabled;
    final String label;
    final VoidCallback? onTap;
    if (friends) {
      final ok =
          editor != null &&
          !_busy &&
          !_loadingFriends &&
          (editor.sealed ||
              editor.canSubmit && _runtime?.proposalsEnabled == true);
      enabled = ok;
      label = editor?.contextName.isNotEmpty == true
          ? 'Split with ${editor!.contextName}'
          : 'Choose who to split with';
      onTap = ok ? _submitFriends : null;
    } else {
      enabled = _canSavePrivate;
      label = 'Save split';
      onTap = enabled ? _savePrivate : null;
    }
    // A split of an existing payment is held back by the server-side funding
    // check (it prevents counting the same spend twice). Say so plainly rather
    // than leaving a dead button.
    final fundingHeld =
        editor != null &&
        editor.evaluation.blockers.contains(
          SharedDraftBlocker.sourceFundingUnavailable,
        );
    final reason = friends && editor != null && !_loadingFriends
        ? (fundingHeld && editor.contextVerified
              ? 'Sending a split of an existing payment to friends is not switched on yet. Use Just for me to label shares now.'
              : editor.submitBlockReason)
        : null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          12 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reason != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  reason,
                  style: BambooFonts.ui(12.5, color: BambooInk.clayInk),
                ),
              ),
            FilledButton(
              key: const ValueKey('split-submit'),
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.onSlate,
                disabledBackgroundColor: BambooInk.paperMuted,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              onPressed: onTap,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: BambooInk.lime,
                      ),
                    )
                  : Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

class _Friendly implements Exception {
  final String message;
  const _Friendly(this.message);
}
