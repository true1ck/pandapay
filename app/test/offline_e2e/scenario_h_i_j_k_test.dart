// WP-Q1 scenarios h, i, j, k: budgets, device-local subscription edits, bills
// marked paid, and account writes (consent revoke, name, support ticket).
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/local/subscription_overrides_store.dart';
import 'package:pandapay/data/local_first/pending_overlays.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/account/account_local_first.dart';
import 'package:pandapay/features/account/support_submit.dart';
import 'package:pandapay/features/consent/consent_commands.dart';
import 'package:pandapay/features/consent/sms_reading_consent.dart';
import 'package:pandapay/features/insights/card_bill_payment.dart';
import 'package:pandapay/features/insights/local_budgets.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'harness.dart';

const _b1 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
const _b2 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
const _newBudget = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3';

void main() {
  late OfflineApp app;
  setUp(() async => app = await OfflineApp.create());
  tearDown(() => app.dispose());

  Future<RecurringReport?> loadReport() =>
      app.c.read<Future<RecurringReport?>>(recurringReportProvider.future);

  Map<String, dynamic> serverBudget(
    String id,
    String scope,
    String? ref,
    double amount,
  ) => {
    'id': id,
    'scope': scope,
    'scope_ref_id': ref,
    'period': 'monthly',
    'amount_inr': amount,
    'rollover': false,
    'client_edited_at': null,
    'is_active': true,
  };

  test('h. budget create/edit/delete offline: local spent, one server row',
      () async {
    final card = app.server.seedCard(last4: '1111')['id'] as String;
    final now = DateTime.now();
    app.server.seedTransaction(
        amount: 300, cardId: card, at: now.subtract(const Duration(hours: 5)));
    app.server.seedTransaction(
        amount: 200, cardId: card, at: now.subtract(const Duration(hours: 6)));
    app.server.budgets[_b1] = serverBudget(_b1, 'overall', null, 5000);
    app.server.budgets[_b2] =
        serverBudget(_b2, 'category', '99999999-9999-4999-8999-999999999999', 700);
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final ref = app.ref;
    // New card budget (kept locally with an estimate) ...
    await rememberLocalBudget(ref,
        id: _newBudget,
        scope: BudgetScope.card,
        scopeRefId: card,
        period: BudgetPeriod.monthly,
        amountInr: 1000);
    await queueCommand(ref,
        kind: OverlayCommand.budgetSave,
        target: 'card|$card|monthly',
        payload: {
          'id': _newBudget,
          'scope': 'card',
          'scopeRefId': card,
          'period': 'monthly',
          'amountInr': 1000.0,
          'rollover': false,
          'clientEditedAt': DateTime.now().toUtc().toIso8601String(),
        });
    // ... an edit of the overall budget ...
    await queueCommand(ref,
        kind: OverlayCommand.budgetSave,
        target: 'overall||monthly',
        payload: {
          'id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
          'scope': 'overall',
          'scopeRefId': null,
          'period': 'monthly',
          'amountInr': 6000.0,
          'rollover': false,
          'clientEditedAt': DateTime.now().toUtc().toIso8601String(),
        });
    // ... and a delete.
    await queueCommand(ref,
        kind: OverlayCommand.budgetDelete,
        target: _b2,
        payload: {
          'id': _b2,
          'clientEditedAt': DateTime.now().toUtc().toIso8601String(),
        });
    await forgetLocalBudget(ref, _b2);
    app.refreshViews();

    Future<List<BudgetStatus>> shown() async {
      app.c.invalidate(budgetsProvider);
      return app.c.read(budgetsProvider.future);
    }

    var list = await shown();
    BudgetStatus byScope(BudgetScope s) => list.singleWhere((b) => b.scope == s);
    expect(byScope(BudgetScope.card).isEstimate, isTrue);
    expect(byScope(BudgetScope.card).spent, Money.fromRupees(500),
        reason: 'spent is computed on the phone');
    expect(byScope(BudgetScope.overall).amount, Money.fromRupees(6000));
    expect(list.any((b) => b.scope == BudgetScope.category), isFalse);
    expect(app.pending, 3);
    expect(app.server.log, isEmpty);

    await app.restart(online: false);
    list = await shown();
    expect(list, hasLength(2), reason: 'survives a restart');
    expect(app.pending, 3);

    app.server.loseNext(1, ['/budgets']);
    await app.goOnline();
    await app.flushAll();

    expect(app.server.invalidIdRequests, isEmpty);
    final active = app.server.activeBudgets;
    expect(active.where((b) => b['scope'] == 'card'), hasLength(1));
    expect(active.where((b) => b['scope'] == 'overall'), hasLength(1));
    expect(active.singleWhere((b) => b['scope'] == 'overall')['amount_inr'], 6000);
    expect(active.any((b) => b['scope'] == 'category'), isFalse);
    expect(app.server.count('POST', '/budgets'), 3,
        reason: 'one replay after the lost answer');
    list = await shown();
    expect(list.where((b) => b.scope == BudgetScope.card), hasLength(1));
    expect(list.where((b) => b.scope == BudgetScope.overall), hasLength(1));
    expect(app.pending, 0);
  });

  test('i. subscriptions: device-local ids never reach the server, survive restart',
      () async {
    final s1 = app.server.newId();
    final s2 = app.server.newId();
    app.server.recurringSeries[s1] = {'id': s1};
    app.server.recurringSeries[s2] = {'id': s2};
    await app.start();
    await app.firstSyncOnline();
    await loadReport();
    await app.goOffline();
    app.server.clearLog();

    final ref = app.ref;
    final cache = await app.c.read(responseCacheProvider.future);
    final overrides =
        SubscriptionOverridesStore(cache.financialStore.database, app.namespace);
    final next = DateTime(2026, 12, 1);
    // What the subscription screen does per id kind.
    for (final id in ['v2:pattern:abc', 'projection:x', 'manual:zzz', s1, s2]) {
      expect(isDeviceLocalSeriesId(id), id != s1 && id != s2);
    }
    overrides.hide('v2:pattern:abc');
    overrides.edit('projection:x',
        displayName: 'Edited',
        amountInr: 99,
        cadenceDays: 30,
        nextExpectedOn: next,
        autopayStatus: 'unknown');
    overrides.addManual(
        displayName: 'Manual Sub',
        amountInr: 49,
        cadenceDays: 30,
        nextExpectedOn: next,
        autopayStatus: 'unknown');
    await queueCommand(ref,
        kind: OverlayCommand.recurringUpdate,
        target: s1,
        payload: {
          'id': s1,
          'displayName': 'Renamed Sub',
          'amountInr': 120.0,
          'cadenceDays': 30,
          'nextExpectedOn': next.toIso8601String(),
          'autopayStatus': 'unknown',
        });
    await queueCommand(ref,
        kind: OverlayCommand.recurringDismiss, target: s2, payload: {'id': s2});

    app.c.invalidate(recurringReportProvider);
    RecurringReport? report = await loadReport();
    expect(report!.series.any((s) => s.displayName == 'Manual Sub'), isTrue);
    expect(app.pending, 2, reason: 'only the two server-id edits are queued');

    await app.restart(online: false);
    report = await loadReport();
    expect(report!.series.any((s) => s.displayName == 'Manual Sub'), isTrue,
        reason: 'manual add survives a restart');
    expect(app.pending, 2);

    await app.goOnline();
    await app.flushAll();
    expect(app.server.invalidIdRequests, isEmpty);
    expect(app.server.recurringEdits..sort(),
        (['dismiss $s2', 'patch $s1']..sort()));
    expect(app.server.unhandledWrites, isEmpty);
    app.c.invalidate(recurringReportProvider);
    report = await loadReport();
    expect(report!.series.any((s) => s.displayName == 'Manual Sub'), isTrue);
  });

  test('j. bill marked paid + card bill payment offline survive refresh/restart',
      () async {
    final card = app.server.seedCard(last4: '1111')['id'] as String;
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final repo = app.c.read(commitmentsRepositoryProvider);
    final due = DateTime.now().add(const Duration(days: 3));
    await repo.save(Commitment(
      id: 'bill-1',
      title: 'Synthetic Utility',
      category: CommitmentCategory.utility,
      amount: Money.fromRupees(900),
      dueOn: due,
      cadence: CommitmentCadence.oneTime,
      source: CommitmentSource.manual,
    ));
    await repo.markAsPaid('bill-1', paidOn: DateTime.now());

    final outbox = await app.c.read(outboxRepositoryProvider.future);
    final txnId = cardBillPaymentTxnId(card, due);
    await enqueueCardBillPayment(outbox,
        txnId: txnId,
        amount: Money.fromRupees(4500),
        cardId: card,
        cardName: 'Test Card One',
        last4: '1111');
    // Saving "paid" twice before it syncs is still one payment.
    await enqueueCardBillPayment(outbox,
        txnId: txnId,
        amount: Money.fromRupees(4500),
        cardId: card,
        cardName: 'Test Card One',
        last4: '1111');
    expect(app.pending, greaterThanOrEqualTo(2));

    await app.restart(online: false);
    var bills = await app.c.read(commitmentsProvider.future);
    expect(bills.singleWhere((b) => b.id == 'bill-1').status,
        CommitmentStatus.paid);

    app.server.loseNext(1, ['/transactions']);
    await app.goOnline();
    await app.flushAll();

    expect(app.server.commitments, hasLength(1));
    expect(app.server.commitments.values.single['status'], 'paid');
    final payments = app.server.activeTransactions
        .where((t) => t['merchant_name'] == 'Credit Card Bill Payment')
        .toList();
    expect(payments, hasLength(1));
    expect(payments.single['entry_kind'], 'transfer');
    expect(app.server.duplicates, isEmpty);

    // A full refresh and another restart keep both.
    app.c.invalidate(homeDataRefreshProvider);
    await app.c.read(homeDataRefreshProvider.future);
    await app.restart(online: true);
    bills = await app.c.read(commitmentsProvider.future);
    expect(bills.singleWhere((b) => b.id == 'bill-1').status,
        CommitmentStatus.paid);
    final rows = (await app.c.read(transactionsProvider.future))
        .where((t) => t.merchantName == 'Credit Card Bill Payment');
    expect(rows, hasLength(1));
    expect(app.pending, 0);
  });

  test('k. consent revoke, profile name and support ticket offline', () async {
    await app.start();
    await app.firstSyncOnline();
    await SmsReadingConsentMirror.set(app.namespace, true);
    await app.goOffline();
    app.server.clearLog();
    final ref = app.ref;

    final r = await submitConsentLocalFirst(ref,
        purpose: smsReadingConsentPurpose,
        granted: false,
        sourceScreen: 'privacy_permissions');
    expect(r, AccountWrite.queued);
    expect(await SmsReadingConsentMirror.isGranted(app.namespace), isFalse,
        reason: 'local mirror is cleared before anything is sent');

    final api = ref.read(accountNameApiProvider)!;
    final named = await sendOrQueue(ref,
        kind: AccountCommand.profileName,
        target: 'profile_name',
        payload: {'name': 'Renamed Person'},
        live: () => api.save('Renamed Person'));
    expect(named, AccountWrite.queued);

    final t = await submitTicketLocalFirst(ref,
        accessToken: app.token,
        kind: 'bug',
        message: 'Synthetic message',
        appVersion: '1.0.0');
    expect(t, AccountWrite.queued);
    expect(app.pending, 3);
    expect(app.server.log, isEmpty);

    await app.restart(online: false);
    expect(app.pending, 3);
    expect(await SmsReadingConsentMirror.isGranted(app.namespace), isFalse);

    app.server.loseNext(2, ['/consents', '/support-tickets']);
    await app.goOnline();
    await app.flushAll();

    expect(app.server.consents.where((c) => c['purpose'] == 'sms_reading'),
        hasLength(1),
        reason: 'exactly one audit POST lands');
    expect(app.server.consents.single['granted'], false);
    expect(app.server.tickets, hasLength(1));
    expect(app.server.profile['display_name'], 'Renamed Person');
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
  });
}
