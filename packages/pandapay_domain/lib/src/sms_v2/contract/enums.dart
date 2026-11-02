// Wire-name enums for the SMS pipeline v2 contract.
//
// Generated once from contracts/sms/v2 and now maintained by hand; the
// conformance tests fail if a wire value drifts from the schemas.

import 'errors.dart';

/// An enum whose values have a fixed wire name.
abstract interface class WireEnum {
  String get wire;
}

/// Looks up the value named [wire]; throws a [ContractException] when none.
T enumFromWire<T extends WireEnum>(List<T> values, String wire, [String path = '']) {
  for (final v in values) {
    if (v.wire == wire) return v;
  }
  throw ContractException([ContractError('enum.unknown', path)]);
}

/// What an amount means in a fact.
enum AmountRole implements WireEnum {
  posted('posted'),
  held('held'),
  released('released'),
  scheduled('scheduled'),
  dueTotal('due_total'),
  dueMinimum('due_minimum'),
  outstanding('outstanding'),
  availableBalance('available_balance'),
  availableCredit('available_credit'),
  creditLimit('credit_limit'),
  ceiling('ceiling'),
  pointsEarned('points_earned'),
  pointsRedeemed('points_redeemed'),
  pointsBalance('points_balance'),
  cashValue('cash_value');

  const AmountRole(this.wire);

  @override
  final String wire;

  static AmountRole fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Kind of account, card or wallet.
enum InstrumentKind implements WireEnum {
  bankAccount('bank_account'),
  creditCard('credit_card'),
  debitCard('debit_card'),
  prepaidCard('prepaid_card'),
  wallet('wallet'),
  broker('broker'),
  loan('loan'),
  payLater('pay_later');

  const InstrumentKind(this.wire);

  @override
  final String wire;

  static InstrumentKind fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Who is on the other side of a movement.
enum CounterpartyKind implements WireEnum {
  merchant('merchant'),
  person('person'),
  own('own'),
  bank('bank'),
  unknown('unknown');

  const CounterpartyKind(this.wire);

  @override
  final String wire;

  static CounterpartyKind fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Which engine produced a fact.
enum Engine implements WireEnum {
  rules('rules'),
  ai('ai'),
  user('user');

  const Engine(this.wire);

  @override
  final String wire;

  static Engine fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// The 10 fact types.
enum FactType implements WireEnum {
  movement('movement'),
  attempt('attempt'),
  hold('hold'),
  balanceSnapshot('balance_snapshot'),
  limitChange('limit_change'),
  billDue('bill_due'),
  mandate('mandate'),
  reward('reward'),
  instrumentHint('instrument_hint'),
  info('info');

  const FactType(this.wire);

  @override
  final String wire;

  static FactType fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Money direction.
enum Direction implements WireEnum {
  debit('debit'),
  credit('credit');

  const Direction(this.wire);

  @override
  final String wire;

  static Direction fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Why money moved.
enum MovementPurpose implements WireEnum {
  purchase('purchase'),
  p2p('p2p'),
  atm('atm'),
  salary('salary'),
  interest('interest'),
  refund('refund'),
  cashback('cashback'),
  reversal('reversal'),
  fee('fee'),
  emi('emi'),
  cardPayment('card_payment'),
  walletTopup('wallet_topup'),
  investment('investment'),
  billPayment('bill_payment'),
  tax('tax'),
  transfer('transfer'),
  dividend('dividend'),
  unknown('unknown');

  const MovementPurpose(this.wire);

  @override
  final String wire;

  static MovementPurpose fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// How money moved.
enum Rail implements WireEnum {
  upi('upi'),
  card('card'),
  imps('imps'),
  neft('neft'),
  rtgs('rtgs'),
  cheque('cheque'),
  nach('nach'),
  wallet('wallet'),
  cash('cash'),
  unknown('unknown');

  const Rail(this.wire);

  @override
  final String wire;

  static Rail fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// State of an attempt that did not move money.
enum AttemptStatus implements WireEnum {
  failed('failed'),
  declined('declined'),
  pending('pending'),
  scheduled('scheduled'),
  cancelled('cancelled');

  const AttemptStatus(this.wire);

  @override
  final String wire;

  static AttemptStatus fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Phase of a hold.
enum HoldPhase implements WireEnum {
  placed('placed'),
  released('released'),
  converted('converted');

  const HoldPhase(this.wire);

  @override
  final String wire;

  static HoldPhase fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Why money is held.
enum HoldPurpose implements WireEnum {
  ipoAsba('ipo_asba'),
  upiMandateBlock('upi_mandate_block'),
  preauth('preauth'),
  lien('lien'),
  other('other');

  const HoldPurpose(this.wire);

  @override
  final String wire;

  static HoldPurpose fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Why a limit changed.
enum LimitChangeReason implements WireEnum {
  increase('increase'),
  decrease('decrease'),
  assigned('assigned');

  const LimitChangeReason(this.wire);

  @override
  final String wire;

  static LimitChangeReason fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Lifecycle phase of a mandate.
enum MandatePhase implements WireEnum {
  created('created'),
  modified('modified'),
  paused('paused'),
  resumed('resumed'),
  revoked('revoked'),
  expired('expired');

  const MandatePhase(this.wire);

