import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart'
    show Money, buildUpiPayUri;
import 'package:uuid/uuid.dart';
import '../../../app/design/app_theme.dart';
import '../../../data/upi_payment_service.dart';
import '../composer/shared_amount_input.dart';
import '../composer/shared_editor.dart';
import '../runtime/shared_runtime.dart';
import 'shared_components.dart';
import 'shared_context_guard.dart';

/// Reports a payment. The optional [upi] service opens the payer's own UPI app
/// with the amount filled in; a returned status is never proof of settlement.
/// Balances change only after the receiver confirms the recorded report.
class SharedSettleSheet extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final String contextId;
  final String? initialPayerId, initialReceiverId;
  final Money? initialAmount;
  final UpiPaymentService? upi;
  const SharedSettleSheet({
    super.key,
    required this.runtime,
    required this.contextId,
    this.initialPayerId,
    this.initialReceiverId,
    this.initialAmount,
    this.upi,
  });
  static Future<void> show(
    BuildContext context, {
    required SharedExpensesRuntime runtime,
    required String contextId,
    String? initialPayerId,
    String? initialReceiverId,
    Money? initialAmount,
    UpiPaymentService? upi,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BambooInk.paper,
    builder: (_) => SharedSettleSheet(
      runtime: runtime,
      contextId: contextId,
      initialPayerId: initialPayerId,
      initialReceiverId: initialReceiverId,
      initialAmount: initialAmount,
      upi: upi,
    ),
  );
  @override
  State<SharedSettleSheet> createState() => _SharedSettleSheetState();
}

