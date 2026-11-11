// A source the user rejected ("Not mine") hides its movements from the
// ledger, including a notice that names the account by its number alone (no
// bank). Without that, such a notice fell through to "an account of the user
// that we cannot name" and was counted. Synthetic facts only.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import '../linker/helpers.dart';

Instrument account(String id, String issuer, String mask, {InstrumentStatus status = InstrumentStatus.confirmed}) =>
    instrument(id, InstrumentKind.bankAccount, issuer, mask, status: status);

const _numberOnly = InstrumentMention(
  kind: InstrumentKind.bankAccount,
  issuerSlug: null,
  maskDigits: '8206',
  maskLength: 4,
);

List<LedgerEntry> projectCredit(Map<String, Instrument> known) {
  final f = credit(
    'p2p',
    410000,
    at: '2026-04-05T10:00:00Z',
    mention: _numberOnly,
    counterparty: party(name: 'SOMEONE', kind: 'person'),
  );
  final store = MemoryEvents();
  store.apply(
    testLinker().link(
      incoming: [f],
      context: RuleLinkContext(
        recentFacts: const [],
        openEvents: const [],
        instrumentsById: known,
        knownEvents: const [],
      ),
      rules: baselineLinkRules(),
    ),
  );
  final byId = {f.factId: f};
  final projector = DefaultLedgerProjector();
  return [for (final e in store.all) ...projector.project(e, byId, known, null)];
}

void main() {
  final rejected = account('00000000-0000-4000-8000-0000000000e1', 'indiapost', '8206', status: InstrumentStatus.rejected);
  final live = account('00000000-0000-4000-8000-0000000000e2', 'sbi', '8206');
  final other = account('00000000-0000-4000-8000-0000000000e3', 'sbi', '1111');

  test('a number-only notice for a live account is counted to that account', () {
    final entries = projectCredit({live.instrumentId: live});
    expect(entries, hasLength(1));
    expect((entries.single.to as InstrumentEndpoint).instrumentId, live.instrumentId);
  });

  test('a number-only notice whose only match is a rejected account is hidden', () {
    expect(projectCredit({rejected.instrumentId: rejected, other.instrumentId: other}), isEmpty);
  });

  test('when a live account also ends in those digits the live one keeps the notice', () {
    final entries = projectCredit({rejected.instrumentId: rejected, live.instrumentId: live});
    expect(entries, hasLength(1));
    expect((entries.single.to as InstrumentEndpoint).instrumentId, live.instrumentId);
  });

  test('no account with that number at all is still counted as the user\'s own, unnamed', () {
    final entries = projectCredit({other.instrumentId: other});
    expect(entries, hasLength(1));
    expect(entries.single.to, isA<OwnUnresolvedEndpoint>());
  });

  test('two rejected accounts with those digits are still hidden', () {
    final second = account('00000000-0000-4000-8000-0000000000e4', 'idfc', '8206', status: InstrumentStatus.rejected);
    expect(projectCredit({rejected.instrumentId: rejected, second.instrumentId: second}), isEmpty);
  });
}