  @override
  final String wire;

  static MandatePhase fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// What a mandate is for.
enum MandatePurpose implements WireEnum {
  ipo('ipo'),
  subscription('subscription'),
  bill('bill'),
  sip('sip'),
  loan('loan'),
  other('other');

  const MandatePurpose(this.wire);

  @override
  final String wire;

  static MandatePurpose fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Identity-only hint kinds.
enum InstrumentHintKind implements WireEnum {
  cardIssued('card_issued'),
  cardActivated('card_activated'),
  accountOpened('account_opened'),
  productName('product_name'),
  linkedUpi('linked_upi');

  const InstrumentHintKind(this.wire);

  @override
  final String wire;

  static InstrumentHintKind fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Kinds of non-financial message.
enum InfoCategory implements WireEnum {
  otp('otp'),
  security('security'),
  promotion('promotion'),
  service('service'),
  delivery('delivery'),
  other('other');

  const InfoCategory(this.wire);

  @override
  final String wire;

  static InfoCategory fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Event types.
enum EventType implements WireEnum {
  purchase('purchase'),
  refund('refund'),
  cashback('cashback'),
  income('income'),
  p2pOut('p2p_out'),
  p2pIn('p2p_in'),
  ownTransfer('own_transfer'),
  cardBillPayment('card_bill_payment'),
  walletTopup('wallet_topup'),
  investment('investment'),
  ipoApplication('ipo_application'),
  investmentWithdrawal('investment_withdrawal'),
  dividend('dividend'),
  atmWithdrawal('atm_withdrawal'),
  fee('fee'),
  emi('emi'),
  billPayment('bill_payment'),
  subscriptionCharge('subscription_charge'),
  unknown('unknown');

  const EventType(this.wire);

  @override
  final String wire;

  static EventType fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Event statuses.
enum EventStatus implements WireEnum {
  complete('complete'),
  awaitingLeg('awaiting_leg'),
  ambiguous('ambiguous'),
  userConfirmed('user_confirmed');

  const EventStatus(this.wire);

  @override
  final String wire;

  static EventStatus fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Roles a fact plays in an event.
enum LegRole implements WireEnum {
  debitLeg('debit_leg'),
  creditLeg('credit_leg'),
  holdPlaced('hold_placed'),
  holdReleased('hold_released'),
  holdConverted('hold_converted'),
  original('original'),
  reversal('reversal'),
  charge('charge'),
  duplicateNotice('duplicate_notice');

  const LegRole(this.wire);

  @override
  final String wire;

  static LegRole fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Instrument lifecycle status.
enum InstrumentStatus implements WireEnum {
  detected('detected'),
  confirmed('confirmed'),
  rejected('rejected'),
  archived('archived');

  const InstrumentStatus(this.wire);

  @override
  final String wire;

  static InstrumentStatus fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Where a credit limit came from.
enum CreditLimitSource implements WireEnum {
  sms('sms'),
  user('user');

  const CreditLimitSource(this.wire);

  @override
  final String wire;

  static CreditLimitSource fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Where a category came from.
enum CategorySource implements WireEnum {
  user('user'),
  shared('shared'),
  catalogue('catalogue'),
  mcc('mcc'),
  historyConfirmed('history_confirmed'),
  ai('ai'),
  fallback('default');

  const CategorySource(this.wire);

  @override
  final String wire;

  static CategorySource fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Kinds of sender.
enum IssuerKind implements WireEnum {
  bank('bank'),
  cardNetwork('card_network'),
  wallet('wallet'),
  broker('broker'),
  gateway('gateway'),
  biller('biller'),
  other('other');

  const IssuerKind(this.wire);

  @override
  final String wire;

  static IssuerKind fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// How a wallet reports spends.
enum WalletSpendVisibility implements WireEnum {
  sms('sms'),
  partial('partial');

  const WalletSpendVisibility(this.wire);

  @override
  final String wire;

  static WalletSpendVisibility fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Rule lifecycle status.
enum RuleStatus implements WireEnum {
  draft('draft'),
  active('active'),
  provisional('provisional'),
  paused('paused'),
  retired('retired');

  const RuleStatus(this.wire);

  @override
  final String wire;

  static RuleStatus fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// How a category rule matches.
enum CategoryMatch implements WireEnum {
  token('token'),
  exact('exact'),
  prefix('prefix'),
  contains('contains');

  const CategoryMatch(this.wire);

  @override
  final String wire;

  static CategoryMatch fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// How link rules use references.
enum ReferenceMode implements WireEnum {
  ignore('ignore'),
  prefer('prefer'),
  require('require');

  const ReferenceMode(this.wire);

  @override
  final String wire;

  static ReferenceMode fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// What a lone leg becomes.
enum SingleLeg implements WireEnum {
  complete('complete'),
  awaitingLeg('awaiting_leg'),
  review('review');

  const SingleLeg(this.wire);

  @override
  final String wire;

  static SingleLeg fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}

/// Ledger units.
enum LedgerUnit implements WireEnum {
  inr('INR'),
  points('POINTS');

  const LedgerUnit(this.wire);

  @override
  final String wire;

  static LedgerUnit fromWire(String wire, [String path = '']) => enumFromWire(values, wire, path);
}