class _SharedSettleSheetState extends State<SharedSettleSheet> {
  final _amount = TextEditingController(), _reference = TextEditingController();
  final _vpa = TextEditingController();
  String? _upiNotice;
  bool _upiOpened = false, _upiBusy = false, _upiConfirmAgain = false;
  List<UpiApp>? _upiChoices;
  final _settlementId = const Uuid().v4();
  List<SharedEditorMember> _members = const [];
  String? _own, _payer, _receiver, _error;
  String _method = 'upi';
  bool _loading = true, _saving = false, _sealed = false;
  DateTime _paidOn = DateTime.now();
  bool get _authorized =>
      widget.runtime.isCurrent() &&
      !widget.runtime.store.isContextRevoked(widget.contextId);
  String get _operationId =>
      widget.runtime.settlementReportId(widget.contextId, _settlementId);
  @override
  void initState() {
    super.initState();
    if (widget.initialAmount != null) {
      _amount.text = sharedRupeesText(widget.initialAmount!);
    }
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _vpa.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final roster = await widget.runtime.contextRoster(widget.contextId);
      if (!mounted || !_authorized) return;
      final members = roster.members.where((m) => m.canSettle).toList();
      if (!members.any((m) => m.id == roster.ownMemberId)) {
        throw const SharedRuntimeUnavailable();
      }
      final own = roster.ownMemberId;
      final payer = widget.initialPayerId ?? own;
      final receiver =
          widget.initialReceiverId ??
          (payer != own
              ? own
              : members.where((m) => m.id != own).firstOrNull?.id);
      if (!members.any((m) => m.id == payer) ||
          receiver == payer ||
          receiver != null && !members.any((m) => m.id == receiver) ||
          payer != own && receiver != own) {
        throw const SharedRuntimeUnavailable();
      }
      setState(() {
        _members = members;
        _own = own;
        _payer = payer;
        _receiver = receiver;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              'Current payment participants could not be loaded. Try again.';
        });
      }
    }
  }

  static final _vpaPattern = RegExp(
    r'^[A-Za-z0-9._-]{2,64}@[A-Za-z][A-Za-z0-9]{1,31}$',
  );
  static final _refPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$');

  /// Hands the payment to the payer's own UPI app. Nothing is recorded here:
  /// the user must come back and tap Record payment, and the receiver must
  /// still confirm before any balance changes.
  Future<void> _openUpi({bool confirmed = false}) async {
    final service = widget.upi;
    if (service == null || _upiBusy || _sealed || _saving) return;
    final amount = SharedDecimalInput.parse(
      _amount.text,
      allowZero: false,
    ).units;
    final vpa = _vpa.text.trim();
    if (amount == null) {
      setState(() => _upiNotice = 'Enter the amount to pay first.');
      return;
    }
    if (!_vpaPattern.hasMatch(vpa)) {
      setState(() => _upiNotice = 'Enter a valid UPI ID, like name@bank.');
      return;
    }
    if (_upiOpened && !confirmed) {
      // Inline confirmation instead of a pop-up over this sheet.
      setState(() => _upiConfirmAgain = true);
      return;
    }
    setState(() {
      _upiBusy = true;
      _upiConfirmAgain = false;
      _upiChoices = null;
      _upiNotice = null;
    });
    try {
      final apps = await service.installedApps();
      if (!mounted) return;
      if (apps.isEmpty) {
        setState(
          () => _upiNotice =
              'No UPI app was found on this device. Pay in your UPI app, then record the payment here.',
        );
        return;
      }
      if (apps.length > 1) {
        setState(() => _upiChoices = apps);
        return;
      }
      await _launchUpi(apps.first, amount, vpa);
    } catch (_) {
      if (mounted) {
        setState(
          () => _upiNotice =
              'Could not open the UPI app. Check your payment app before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => _upiBusy = false);
    }
  }

  Future<void> _launchUpi(UpiApp app, int amount, String vpa) async {
    final service = widget.upi;
    if (service == null) return;
    setState(() {
      _upiChoices = null;
      _upiBusy = true;
      _upiOpened = true;
    });
    try {
      final receiver = _members.where((m) => m.id == _receiver).firstOrNull;
      final uri = buildUpiPayUri(
        pa: vpa,
        pn: receiver?.name,
        am: Money.fromPaise(amount),
        tn: 'PandaPay split settle-up',
      );
      final result = await service.pay(
        upiUri: uri,
        packageName: app.packageName,
      );
      if (!mounted) return;
      final ref = result.approvalRefNo;
      setState(() {
        if (ref != null &&
            _reference.text.isEmpty &&
            _refPattern.hasMatch(ref)) {
          _reference.text = ref;
        }
        _upiNotice = switch (result.status) {
          UpiPaymentStatus.failure =>
            'The UPI app reported the payment failed. Check your payment app before trying again.',
          UpiPaymentStatus.cancelled =>
            'Payment was cancelled. Nothing was recorded.',
          UpiPaymentStatus.noAppsAvailable =>
            'No UPI app was found on this device.',
          _ =>
            'Payment status is not confirmed. Check your payment app, then tap Record payment if it went through. The receiver still confirms.',
        };
        if (result.status == UpiPaymentStatus.cancelled ||
            result.status == UpiPaymentStatus.noAppsAvailable) {
          _upiOpened = false;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _upiNotice =
              'Could not open the UPI app. Check your payment app before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => _upiBusy = false);
    }
  }

  Future<void> _save() async {
    if (_saving || !_authorized || !widget.runtime.settlementsEnabled) return;
    if (_sealed) {
      setState(() => _saving = true);
      try {
        await widget.runtime.flushEditor();
      } catch (_) {
        if (mounted) _error = 'Could not refresh. Your saved report is kept.';
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    final amount = SharedDecimalInput.parse(
      _amount.text,
      allowZero: false,
    ).units;
    final reference = _reference.text.trim();
    if (amount == null) {
      setState(
        () => _error =
            'Enter a positive amount with at most two decimal places, up to ₹1,00,00,000.',
      );
      return;
    }
    if (reference.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$').hasMatch(reference)) {
      setState(
        () => _error =
            'Use a payment reference of up to 128 letters, numbers, dots, colons, underscores or hyphens.',
      );
      return;
    }
    if (_payer == null ||
        _receiver == null ||
        _payer == _receiver ||
        _payer != _own && _receiver != _own) {
      setState(() => _error = 'Select yourself and another active member.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.runtime.reportSettlement(
        contextId: widget.contextId,
        settlementId: _settlementId,
        payerMemberId: _payer!,
        receiverMemberId: _receiver!,
        amountMinor: '$amount',
        method: _method,
        paidOn: DateFormat('yyyy-MM-dd').format(_paidOn),
        reference: reference.isEmpty ? null : reference,
      );
    } catch (_) {
      if (mounted) {
        _error =
            'Could not save the payment yet. It is kept on this phone. Try again.';
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _sealed =
              _authorized &&
              widget.runtime.store.operation(_operationId) != null;
        });
      }
    }
  }

  Widget _person(
    String label,
    String? selected,
    ValueChanged<String?> choose,
  ) => DropdownButtonFormField<String>(
    key: ValueKey('$label:$selected'),
    initialValue: selected,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    style: BambooFonts.ui(14),
    items: [
      for (final member in _members)
        DropdownMenuItem(
          value: member.id,
          child: Text(
            member.id == _own ? 'You' : member.name,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: _sealed || _saving ? null : choose,
  );
  @override
  Widget build(BuildContext context) => SharedContextGuard(
    runtime: widget.runtime,
    contextId: widget.contextId,
    builder: (context) {
      if (!_authorized) {
        return const SafeArea(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('This shared expense is no longer available.'),
          ),
        );
      }
      final enabled = widget.runtime.settlementsEnabled;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Settle up', style: BambooFonts.heading(20)),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SharedNotice(
                  'Record a payment already made. This does not send money. Balances change only after receiver confirmation.',
                ),
                if (!enabled)
                  const SharedNotice(
                    'Settlement recording is not enabled for this account yet.',
                  ),
                if (_loading)
                  const LinearProgressIndicator(color: BambooInk.slate),
                if (_error != null)
                  Text(
                    _error!,
                    style: BambooFonts.ui(13, color: BambooInk.clayInk),
                  ),
                if (!_loading && _members.isEmpty)
                  TextButton(onPressed: _load, child: const Text('Try again')),
                if (_members.length < 2 && !_loading)
                  const SharedNotice(
                    'Two active, verified members are needed. Invited people cannot confirm payments yet.',
                  ),
                if (_members.length >= 2) ...[
                  _person(
                    'Paid by',
                    _payer,
                    (id) => setState(() {
                      _payer = id;
                      if (id != _own) {
                        _receiver = _own;
                      } else if (_receiver == _own) {
                        _receiver = _members
                            .where((m) => m.id != _own)
                            .first
                            .id;
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  _person(
                    'Paid to',
                    _receiver,
                    (id) => setState(() {
                      _receiver = id;
                      if (id != _own) {
                        _payer = _own;
                      } else if (_payer == _own) {
                        _payer = _members.where((m) => m.id != _own).first.id;
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('settlement-amount'),
                    controller: _amount,
                    readOnly: _sealed || _saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: BambooFonts.money(18),
                    decoration: const InputDecoration(labelText: 'Amount (₹)'),
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final method in const [
                        ('upi', 'UPI'),
                        ('cash', 'Cash'),
                        ('bank', 'Bank'),
                      ])
                        ChoiceChip(
                          label: Text(method.$2, style: BambooFonts.ui(13)),
                          selected: _method == method.$1,
                          onSelected: _sealed || _saving
                              ? null
                              : (_) => setState(() => _method = method.$1),
                        ),
                    ],
                  ),
                  if (_method == 'upi' &&
                      enabled &&
                      widget.upi != null &&
                      _payer == _own) ...[
                    TextField(
                      key: const ValueKey('settlement-vpa'),
                      controller: _vpa,
                      readOnly: _sealed || _saving,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      style: BambooFonts.ui(14),
                      decoration: const InputDecoration(
                        labelText: "Receiver's UPI ID",
                        hintText: 'name@bank',
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _upiBusy || _sealed || _saving
                          ? null
                          : _openUpi,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: Text(
                        _upiBusy
                            ? 'Opening…'
                            : _upiOpened
                            ? 'Open UPI app again'
                            : 'Pay with UPI app',
                        style: BambooFonts.ui(13),
                      ),
                    ),
                    if (_upiConfirmAgain) ...[
                      const SharedNotice(
                        'Check your payment app first. If the payment already went through, record it instead of paying twice.',
                        icon: Icons.warning_amber_rounded,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () =>
                                setState(() => _upiConfirmAgain = false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => _openUpi(confirmed: true),
                            child: const Text('Open again'),
                          ),
                        ],
                      ),
                    ],
                    if (_upiChoices != null) ...[
                      Text(
                        'Pay with',
                        style: BambooFonts.ui(13, weight: FontWeight.w600),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final choice in _upiChoices!)
                            ActionChip(
                              label: Text(
                                choice.name,
                                style: BambooFonts.ui(13),
                              ),
                              onPressed: () {
                                final units = SharedDecimalInput.parse(
                                  _amount.text,
                                  allowZero: false,
                                ).units;
                                if (units != null) {
                                  _launchUpi(choice, units, _vpa.text.trim());
                                }
                              },
                            ),
                        ],
                      ),
                    ],
                    if (_upiNotice != null) SharedNotice(_upiNotice!),
                  ] else if (_method == 'upi')
                    const SharedNotice(
                      'Pay in your UPI app, then record the payment here.',
                    ),
                  TextField(
                    controller: _reference,
                    readOnly: _sealed || _saving,
                    maxLength: 128,
                    style: BambooFonts.ui(14),
                    decoration: const InputDecoration(
                      labelText: 'Payment reference (optional)',
                    ),
                  ),
                  TextButton(
                    onPressed: _sealed || _saving
                        ? null
                        : () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: _paidOn,
                              firstDate: DateTime(2000),
                              lastDate: DateTime.now(),
                            );
                            if (mounted && date != null) {
                              setState(() => _paidOn = date);
                            }
                          },
                    child: Text(
                      'Paid on ${DateFormat.yMMMd().format(_paidOn)}',
                      style: BambooFonts.ui(13),
                    ),
                  ),
                  if (_sealed)
                    SharedNotice(widget.runtime.operationStatus(_operationId)),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: sharedPrimaryButtonStyle(),
                    onPressed: !enabled || _saving ? null : _save,
                    child: Text(
                      _saving
                          ? 'Saving…'
                          : _sealed
                          ? 'Check status'
                          : 'Record payment',
                      style: BambooFonts.ui(14, weight: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
