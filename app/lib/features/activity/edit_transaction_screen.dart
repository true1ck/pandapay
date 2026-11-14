import 'dart:async';
import '../../app/design/saved_offline.dart';
import '../../app/design/refresh_views.dart';
import '../sms_v2/similar/similar_changes.dart';
import '../sync/sync_engine.dart';
import '../sms_v2/similar/similar_offer_sheet.dart';
import '../sms_v2/ui/review_controller.dart';
import '../sms_v2/ui/transaction_actions.dart';
import '../sms_v2/providers/data_providers.dart';
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/category_picker.dart';
import '../../app/transaction_tag_picker.dart';
import '../../app/providers.dart';
import '../../app/required_field.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart'
    show SpendCategory, categoryIdForServer, userCategoryIdForServer;
import '../../data/merchant_category_rules_repository.dart';
import '../../data/user_cards_repository.dart';
import '../../data/self_transfer.dart';
import '../../data/local/financial_store.dart' show canonicalBankSender;
import '../../data/local/self_transfer_rules.dart';
import '../../data/local/sms_intake_repository.dart';
import '../../data/connectivity/reachability.dart';
import '../payments/payment_method_catalogue.dart';
import '../payments/payment_method_command.dart';
import '../payments/payment_method_picker.dart';
import '../payments/payment_method_rules.dart';
import 'category_bulk_review_sheet.dart';
import '../sms_v2/similar/similar_runner.dart';
import '../sms_v2/storage/event_store.dart';
import 'merchant_future_rule_sheet.dart';

/// D3 Edit Transaction (ui-spec Group D). All fields editable, explicit
/// save/cancel; recomputes caps/milestones on save — that recompute is
/// entirely server-side (Task C-0c's PATCH /transactions/:id, verified
/// live against a real database during that task), so this screen's only
/// job is collecting the new values correctly.
class EditTransactionScreen extends ConsumerStatefulWidget {
  final String transactionId;
  final TransactionEntry? initialEntry;

  const EditTransactionScreen({
    super.key,
    required this.transactionId,
    this.initialEntry,
  });

  @override
  ConsumerState<EditTransactionScreen> createState() =>
      _EditTransactionScreenState();
}

class _EditTransactionScreenState extends ConsumerState<EditTransactionScreen> {
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  String? _userCardId;
  String? _categoryId;
  Set<String> _tagIds = {};
  bool _tagsEdited = false;
  TransactionEntry? _originalEntry;
  DateTime? _occurredAt;
  TxnInstrument? _instrument;

  /// How it was paid (cheque, NEFT...). Starts as what is saved; only sent
  /// when the person changes it, so an edit that never touches it is unchanged.
  String? _paymentMethod;
  TxnEntryKind _entryKind = TxnEntryKind.spend;
  SelfTransferDestination? _selfTransfer;
  SelfTransferDestination? _clearedSelfTransfer;
  bool _rememberSelfTransferChoice = false;
  bool _applyHistoricalSelfTransferChoice = false;

