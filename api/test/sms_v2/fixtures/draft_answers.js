"use strict";
// Model answers for synthetic layouts: VALID ones a careful model would give (the validator must accept every one)
// and WRONG ones the audit (qa-bug-hunt S3-1) showed the old validator accepted. Slots are named as the model names
// them (amt1, date1 ...). Used by draft_sanity.test.js.
const mv = (direction, purpose, rail, extra = {}) => ({
  factType: "movement",
  attrs: { direction, purpose, rail, ...(extra.attrs ?? {}) },
  amounts: [{ role: "posted", from: extra.amt ?? "amt1", unit: "INR" }],
  ...(extra.date ? { occurredAt: { from: extra.date } } : {}),
  ...(extra.mask ? { instrument: { kind: extra.kind ?? "bank_account", maskFrom: extra.mask } } : {}),
  ...(extra.party ? { counterparty: { nameFrom: extra.party, kind: "merchant" } } : {}),
  ...(extra.refs ? { references: extra.refs } : {}),
});
const bal = (from, role = "available_balance") => ({ factType: "balance_snapshot", attrs: { asOf: { field: "occurredAt", sameAs: 0 } }, amounts: [{ role, from, unit: "INR" }], instrument: { sameAs: 0 } });
const info = (category) => ({ factType: "info", attrs: { category } });
const ans = (emit, confidence = 0.9) => ({ family: "ai_test", confidence, emit });

const DEBIT = "<AMT> debited from A/c <MASK> on <DATE> to <PARTY>. UPI Ref <REF>. Avl Bal <AMT>.";

const VALID = [
  { name: "upi debit with balance", layout: DEBIT, answer: ans([mv("debit", "purchase", "upi", { mask: "mask1", date: "date1", party: "party1", refs: { upiRef: "ref1" } }), bal("amt2")]) },
  { name: "upi debit, purpose unknown", layout: DEBIT, answer: ans([mv("debit", "unknown", "upi", { mask: "mask1", date: "date1", party: "party1" })]) },
  { name: "otp", layout: "Dear Customer, your OTP is <REF>. Do not share it with anyone.", answer: ans([info("otp")]) },
  { name: "credit with balance", layout: "Your account <MASK> was credited with <AMT> on <DATE>. Avl Bal <AMT>.", answer: ans([mv("credit", "unknown", "unknown", { mask: "mask1", date: "date1", amt: "amt1" }), bal("amt2")]) },
  { name: "card spend with available limit", layout: "<AMT> spent on card <MASK> on <DATE>. Avl limit <AMT>.", answer: ans([mv("debit", "purchase", "card", { mask: "mask1", kind: "credit_card", date: "date1" }), bal("amt2", "available_credit")]) },
  { name: "card spend", layout: "<AMT> spent on card <MASK>.", answer: ans([mv("debit", "purchase", "card", { mask: "mask1", kind: "credit_card" })]) },
  { name: "bill due", layout: "Your <PARTY> bill of <AMT> is due on <DATE>.", answer: ans([{ factType: "bill_due", attrs: { dueDate: { from: "date1" }, billerName: { from: "party1" } }, amounts: [{ role: "due_total", from: "amt1", unit: "INR" }] }]) },
  { name: "account updated", layout: "Your account has been updated.", answer: ans([info("service")]) },
  { name: "money sent to vpa", layout: "Rs <AMT> sent to <VPA> successfully. UPI Ref <REF>.", answer: ans([{ ...mv("debit", "p2p", "upi", { refs: { upiRef: "ref1" } }), counterparty: { vpaFrom: "vpa1", kind: "person" } }]) },
  { name: "salary credit", layout: "Salary of <AMT> credited to A/c <MASK> on <DATE>.", answer: ans([mv("credit", "salary", "neft", { mask: "mask1", date: "date1" })]) },
  { name: "interest credit", layout: "Interest <AMT> credited to your A/c <MASK>.", answer: ans([mv("credit", "interest", "unknown", { mask: "mask1" })]) },
  { name: "atm withdrawal", layout: "<AMT> withdrawn at ATM from A/c <MASK> on <DATE>. Bal <AMT>.", answer: ans([mv("debit", "atm", "card", { mask: "mask1", date: "date1" }), bal("amt2")]) },
  { name: "refund credit", layout: "Refund of <AMT> credited to your card <MASK> for <PARTY>.", answer: ans([mv("credit", "refund", "card", { mask: "mask1", kind: "credit_card", party: "party1" })]) },
  { name: "reversal credit", layout: "Reversal of <AMT> processed and credited to A/c <MASK>.", answer: ans([mv("credit", "reversal", "unknown", { mask: "mask1" })]) },
  { name: "provider receipt (evidenceOnly, 'received')", layout: "Payment of <AMT> received for your <PARTY> recharge. Thank you.", answer: ans([mv("debit", "bill_payment", "unknown", { party: "party1", attrs: { evidenceOnly: true } })]) },
  { name: "sip investment", layout: "Your SIP of <AMT> in <PARTY> was debited from A/c <MASK>.", answer: ans([mv("debit", "investment", "nach", { mask: "mask1", party: "party1" })]) },
  { name: "wrapped amount phrase", layout: "Paid to <PARTY> Rs <AMT> on <DATE>.", answer: ans([mv("debit", "purchase", "upi", { party: "party1", date: "date1" })]) },
  { name: "balance said after the number", layout: "<AMT> debited from A/c <MASK>. <AMT> is your available balance.", answer: ans([mv("debit", "purchase", "unknown", { mask: "mask1" }), bal("amt2")]) },
  { name: "debit and fee, two movements", layout: "<AMT> debited from A/c <MASK>. Fee of <AMT> charged.", answer: ans([mv("debit", "purchase", "unknown", { mask: "mask1" }), mv("debit", "fee", "unknown", { amt: "amt2", mask: "mask1" })]) },
  { name: "autopay mandate ceiling", layout: "AutoPay set for <PARTY> up to <AMT> monthly. UMN <REF>.", answer: ans([{ factType: "mandate", attrs: { phase: "created", merchantName: { from: "party1" } }, amounts: [{ role: "ceiling", from: "amt1", unit: "INR" }], references: { umrn: "ref1" } }]) },
  { name: "ipo block", layout: "<AMT> blocked in A/c <MASK> for IPO application.", answer: ans([{ factType: "hold", attrs: { phase: "placed", purpose: "ipo_asba" }, amounts: [{ role: "held", from: "amt1", unit: "INR" }], instrument: { kind: "bank_account", maskFrom: "mask1" } }]) },
  { name: "points redeemed", layout: "You redeemed <AMT> reward points on <DATE>.", answer: ans([{ factType: "reward", attrs: {}, amounts: [{ role: "points_redeemed", from: "amt1", unit: "POINTS" }] }]) },
  { name: "credit limit raised", layout: "Credit limit on card <MASK> increased to <AMT>.", answer: ans([{ factType: "limit_change", attrs: { reason: "increase" }, amounts: [{ role: "credit_limit", from: "amt1", unit: "INR" }], instrument: { kind: "credit_card", maskFrom: "mask1" } }]) },
  { name: "outstanding balance snapshot", layout: "Outstanding on card <MASK> is <AMT> as of <DATE>.", answer: ans([{ factType: "balance_snapshot", attrs: { asOf: { from: "date1" } }, amounts: [{ role: "outstanding", from: "amt1", unit: "INR" }], instrument: { kind: "credit_card", maskFrom: "mask1" } }]) },
  { name: "mask from a bare number slot", layout: "<AMT> debited from account <REF>.", answer: ans([mv("debit", "purchase", "unknown", { mask: "ref1" })]) },
  { name: "dollar spend that names the currency", layout: "USD <AMT> spent on card <MASK>.", answer: ans([{ factType: "movement", attrs: { direction: "debit", purpose: "purchase", rail: "card" }, amounts: [{ role: "posted", from: "amt1", unit: "USD" }], instrument: { kind: "credit_card", maskFrom: "mask1" } }]) },
];

