import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_amount_input.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_draft.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/shared_expenses.dart';

const me = '00000000-0000-4000-8000-000000000001';
const rahul = '00000000-0000-4000-8000-000000000002';
const priya = '00000000-0000-4000-8000-000000000003';
const owner = '00000000-0000-4000-8000-000000000004';
SharedExpenseDraft draft({
  String bill = '100',
  String shared = '100',
  Map<String, SharedPayerInput>? payers,
  List<String> participants = const [me, rahul, priya],
  SharedSplitMode mode = SharedSplitMode.equal,
  Map<String, String> inputs = const {},
  SharedEntryKind kind = SharedEntryKind.unlinkedCash,
  SharedExpenseSourceReference? source,
  Money? lockedOwnPaid,
  bool confirmedValuation = true,
}) => SharedExpenseDraft(
  ownMemberId: me,
  ownAccountId: owner,
  memberOrder: const [me, rahul, priya],
  billText: bill,
  sharedText: shared,
  payers: payers ?? {me: SharedPayerInput(fullText: bill, sharedText: shared)},
  participants: participants,
  mode: mode,
  splitInputs: inputs,
  entryKind: kind,
  source: source,
  lockedOwnPaid: lockedOwnPaid,
  confirmedValuation: confirmedValuation,
);
void main() {
  test('persisted remainder order is detached from mutable roster input', () {
    final order = [me, rahul, priya];
    final value = SharedExpenseDraft(
      ownMemberId: me,
      ownAccountId: owner,
      memberOrder: order,
      billText: '100',
      sharedText: '100',
      payers: {me: const SharedPayerInput(fullText: '100', sharedText: '100')},
      participants: const [me, rahul, priya],
    );
    order.setAll(0, [priya, rahul, me]);
    expect(value.evaluate().preview!.shares[me]!.paise, 3334);
  });
  test(
    'decimal input converts strings exactly without accepting exponent or rounding',
    () {
      expect(SharedDecimalInput.parse('00033.34').units, 3334);
      expect(SharedDecimalInput.parse(' 0.01 ').units, 1);
      for (final value in [
        '-1',
        '+1',
        '1e3',
        'NaN',
        '1,000',
        '1.001',
        '١٠',
        '1\n2',
        '9' * 1000,
      ]) {
        expect(SharedDecimalInput.parse(value).isValid, isFalse, reason: value);
      }
      expect(
        SharedDecimalInput.parse('100.').state,
        SharedInputState.incomplete,
      );
      expect(SharedDecimalInput.parse('').state, SharedInputState.empty);
      expect(
        sharedRupeesText(const Money.fromPaise(9007199254740991)),
        '90071992547409.91',
      );
    },
  );
  test('maximum and one-paisa-over inputs fail without coercion', () {
    expect(SharedDecimalInput.parse('10000000').units, 1000000000);
    expect(SharedDecimalInput.parse('10000000.01').isValid, isFalse);
    expect(draft(bill: '0', shared: '0').evaluate().isValid, isFalse);
  });
  test(
    'equal allocation persists remainder order independent of selection order',
    () {
      final a = draft().evaluate(),
          b = draft(participants: [priya, rahul, me]).evaluate();
      expect(a.isValid, isTrue);
      expect(a.preview!.shares[me]!.paise, 3334);
      expect(a.preview!.shares[rahul]!.paise, 3333);
      expect(a.preview!.financialSnapshot, b.preview!.financialSnapshot);
    },
  );
  test(
    'partial shared bill keeps full payment residual and own share distinct',
    () {
      final result = draft(bill: '1400', shared: '1200').evaluate();
      expect(result.preview!.billTotal.paise, 140000);
      expect(result.preview!.sharedTotal.paise, 120000);
      expect(result.preview!.yourFullPaid.paise, 140000);
      expect(result.preview!.yourSharedPaid.paise, 120000);
      expect(result.preview!.yourResidual.paise, 20000);
      expect(result.preview!.yourShare.paise, 40000);
      expect(result.preview!.yourPersonalCost.paise, 60000);
      expect(result.preview!.financialSnapshot['totalMinor'], '120000');
    },
  );
  test(
    'someone else paid has no own payment and includes only own consumption',
    () {
      final result = draft(
        kind: SharedEntryKind.someoneElsePaid,
        bill: '1400',
        shared: '1200',
        payers: {
          rahul: const SharedPayerInput(fullText: '1400', sharedText: '1200'),
        },
      ).evaluate();
      expect(result.isValid, isTrue);
      expect(result.preview!.yourFullPaid.isZero, isTrue);
      expect(result.preview!.yourResidual.isZero, isTrue);
      expect(result.preview!.yourPersonalCost.paise, 40000);
      expect(result.preview!.yourBalance.paise, -40000);
    },
  );
  test('multiple payers never assigns another payer residual to me', () {
    final result = draft(
      bill: '1000',
      shared: '600',
      payers: {
        me: const SharedPayerInput(fullText: '400', sharedText: '300'),
        rahul: const SharedPayerInput(fullText: '600', sharedText: '300'),
      },
    ).evaluate();
    expect(result.preview!.yourResidual.paise, 10000);
    expect(result.preview!.yourPersonalCost.paise, 30000);
  });
  test('payer-only member retains residual but zero shared consumption', () {
    final result = draft(
      bill: '100',
      shared: '60',
      participants: [rahul, priya],
    ).evaluate();
    expect(result.preview!.yourShare.isZero, isTrue);
    expect(result.preview!.yourPersonalCost.paise, 4000);
    expect(result.preview!.yourBalance.paise, 6000);
  });
  test('uninvolved member has neither own funding nor own consumption', () {
    final result = draft(
      participants: [priya],
      payers: {
        rahul: const SharedPayerInput(fullText: '100', sharedText: '100'),
      },
    ).evaluate();
    expect(result.preview!.yourPersonalCost.isZero, isTrue);
    expect(result.preview!.yourBalance.isZero, isTrue);
  });
  test(
    'exact and percentage fields validate the live sum without silent adjustment',
    () {
      final exact = draft(
        mode: SharedSplitMode.exact,
        inputs: {me: '33.34', rahul: '33.33', priya: '33.33'},
      ).evaluate();
      expect(exact.isValid, isTrue);
      final wrong = draft(
        mode: SharedSplitMode.exact,
        inputs: {me: '33.33', rahul: '33.33', priya: '33.33'},
      ).evaluate();
      expect(wrong.errors['splitTotal'], isNotNull);
      expect(wrong.preview, isNull);
      final pct = draft(
        mode: SharedSplitMode.percentage,
        inputs: {me: '50', rahul: '25.01', priya: '24.99'},
      ).evaluate();
      expect(pct.preview!.shares[rahul]!.paise, 2501);
      expect(
        draft(
          mode: SharedSplitMode.percentage,
          inputs: {me: '50', rahul: '25', priya: '24.99'},
        ).evaluate().isValid,
        isFalse,
      );
    },
  );
  test('weighted shares use whole positive units and reject zero total', () {
    final result = draft(
      mode: SharedSplitMode.shares,
      inputs: {me: '1', rahul: '2', priya: '0'},
    ).evaluate();
    expect(result.preview!.shares[me]!.paise, 3333);
    expect(result.preview!.shares[rahul]!.paise, 6667);
    for (final input in ['0', '1.5', '1000001']) {
      expect(
        draft(
          mode: SharedSplitMode.shares,
          inputs: {me: input, rahul: '0', priya: '0'},
        ).evaluate().isValid,
        isFalse,
      );
    }
  });
  test('each payer and both totals must reconcile separately', () {
    for (final payers in [
      {me: const SharedPayerInput(fullText: '99', sharedText: '100')},
      {me: const SharedPayerInput(fullText: '100', sharedText: '99')},
      {me: const SharedPayerInput(fullText: '101', sharedText: '100')},
    ]) {
      expect(draft(payers: payers).evaluate().isValid, isFalse);
    }
    expect(draft(bill: '99', shared: '100').evaluate().isValid, isFalse);
    expect(
      draft(kind: SharedEntryKind.someoneElsePaid).evaluate().isValid,
      isFalse,
    );
  });
  test(
    'draft freezes fields and rejects unknown, duplicate or missing members',
    () {
      final inputs = {me: '100', rahul: '0', priya: '0'};
      final value = draft(mode: SharedSplitMode.exact, inputs: inputs);
      inputs[me] = '1';
      expect(value.evaluate().isValid, isTrue);
      expect(draft(participants: [me, me]).evaluate().isValid, isFalse);
      expect(draft(participants: []).evaluate().isValid, isFalse);
      expect(draft(participants: [owner]).evaluate().isValid, isFalse);
      expect(
        () => value.evaluate().preview!.financialSnapshot['totalMinor'] = '1',
        throwsUnsupportedError,
      );
    },
  );
  test(
    'unfinished amount remains editable but cannot publish last valid value',
    () {
      final value = draft(bill: '100.', shared: '100');
      expect(value.billText, '100.');
      expect(value.evaluate().preview, isNull);
      expect(value.evaluate().isValid, isFalse);
    },
  );
  test(
    'linked source intent never falls back to an unlinked accepted expense',
    () {
      final source = SharedExpenseSourceReference.parse({
        'kind': 'legacy_transaction',
        'ownerAccountId': owner,
        'canonicalTransactionId': me,
        'sourceVersion': 'a' * 64,
      });
      final value = draft(
        kind: SharedEntryKind.existingOwnPayment,
        source: source,
        lockedOwnPaid: const Money.fromPaise(10000),
      );
      final result = value.evaluate();
      expect(result.isValid, isTrue);
      expect(result.canPropose, isFalse);
      expect(
        result.blockers,
        contains(SharedDraftBlocker.sourceFundingUnavailable),
      );
      expect(value.source!.toJson(), source.toJson());
      expect(value.evaluate(sourceFundingEnabled: true).canPropose, isTrue);
      expect(
        draft(
          kind: SharedEntryKind.newOwnPayment,
        ).evaluate(sourceFundingEnabled: true).canPropose,
        isFalse,
      );
    },
  );
  test(
    'linked source owner, amount, current fingerprint and valuation are required',
    () {
      final foreign = SharedExpenseSourceReference.parse({
        'kind': 'confirmed_foreign_payment',
        'ownerAccountId': owner,
        'foreignPaymentId': rahul,
        'canonicalTransactionId': me,
        'sourceVersion': 'a' * 64,
      });
      final value = draft(
        kind: SharedEntryKind.existingOwnPayment,
        source: foreign,
        lockedOwnPaid: const Money.fromPaise(9999),
        confirmedValuation: false,
      );
      final result = value.evaluate(sourceFundingEnabled: true);
      expect(result.isValid, isFalse);
      expect(result.canPropose, isFalse);
      expect(
        result.blockers,
        contains(SharedDraftBlocker.unconfirmedValuation),
      );
      final unknown = SharedExpenseSourceReference.parse({
        'kind': 'sms_v2_event',
        'ownerAccountId': owner,
        'eventId': 'b' * 64,
      });
      expect(
        draft(
          kind: SharedEntryKind.existingOwnPayment,
          source: unknown,
          lockedOwnPaid: const Money.fromPaise(10000),
        ).evaluate(sourceFundingEnabled: true).canPropose,
        isFalse,
      );
    },
  );
}