  /// A transfer is either between the person's own accounts or a credit card
  /// bill. Both show as "Transfer"; the ledger's event type tells them apart.
  bool _cardBill = false;
  bool _originalCardBill = false;
  TxnRail _rail = TxnRail.unknown;
  bool _initialized = false;
  bool _saving = false;
  bool _submitted = false;
  // After a saved SMS edit: the others that look the same, offered once the edit is committed.
  SimilarChanges? _similar;
  List<SimilarOffer> _similarOffers = const [];
  String _similarShop = '';
  String _instrumentLabel = 'this card';
  String? _error;

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  void _initFrom(TransactionEntry entry) {
    if (_initialized) return;
    _initialized = true;
    _originalEntry = entry;
    _tagIds =
        (ref
                    .read(transactionTagsProvider)
                    ?.tagsForTransaction(entry.id, fallback: entry.tags) ??
                entry.tags)
            .map((t) => t.id)
            .toSet();
    _amountController.text = entry.amount.rupees.toStringAsFixed(2);
    _merchantController.text = entry.merchantName ?? '';
    _userCardId = entry.userCardId;
    _categoryId = entry.categoryId;
    _occurredAt = entry.occurredAt;
    _entryKind = entry.entryKind;
    final destination = entry.selfTransferRule?['destination'];
    if (entry.entryKind == TxnEntryKind.transfer &&
        destination is Map &&
        destination['bank'] is String &&
        destination['accountLast4'] is String) {
      _selfTransfer = SelfTransferDestination(
        bank: destination['bank'] as String,
        accountLast4: destination['accountLast4'] as String,
      );
    }
    _instrument = entry.instrumentKnown ? entry.instrument : null;
    _paymentMethod = entry.paymentMethod;
    _rail = entry.rail;
    if (entry.pipelineVersion == 2 && entry.eventId != null) {
      try {
        final cache = ref.read(responseCacheProvider).valueOrNull;
        if (cache != null) {
          final stored = EventStore(
            cache.financialStore.database.db,
            namespace: ref.read(cacheNamespaceProvider),
          ).get(entry.eventId!)?.type;
          _cardBill = _originalCardBill = stored == v2.EventType.cardBillPayment;
        }
      } catch (_) {
        // Without it the choice just starts on "between my accounts".
      }
    }
    // The bottom action is built before the body's AsyncValue builder runs.
    // Request one safe rebuild after the first frame so Save is enabled for
    // the loaded row instead of remaining disabled until another provider
    // happens to change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// The method to send: only when the person set one that differs from what
  /// is saved. An SMS-ledger row is edited through the ledger, which has no
  /// method field, so nothing is sent for it.
  String? get _methodToSend {
    final original = _originalEntry;
    if (original == null || original.pipelineVersion == 2) return null;
    final method = _paymentMethod;
    if (method == null || method == original.paymentMethod) return null;
    return paymentMethodByWire(method) == null ? null : method;
  }

  /// The person removed a saved method (for example by switching to cash).
  bool get _clearMethod {
    final original = _originalEntry;
    // A saved plain `upi` is the SMS reader's evidence, not a choice the
    // person made, so changing the instrument never counts as clearing it
    // (the server keeps it, exactly as before this feature existed).
    return original != null &&
        original.pipelineVersion != 2 &&
        original.paymentMethod != null &&
        original.paymentMethod != 'upi' &&
        _paymentMethod == null;
  }

  bool get _methodChanged => _methodToSend != null || _clearMethod;

  /// The phone is known to be offline, or the server cannot be reached.
  bool _offlineNow() =>
      ref.read(isOnlineProvider).valueOrNull == false ||
      ref.read(serverReachabilityProvider).serverReachable == false;

  Future<void> _save() async {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || !amount.isFinite || amount <= 0) {
      setState(() => _submitted = true);
      setState(() => _error = 'Enter a valid amount greater than zero.');
      return;
    }
    // A self-transfer decision runs several server checks and rules (it can
    // also re-label older transactions), so it is not safe to replay later:
    // it needs the connection, and says so in plain words.
    if ((_selfTransfer != null || _clearedSelfTransfer != null) &&
        _offlineNow()) {
      setState(
        () => _error =
            'You are offline. Confirming or undoing a self-transfer needs a connection. Try again when you are back online.',
      );
      return;
    }
    // A payment method change is a queued command offline. A row that exists
    // only as a queued quick-add has no server id to send it to yet.
    if (_methodChanged &&
        _offlineNow() &&
        widget.transactionId.startsWith('local')) {
      setState(
        () => _error =
            'You are offline. This entry has not reached your account yet, so how it was paid can be changed once it has.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final original = _originalEntry;
    final financialChanged =
        _selfTransfer != null ||
        _clearedSelfTransfer != null ||
        original == null ||
        original.amount != Money.fromRupees(amount) ||
        original.categoryId != _categoryId ||
        original.userCardId != _userCardId ||
        original.occurredAt != _occurredAt ||
        (original.merchantName ?? '') != _merchantController.text.trim() ||
        (original.instrumentKnown
            ? original.instrument != _instrument
            : _instrument != null) ||
        original.entryKind != _entryKind ||
        _cardBill != _originalCardBill ||
        original.rail != _rail ||
        _methodChanged;
    try {
      final categoryChanged =
          original != null && original.categoryId != _categoryId;
      if (_tagsEdited) {
        final tags = ref.read(transactionTagsProvider);
        if (tags == null)
          throw StateError('Tags are still loading. Please retry.');
        await tags.replace(
          widget.transactionId,
          _tagIds,
          fallback: original?.tags ?? [],
        );
      }
      if (financialChanged) {
        await _submitEdit(amount);
        await _rememberSelfTransfer();
      }
      // Hold the spinner until every list and total shows the edit.
      await refreshViews(ref);
      if (!mounted) return; // left the screen while waiting; the edit is saved
      _confirmSaved(original);

      // The original row is saved before the optional online offers (bulk
      // review of related transactions, future rule). They never hold the
      // screen: it closes first and the offers run from the screen below with
      // a short time limit, and are skipped when the phone is offline or the
      // server cannot be reached.
      final runOffers =
          categoryChanged && original.pipelineVersion != 2 && !_offlineNow();
      final offerContext = Navigator.of(context, rootNavigator: true).context;
      final offerContainer = ProviderScope.containerOf(context, listen: false);
      final offerCategoryId = _categoryId;
      final offerCategoryLabel = _categoryLabel(_categoryId);
      try {
        await _offerSimilar();
      } catch (_) {
        // The edit is saved; a failed offer to change the others never undoes
        // or reports it as failed.
      }
      if (mounted) context.pop(true);
      if (runOffers) {
        unawaited(
          _runCategoryOffers(
            ctx: offerContext,
            container: offerContainer,
            txId: widget.transactionId,
            categoryId: offerCategoryId,
            categoryLabel: offerCategoryLabel,
          ),
        );
      }
    } catch (e) {
      // Plan Phase 4. Before this, an edit made offline simply failed and the
      // user's typing was gone the moment they left the screen — only B6
      // quick-add had an offline path, and this is an edit to a row that
      // already exists, which that queue can't represent.
      //
      // Queued only when the device is actually offline. A 4xx means the
      // server rejected the content and queueing it would just retry the same
      // rejection five times before dropping it, while telling the user it
      // was saved.
      final offline = ref.read(isOnlineProvider).valueOrNull == false;
      if (offline &&
          original?.pipelineVersion != 2 &&
          _selfTransfer == null &&
          _clearedSelfTransfer == null &&
          !_methodChanged) {
        final queue = await ref.read(syncQueueProvider.future);
        queue.enqueueUpdate(
          entity: 'transactions',
          entityId: widget.transactionId,
          fields: {
            'amount_inr': amount,
            'occurred_at': _occurredAt?.toIso8601String(),
            'category_id': categoryIdForServer(_categoryId),
            'user_category_id': userCategoryIdForServer(_categoryId),
            'merchant_name': _merchantController.text.trim().isEmpty
                ? null
                : _merchantController.text.trim(),
            'user_card_id': _userCardId,
            if (_instrument != null) 'instrument': _instrument!.wireValue,
            'entry_kind': _entryKind.wireValue,
            'rail': _railWireValue(_rail),
          },
        );
        ref.invalidate(pendingSyncCountProvider);
        await refreshViews(ref);
        if (mounted) {
          showSavedOfflineSnack(context);
          context.pop(true);
        }
        return;
      }
      if (isAuthenticationFailure(e)) {
        try {
          final refreshed = await ref
              .read(sessionRefreshCoordinatorProvider)
              .refresh();
          if (refreshed != null && refreshed.isNotEmpty) {
            await _submitEdit(amount);
            await _rememberSelfTransfer();
            await refreshViews(ref);
            if (mounted) context.pop(true);
            return;
          }
        } catch (_) {
          // Fall through to the explicit session-recovery message below.
        }
        if (mounted) {
          setState(
            () => _error =
                'Your session has expired. Reconnect and sign in again, then try saving this edit.',
          );
        }
        return;
      }
      // Keep the real cause in the log: the on-screen copy is deliberately
      // generic for anything that is not a validation message.
      debugPrint('Edit transaction save failed: $e');
      final locked = e.toString().contains('database is locked');
      setState(
        () => _error = locked
            ? 'The phone is busy reading your messages. Wait a moment and save again.'
            : userFacingErrorMessage(e),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Tells the person the edit is in, at once. An SMS transaction is saved on
  /// this phone first and reaches the account in the background, so the
  /// message says that instead of implying the server already has it.
  void _confirmSaved(TransactionEntry? original) {
    if (!mounted) return;
    final offline = ref.read(isOnlineProvider).valueOrNull == false;
    final onPhone = original?.pipelineVersion == 2;
    final text = onPhone
        ? (offline
              ? savedOfflineCopy
              : 'Saved on this phone. Syncing in the background.')
        : (offline
              ? savedOfflineCopy
              : 'Saved. Syncing in the background.');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _submitEdit(double amount) async {
    final original = _originalEntry;
    if (original?.pipelineVersion == 2) {
      final namespace = ref.read(cacheNamespaceProvider);
      final controller = await smsReviewController(ref);
      final instruments = await ref.read(instrumentsProvider.future);
      if (!mounted || namespace != ref.read(cacheNamespaceProvider))
        throw StateError('Account changed');
      String? instrumentId;
      if (_userCardId != original!.userCardId ||
          _instrument != original.instrument) {
        final matches = instruments
            .where(
              (i) =>
                  i.status == v2.InstrumentStatus.confirmed &&
                  (_userCardId != null
                      ? i.userCardId == _userCardId
                      : switch (_instrument) {
                          TxnInstrument.upiBank =>
                            i.kind == v2.InstrumentKind.bankAccount,
                          TxnInstrument.wallet =>
                            i.kind == v2.InstrumentKind.wallet,
                          TxnInstrument.creditCard =>
                            i.kind == v2.InstrumentKind.creditCard,
                          TxnInstrument.debitCard =>
                            i.kind == v2.InstrumentKind.debitCard,
                          _ => false,
                        }),
            )
            .toList();
        if (matches.length != 1)
          throw ArgumentError(
            'Choose a confirmed account or card in Needs review',
          );
        instrumentId = matches.single.instrumentId;
      }
      String? category;
      if (original.categoryId != _categoryId) {
        category = ref
            .read(categoriesProvider)
            .valueOrNull
            ?.where((c) => c.id == _categoryId)
            .firstOrNull
            ?.slug;
        if (category == null && _categoryId != null)
          throw ArgumentError(
            'Choose a supported SMS category in Needs review',
          );
        category ??= 'other';
      }
      final kind = switch (_entryKind) {
        TxnEntryKind.spend => v2.EventType.purchase,
        TxnEntryKind.income => v2.EventType.income,
        TxnEntryKind.investment => v2.EventType.investment,
        TxnEntryKind.investmentReturn => v2.EventType.investmentWithdrawal,
        TxnEntryKind.refund => v2.EventType.refund,
        TxnEntryKind.transfer =>
          _cardBill ? v2.EventType.cardBillPayment : v2.EventType.ownTransfer,
        _ => v2.EventType.unknown,
      };
      final rail = _rail == original.rail
          ? null
          : _rail == TxnRail.upiQr
          ? v2.Rail.upi
          : v2.Rail.unknown;
      // What the transaction looked like before this edit changes it.
      final similar = SimilarChanges.forController(controller);
      final before = similar.snapshot(original);
      final typeChanged =
          _entryKind != original.entryKind ||
          (_entryKind == TxnEntryKind.transfer && _cardBill != _originalCardBill);
      SmsTransactionActions(controller: controller).edit(
        original,
        amountMinor: Money.fromRupees(amount).paise,
        merchant: _merchantController.text.trim(),
        occurredAt: _occurredAt ?? original.occurredAt,
        category: category,
        instrumentId: instrumentId,
        eventType: kind,
        rail: rail,
      );
      // The edit is committed. Looking for others that look the same is a
      // separate, optional step and never puts the edit at risk.
      try {
        if (before != null) {
          final name = _merchantController.text.trim();
          _similar = similar;
          _similarShop = before.printedName ?? name;
          _instrumentLabel =
              instruments
                  .where((i) => i.instrumentId == instrumentId)
                  .firstOrNull
                  ?.displayName ??
              'this card';
          _similarOffers = similar.offers(
            before,
            shopName: name.isNotEmpty && name != (original.merchantName ?? '')
                ? name
                : null,
            categorySlug: category,
            instrumentId: instrumentId,
            eventType: typeChanged ? kind : null,
          );
        }
      } catch (_) {
        _similarOffers = const [];
      }
      return;
    }

    // Local first, always: the edit is saved on the phone and sent in the
    // background, so the save never waits on the network and the lists already
    // show it (the entity reader overlays queued edits). Only a self-transfer
    // decision needs the server's own checks, and a row that exists only as a
    // queued quick-add has no server id yet, so those keep the direct call
    // below.
    if (_selfTransfer == null &&
        _clearedSelfTransfer == null &&
        !widget.transactionId.startsWith('local')) {
      final fields = _changedServerFields(original, amount);
      // WP-C5: `instrument` / `entry_kind` are typed columns the legacy sync
      // writer refuses, so they travel as their own command to the domain PATCH
      // route (never lost, never parked by the sync push) and are written to
      // the stored row now so the lists show them at once.
      final typed = <String, Object?>{
        for (final key in const [
          'instrument',
          'entry_kind',
          'amount_inr',
          'occurred_at',
          'category_id',
          'user_category_id',
          'user_card_id',
          'rail',
        ])
          if (fields.containsKey(key)) key: fields.remove(key),
      };
      if (fields.isNotEmpty) {
        final queue = await ref.read(syncQueueProvider.future);
        queue.enqueueUpdate(
          entity: 'transactions',
          entityId: widget.transactionId,
          fields: fields,
        );
        ref.invalidate(pendingSyncCountProvider);
      }
      final store = (await ref.read(responseCacheProvider.future)).financialStore;
      final namespace = ref.read(cacheNamespaceProvider);
      if (typed.isNotEmpty) {
        await queueCommand(
          ref,
          kind: PaymentMethodCommand.setTyped,
          target: widget.transactionId,
          payload: {
            'id': widget.transactionId,
            ...typed.map((k, v) => MapEntry(_typedWireKey(k), v)),
          },
        );
        store.patchTransaction(namespace, widget.transactionId, typed);
      }
      if (_methodChanged) {
        final method = _methodToSend;
        await queueCommand(
          ref,
          kind: PaymentMethodCommand.set,
          target: widget.transactionId,
          payload: {'id': widget.transactionId, 'paymentMethod': method},
        );
        store.patchTransaction(namespace, widget.transactionId, {
          'payment_method': method,
        });
      }
      if (fields.isNotEmpty) unawaited(ref.read(syncEngineProvider).sync());
      return;
    }

    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      throw const AuthenticationUnavailableException();
    }
    await repo.editTransaction(
      widget.transactionId,
      amountInr: amount,
      occurredAt: _occurredAt,
      categoryId: _categoryId,
      clearCategory: _originalEntry?.categoryId != null && _categoryId == null,
      merchantName: _merchantController.text.trim().isEmpty
          ? null
          : _merchantController.text.trim(),
      userCardId: _userCardId,
      instrument: _selfTransfer != null ? TxnInstrument.upiBank : _instrument,
      entryKind: _entryKind,
      paymentMethod: _methodToSend,
      clearPaymentMethod: _clearMethod,
      selfTransfer: _selfTransfer == null && _clearedSelfTransfer == null
          ? null
          : {
              ...(_selfTransfer ?? _clearedSelfTransfer!).toJson(),
              if (_selfTransfer != null)
                'remember': _rememberSelfTransferChoice,
              if (_selfTransfer != null && _applyHistoricalSelfTransferChoice)
                'applyHistorical': true,
              if (_selfTransfer == null) 'action': 'disable',
            },
      rail: _rail,
    );
  }

  /// Only the fields the person actually changed, in the names the sync API
  /// accepts. Sending an untouched field would give it a fresh clock and could
  /// overwrite a newer edit made on another device.
  Map<String, Object?> _changedServerFields(
    TransactionEntry? original,
    double amount,
  ) {
    final merchant = _merchantController.text.trim();
    return {
      if (original == null || original.amount != Money.fromRupees(amount))
        'amount_inr': amount,
      if (original == null || original.occurredAt != _occurredAt)
        'occurred_at': _occurredAt?.toIso8601String(),
      if (original == null || original.categoryId != _categoryId) ...{
        'category_id': categoryIdForServer(_categoryId),
        'user_category_id': userCategoryIdForServer(_categoryId),
      },
      if (original == null || (original.merchantName ?? '') != merchant)
        'merchant_name': merchant.isEmpty ? null : merchant,
      if (original == null || original.userCardId != _userCardId)
        'user_card_id': _userCardId,
      if (_instrument != null &&
          (original == null || original.instrument != _instrument))
        'instrument': _instrument!.wireValue,
      if (original == null || original.entryKind != _entryKind)
        'entry_kind': _entryKind.wireValue,
      if (original == null || original.rail != _rail)
        'rail': _railWireValue(_rail),
    };
  }

  /// Asks about the other transactions that look the same, one change at a
  /// time, after the edit itself is saved.
  Future<void> _offerSimilar() async {
    final similar = _similar;
    final offers = _similarOffers;
    _similar = null;
    _similarOffers = const [];
    if (similar == null || offers.isEmpty) return;
    for (final offer in offers) {
      if (!mounted) return;
      final target = switch (offer.field) {
        SimilarField.shopName => offer.change['name'] as String,
        SimilarField.category => _categoryLabel(_categoryId),
        SimilarField.paymentMethod => _instrumentLabel,
        SimilarField.type => switch (_entryKind) {
          TxnEntryKind.income => 'income',
          TxnEntryKind.investment => 'an investment',
          TxnEntryKind.investmentReturn => 'an investment return',
          TxnEntryKind.refund => 'a refund',
          TxnEntryKind.transfer => _cardBill
              ? 'a credit card bill payment'
              : 'a transfer between your accounts',
          _ => 'a spend',
        },
      };
      final ids = await showSimilarOfferSheet(
        context: context,
        offer: offer,
        changes: similar,
        shop: _similarShop,
        target: target,
      );
      if (ids == null || ids.isEmpty || !mounted) continue;
      // The screen may be gone before this finishes, so the run holds on to
      // the messenger and the provider container, not to this State.
      final messenger = ScaffoldMessenger.of(context);
      final container = ProviderScope.containerOf(context);
      void refresh() {
        container.invalidate(transactionsProvider);
        container.invalidate(utilizationTransactionsProvider);
        container.invalidate(homeSummaryProvider);
        container.invalidate(spendReportProvider);
        container.invalidate(categorySpendProvider);
      }
      // One run at a time: a name and a category offer for the same
      // transactions must not interleave their writes.
      _similarRuns = _similarRuns.then(
        (_) => applySimilarInBackground(
          messenger: messenger,
          changes: similar,
          offer: offer,
          eventIds: ids,
          onChanged: refresh,
        ),
      );
    }
  }

  Future<void> _similarRuns = Future<void>.value();

  Future<void> _rememberSelfTransfer() async {
    // The server has already committed. A local cache failure must not turn
    // a successful financial correction into a failed save.
    try {
      final original = _originalEntry;
      if (original?.sourceKey == null) return;
      final cache = await ref.read(responseCacheProvider.future);
      final namespace = ref.read(cacheNamespaceProvider);
      final captured = SmsIntakeRepository(
        cache.financialStore.database,
      ).capturedById(namespace, original!.sourceKey!);
      if (captured == null) return;
      final rules = SelfTransferRules(
        cache.financialStore.database,
        namespace: namespace,
      );
      if (_selfTransfer != null && _rememberSelfTransferChoice) {
        rules.remember(
          sender: captured.message.sender,
          body: captured.message.body,
          destination: _selfTransfer!,
        );
      } else if (_selfTransfer == null && _entryKind != TxnEntryKind.transfer) {
        rules.forget(
          sender: captured.message.sender,
          body: captured.message.body,
        );
      }
    } catch (_) {
      // Future server imports still use the committed personal confirmation.
    }
  }

  Widget _selfTransferPicker(TransactionEntry entry) {
    if (entry.instrument != TxnInstrument.upiBank ||
        entry.accountLast4 == null ||
        (entry.source != 'sms' && entry.source != 'sms_bulk') ||
        (_entryKind != TxnEntryKind.spend &&
            _entryKind != TxnEntryKind.transfer)) {
      return const SizedBox.shrink();
    }
    final accounts =
        ref.watch(bankAccountSummariesProvider).valueOrNull ?? const [];
    final choices = <String, SelfTransferDestination>{
      for (final account in accounts)
        if (account.issuerSlug != null &&
            account.accountLast4 != entry.accountLast4)
          '${canonicalBankSender(account.issuerSlug)}:${account.accountLast4}':
              SelfTransferDestination(
                accountLast4: account.accountLast4,
                bank: canonicalBankSender(account.issuerSlug),
              ),
    };
    if (choices.isEmpty) return const SizedBox.shrink();
    final selected = _selfTransfer == null
        ? null
        : '${_selfTransfer!.bank}:${_selfTransfer!.accountLast4}';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: DropdownButtonFormField<String>(
        key: ValueKey('self-transfer-account:$selected'),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Mark as self-transfer',
          helperText:
              'Excluded from spending. Choose the receiving account; remembering is optional.',
          helperMaxLines: 2,
        ),
        hint: const Text('Choose receiving account'),
        items: [
          for (final choice in choices.entries)
            DropdownMenuItem(
              value: choice.key,
              child: Text(
                '${selfTransferBankLabel(choice.value.bank)} •${choice.value.accountLast4}',
              ),
            ),
        ],
        onChanged: _saving
            ? null
            : (value) {
                if (value == null) return;
                setState(() {
                  _selfTransfer = choices[value];
                  _entryKind = TxnEntryKind.transfer;
                  _merchantController.text = _selfTransfer!.label;
                });
              },
      ),
    );
  }

  String _categoryLabel(String? id) {
    if (id == null) return 'this category';
    final categories = ref.read(categoriesProvider).valueOrNull ?? const [];
    for (final category in categories) {
      if (category.id == id) return category.name;
    }
    return 'this category';
  }

  /// Runs both offers after the edit screen has closed. [ctx] is the root
  /// navigator's context (still mounted) and [container] the app's provider
  /// container, because this State is gone by now.
  Future<void> _runCategoryOffers({
    required BuildContext ctx,
    required ProviderContainer container,
    required String txId,
    required String? categoryId,
    required String categoryLabel,
  }) async {
    try {
      final result = await _offerCategoryBulkReview(
        ctx: ctx,
        container: container,
        txId: txId,
        targetCategoryId: categoryId,
      );
      if (result != null && ctx.mounted && result.changedCount > 0) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text(
              'Applied ${result.changedCount} more transaction${result.changedCount == 1 ? '' : 's'} to $categoryLabel.',
            ),
          ),
        );
      }
      await _offerFutureCategoryRule(
        ctx: ctx,
        container: container,
        txId: txId,
        targetCategoryId: categoryId,
      );
    } catch (_) {
      // Optional extras: the edit itself is saved and nothing here undoes it.
    }
  }