const mutateOf = (fn) => (answer) => {
  const copy = JSON.parse(JSON.stringify(answer));
  fn(copy);
  return copy;
};
const base = VALID[0];
// [name, change to the correct upi-debit answer, the code the validator must now give]
const WRONG = [
  ["direction flipped on a debited message", (a) => { a.emit[0].attrs.direction = "credit"; }, "direction_conflicts_wording"],
  ["purpose salary on a plain debit", (a) => { a.emit[0].attrs.purpose = "salary"; }, "purpose_unsupported"],
  ["posted amount wired to the Avl Bal slot", (a) => { a.emit[0].amounts[0].from = "amt2"; }, "posted_amount_is_balance"],
  ["balance wired to the debit slot", (a) => { a.emit[1].amounts[0].from = "amt1"; }, "balance_amount_not_balance"],
  ["amount wired to the date slot", (a) => { a.emit[0].amounts[0].from = "date1"; }, "slot_kind_mismatch"],
  ["amount wired to the party slot (never applies on the phone)", (a) => { a.emit[0].amounts[0].from = "party1"; }, "slot_kind_mismatch"],
  ["occurredAt wired to the party slot", (a) => { a.emit[0].occurredAt.from = "party1"; }, "slot_kind_mismatch"],
  ["mask wired to the amount slot", (a) => { a.emit[0].instrument.maskFrom = "amt1"; }, "slot_kind_mismatch"],
  ["name wired to the ref slot", (a) => { a.emit[0].counterparty.nameFrom = "ref1"; }, "slot_kind_mismatch"],
  ["upiRef wired to the date slot", (a) => { a.emit[0].references.upiRef = "date1"; }, "slot_kind_mismatch"],
  ["ceiling role on a movement", (a) => { a.emit[0].amounts[0].role = "ceiling"; }, "amount_role_not_allowed"],
  ["movement with no amount", (a) => { delete a.emit[0].amounts; }, "amount_missing"],
  ["USD on a rupee layout", (a) => { a.emit[0].amounts[0].unit = "USD"; }, "amount_unit_unsupported"],
  ["POINTS on a rupee amount", (a) => { a.emit[0].amounts[0].unit = "POINTS"; }, "amount_unit_unsupported"],
  ["two posted amounts in one fact", (a) => { a.emit[0].amounts.push({ role: "posted", from: "amt2", unit: "INR" }); }, "amount_role_repeated"],
  ["balance posted as a second movement", (a) => { a.emit[1] = { ...a.emit[0], amounts: [{ role: "posted", from: "amt2", unit: "INR" }] }; }, "posted_amount_is_balance"],
  ["date fed to a bill's amount attr", (a) => { a.emit[1] = { factType: "balance_snapshot", attrs: { asOf: { from: "party1" } }, amounts: [{ role: "available_balance", from: "amt2", unit: "INR" }] }; }, "slot_kind_mismatch"],
].map(([name, change, code]) => ({ name, layout: base.layout, answer: mutateOf(change)(base.answer), code }));

module.exports = { VALID, WRONG, DEBIT };