  /// How long an optional offer may wait for the server before it is dropped.
  static const _offerTimeout = Duration(seconds: 4);

  /// Invokes the category-bulk data contract after the original row is saved.
  /// Preview and apply both use server-owned IDs and selection tiers; the UI
  /// never reconstructs merchant matches locally.
  Future<CategoryBulkApplyResult?> _offerCategoryBulkReview({
    required BuildContext ctx,
    required ProviderContainer container,
    required String txId,
    required String? targetCategoryId,
  }) async {
    if (targetCategoryId == null || targetCategoryId.isEmpty) return null;
    final repo = container.read(userCardsRepositoryProvider);
    if (repo == null) return null;
    final isCustomCategory = targetCategoryId.startsWith('custom:');
    final serverCategoryId = isCustomCategory ? null : targetCategoryId;
    final serverUserCategoryId = isCustomCategory
        ? targetCategoryId.substring('custom:'.length)
        : null;

    Future<RelatedCategoryPreview> fetchPreview() =>
        repo.fetchCategoryRelatedPreview(
          txId,
          targetCategoryId: serverCategoryId,
          targetUserCategoryId: serverUserCategoryId,
        ).timeout(_offerTimeout);

    RelatedCategoryPreview preview;
    try {
      preview = await fetchPreview();
    } catch (error) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text(
              'Saved this transaction. Related transactions could not be loaded.',
            ),
          ),
        );
      }
      return null;
    }
    if (!ctx.mounted || preview.candidates.isEmpty) return null;

    Future<CategoryBulkApplyResult> apply(Set<String> ids) =>
        repo.applyCategoryBulk(
          previewId: preview.previewId,
          selectedTransactionIds: ids,
          targetCategoryId: serverCategoryId,
          targetUserCategoryId: serverUserCategoryId,
        );

    final result = await showCategoryBulkReviewSheet(
      context: ctx,
      preview: preview,
      onRetry: fetchPreview,
      onApply: apply,
    );
    if (result != null) {
      container.invalidate(transactionsProvider);
      container.invalidate(utilizationTransactionsProvider);
      container.invalidate(homeSummaryProvider);
    }
    return result;
  }

  /// Offers the separate, opt-in future rule after the one-time bulk review.
  /// The server derives merchant identity from the owned source transaction;
  /// the client never sends a merchant name, VPA, narration, or phone number.
  Future<MerchantCategoryRule?> _offerFutureCategoryRule({
    required BuildContext ctx,
    required ProviderContainer container,
    required String txId,
    required String? targetCategoryId,
  }) async {
    if (targetCategoryId == null || targetCategoryId.isEmpty) return null;
    final repo = container.read(merchantCategoryRulesRepositoryProvider);
    if (repo == null) return null;
    final isCustomCategory = targetCategoryId.startsWith('custom:');
    final categoryId = isCustomCategory ? null : targetCategoryId;
    final userCategoryId = isCustomCategory
        ? targetCategoryId.substring('custom:'.length)
        : null;
    MerchantCategoryRulePreview preview;
    try {
      preview = await repo.preview(
        sourceTransactionId: txId,
        categoryId: categoryId,
        userCategoryId: userCategoryId,
      ).timeout(_offerTimeout);
    } catch (_) {
      // The saved one-time category edit remains complete if the optional
      // future-rule service is unavailable. Do not turn this into an edit
      // failure or imply that a rule was created.
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text(
              'Saved this transaction. Future rule options could not be loaded.',
            ),
          ),
        );
      }
      return null;
    }
    if (!ctx.mounted || !preview.hasUsableIdentity) return null;

    Future<MerchantCategoryRule> create() => repo.create(
      sourceTransactionId: txId,
      categoryId: categoryId,
      userCategoryId: userCategoryId,
    );
    Future<MerchantCategoryRule> update(MerchantCategoryRule rule) =>
        repo.update(
          rule.id,
          categoryId: categoryId,
          userCategoryId: userCategoryId,
          isActive: true,
          expectedVersion: rule.version,
        );

    return showMerchantFutureRuleSheet(
      context: ctx,
      preview: preview,
      onCreate: create,
      onUpdate: update,
      offline: container.read(isOnlineProvider).valueOrNull == false,
    );
  }

  String? _categorySlug(List<SpendCategory> categories) {
    final id = _categoryId;
    if (id == null) return null;
    for (final category in categories) {
      if (category.id == id) return category.slug;
    }
    return null;
  }

  static bool _hasCardOfType(List<UserCard> cards, String kind) {
    for (final card in cards) {
      if (card.cardType == null || card.cardType!.toLowerCase() == kind) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final tagRepository = ref.watch(transactionTagsProvider);
    if (!_tagsEdited && _originalEntry != null && tagRepository != null) {
      _tagIds = tagRepository
          .tagsForTransaction(
            widget.transactionId,
            fallback: _originalEntry!.tags,
          )
          .map((tag) => tag.id)
          .toSet();
    }
    final txn = ref.watch(
      _editTransactionProvider((
        id: widget.transactionId,
        initialEntry: widget.initialEntry,
      )),
    );
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];

    InputDecoration inputDecoration(
      String label, {
      bool required = false,
      String? errorText,
    }) => InputDecoration(
      labelText: required ? null : label,
      label: required ? requiredLabel(label) : null,
      errorText: errorText,
      labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
      filled: true,
      fillColor: BambooInk.glassFillOnPaper,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
      ),
    );

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Edit transaction',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: BambooInk.ink900),
            onPressed: () => context.pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.sm,
            AppSpace.lg,
            AppSpace.lg,
          ),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            // Never offer Save while the transaction itself failed to load;
            // the screenshot's blank form was allowing exactly that state.
            onPressed: _saving || !_initialized ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: BambooInk.lime,
                    ),
                  )
                : const Text('Save'),
          ),
        ),
      ),
      body: AppBackground(
        child: txn.when(skipLoadingOnReload: true, skipLoadingOnRefresh: true, 
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
          data: (entry) {
            _initFrom(entry);
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  children: [
                    TextField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      onChanged: (_) {
                        if (_submitted) setState(() {});
                      },
                      decoration: inputDecoration(
                        _entryKind == TxnEntryKind.income
                            ? 'Amount credited (₹)'
                            : 'Amount (₹)',
                        required: true,
                        errorText: requiredError(
                          _submitted,
                          _amountController.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    TextField(
                      controller: _merchantController,
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      decoration: inputDecoration(
                        _entryKind == TxnEntryKind.income
                            ? 'Received from'
                            : 'Merchant',
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    DropdownButtonFormField<TxnEntryKind>(
                      key: ValueKey(_entryKind),
                      initialValue: _entryKind,
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      decoration: inputDecoration('Kind'),
                      items: [
                        for (final kind in TxnEntryKind.values.where(
                          (kind) =>
                              (kind != TxnEntryKind.refund &&
                                  kind != TxnEntryKind.unknown) ||
                              kind == _entryKind,
                        ))
                          DropdownMenuItem(
                            value: kind,
                            child: Text(kind.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _entryKind = value;
                          if (value != TxnEntryKind.transfer &&
                              _selfTransfer != null) {
                            _clearedSelfTransfer = _selfTransfer;
                            _selfTransfer = null;
                            _merchantController.text =
                                _originalEntry?.merchantName ?? '';
                          }
                          if (_entryKind != TxnEntryKind.spend &&
                              _instrument == TxnInstrument.creditCard) {
                            _paymentMethod = selectPaymentInstrument(
                              PaymentSelection(
                                instrument: _instrument,
                                method: _paymentMethod,
                              ),
                              TxnInstrument.upiBank,
                            ).method;
                            _instrument = TxnInstrument.upiBank;
                            _userCardId = null;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: AppSpace.lg),
                    if (_entryKind == TxnEntryKind.transfer &&
                        entry.pipelineVersion == 2) ...[
                      DropdownButtonFormField<bool>(
                        key: ValueKey('transfer-type:$_cardBill'),
                        initialValue: _cardBill,
                        isExpanded: true,
                        style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                        decoration: inputDecoration('Transfer type'),
                        items: const [
                          DropdownMenuItem(
                            value: false,
                            child: Text('Between my accounts'),
                          ),
                          DropdownMenuItem(
                            value: true,
                            child: Text('Credit card bill'),
                          ),
                        ],
                        onChanged: _saving
                            ? null
                            : (value) =>
                                  setState(() => _cardBill = value ?? false),
                      ),
                      const SizedBox(height: AppSpace.lg),
                    ],
                    _selfTransferPicker(entry),
                    if (_selfTransfer != null)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _rememberSelfTransferChoice,
                        onChanged: _saving
                            ? null
                            : (value) => setState(
                                () => _rememberSelfTransferChoice =
                                    value ?? false,
                              ),
                        title: const Text('Remember for similar transfers'),
                        subtitle: const Text(
                          'Use this exact source account and recipient only.',
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    if (_selfTransfer != null)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _applyHistoricalSelfTransferChoice,
                        onChanged: _saving
                            ? null
                            : (value) => setState(
                                () => _applyHistoricalSelfTransferChoice =
                                    value ?? false,
                              ),
                        title: const Text(
                          'Apply to previous matching transfers',
                        ),
                        subtitle: const Text(
                          'Reclassifies older matching bank SMS rows; user-locked rows are left unchanged.',
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Paid with',
                        style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: PaymentMethodPicker(
                        entryKind: _entryKind,
                        selection: PaymentSelection(
                          instrument: _instrument,
                          method: _paymentMethod,
                        ),
                        savedInstrument: entry.instrumentKnown
                            ? entry.instrument
                            : null,
                        savedMethod: entry.paymentMethod,
                        amountController: _amountController,
                        categorySlug: _categorySlug(categories),
                        hasCreditCards: _hasCardOfType(cards, 'credit'),
                        hasDebitCards: _hasCardOfType(cards, 'debit'),
                        cardSelected: _userCardId != null,
                        // An SMS-ledger row is edited through the ledger,
                        // which cannot store a method.
                        methodsEnabled: entry.pipelineVersion != 2,
                        unknownHint: 'Unknown — choose a method',
                        onChanged: (next) => setState(() {
                          final instrumentChanged =
                              next.instrument != _instrument;
                          if (instrumentChanged &&
                              next.instrument != TxnInstrument.creditCard) {
                            _userCardId = null;
                          }
                          _instrument = next.instrument;
                          _paymentMethod = next.method;
                          // Tapping away and back to the saved instrument
                          // must not lose the saved method. Only an
                          // instrument tap restores it: clearing the method
                          // on the same instrument is the person's choice.
                          final saved = entry.paymentMethod;
                          if (instrumentChanged &&
                              _paymentMethod == null &&
                              saved != null &&
                              entry.instrumentKnown &&
                              next.instrument == entry.instrument) {
                            _paymentMethod = saved;
                          }
                        }),
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    DropdownButtonFormField<TxnRail>(
                      initialValue: _rail,
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      decoration: inputDecoration('Payment route'),
                      items: [
                        for (final rail in TxnRail.values)
                          DropdownMenuItem(
                            value: rail,
                            child: Text(_railLabel(rail)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _rail = value);
                      },
                    ),
                    if (_instrument == TxnInstrument.creditCard) ...[
                      const SizedBox(height: AppSpace.lg),
                      DropdownButtonFormField<String>(
                        initialValue: _userCardId,
                        style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                        decoration: inputDecoration('Card'),
                        items: [
                          for (final c in cards)
                            DropdownMenuItem(
                              value: c.id,
                              child: Text(
                                c.nickname?.isNotEmpty == true
                                    ? c.nickname!
                                    : c.cardName,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _userCardId = v),
                      ),
                    ],
                    const SizedBox(height: AppSpace.lg),
                    CategoryPickerField(
                      categories: categories,
                      selectedId: _categoryId,
                      label: 'Category',
                      onSelected: (v) => setState(() => _categoryId = v),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    Material(
                      color: BambooInk.glassFillOnPaper,
                      borderRadius: BorderRadius.circular(16),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(
                            color: BambooInk.hairlineOnPaper,
                          ),
                        ),
                        title: Text(
                          'Date',
                          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                        ),
                        subtitle: Text(
                          _occurredAt?.toLocal().toString().split(' ').first ??
                              '—',
                          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                        ),
                        trailing: const Icon(
                          Icons.calendar_today_outlined,
                          size: 18,
                          color: BambooInk.ink500,
                        ),
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _occurredAt ?? DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null)
                            setState(() => _occurredAt = picked);
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    TransactionTagField(
                      selectedIds: _tagIds,
                      enabled: !_saving,
                      onChanged: (ids) => setState(() {
                        _tagIds = ids;
                        _tagsEdited = true;
                      }),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpace.md),
                      Text(
                        _error!,
                        style: BambooFonts.ui(12.5, color: BambooInk.clay),
                      ),
                    ],
                    const SizedBox(height: AppSpace.xl),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static String _railLabel(TxnRail rail) => switch (rail) {
    TxnRail.upiQr => 'UPI QR',
    TxnRail.swipe => 'Swipe',
    TxnRail.online => 'Online',
    TxnRail.contactless => 'Contactless',
    TxnRail.atm => 'ATM',
    TxnRail.emi => 'EMI',
    TxnRail.unknown => 'Unknown',
  };

  static String _typedWireKey(String k) => switch (k) {
    'entry_kind' => 'entryKind',
    'amount_inr' => 'amountInr',
    'occurred_at' => 'occurredAt',
    'category_id' => 'categoryId',
    'user_category_id' => 'userCategoryId',
    'user_card_id' => 'userCardId',
    _ => k,
  };

  static String _railWireValue(TxnRail rail) => switch (rail) {
    TxnRail.upiQr => 'upi_qr',
    TxnRail.swipe => 'swipe',
    TxnRail.online => 'online',
    TxnRail.contactless => 'contactless',
    TxnRail.atm => 'atm',
    TxnRail.emi => 'emi',
    TxnRail.unknown => 'unknown',
  };
}

final _editTransactionProvider =
    FutureProvider.family<
      TransactionEntry,
      ({String id, TransactionEntry? initialEntry})
    >((ref, request) async {
      final id = request.id;
      final repo = ref.watch(userCardsRepositoryProvider);
      // Activity already has the row the user tapped. Prefer that row, then
      // the in-memory list/cache, so an expired token cannot turn a usable
      // edit screen into a blank form.
      final loaded = ref.read(transactionsProvider).valueOrNull;
      TransactionEntry? fromLoaded;
      if (loaded != null) {
        for (final entry in loaded) {
          if (entry.id == id) {
            fromLoaded = entry;
            break;
          }
        }
      }
      final cached =
          request.initialEntry ??
          fromLoaded ??
          await cachedTransactionById(ref, id);
      if (repo == null) {
        if (cached != null) return cached;
        throw ApiException('Not signed in');
      }
      try {
        return await repo.fetchTransaction(id);
      } catch (_) {
        if (cached != null) return cached;
        rethrow;
      }
    });
