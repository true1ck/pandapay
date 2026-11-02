import json, re, sys, collections
from datetime import datetime, timedelta
D = sys.argv[1]
msgs = {json.loads(l)["id"]: json.loads(l) for l in open(f"{D}/private/sms_12m.jsonl")}
srv = {json.loads(l)["id"]: json.loads(l) for l in open(f"{D}/private/server_out.jsonl")}
dev = {json.loads(l)["id"]: json.loads(l) for l in open(f"{D}/private/device_out.jsonl")}
def booked_dev(d): return d and d.get("disp") == "sync" and d.get("amount") is not None
def booked_srv(s): return s and s.get("ok") and s.get("amount") is not None
def t(m): return datetime.fromisoformat(m["observedAt"])
def has(m, rx): return re.search(rx, m["body"], re.I) is not None
R = {}
def check(name, rx, should_book):
    ids = [i for i, m in msgs.items() if has(m, rx)]
    sb = [i for i in ids if booked_srv(srv.get(i))]
    db = [i for i in ids if booked_dev(dev.get(i))]
    R[name] = {"messages": len(ids), "server_booked": len(sb), "phone_booked": len(db),
               "server_kinds": dict(collections.Counter(srv[i]["kind"] for i in sb)),
               "phone_kinds": dict(collections.Counter(dev[i]["kind"] for i in db)),
               "server_booked_inr": round(sum(srv[i]["amount"] for i in sb)),
               "phone_booked_inr": round(sum(dev[i]["amount"] for i in db)),
               "should_book": should_book}
check("ipo_upi_block", r"has been blocked by an amount|blocked .*(?:asba|ipo|mandate)", False)
check("ipo_upi_unblock", r"unblocked by an amount|released|unblock", False)
check("ipo_allot_or_debit", r"\bipo\b|allot", None)
check("card_statement", r"statement.*(?:total|due)|total amt due|total of .* or minimum|min(?:imum)? due", False)
check("card_bill_due_reminder", r"payment for your .*credit card .*is due|is due on .*min due|bill amount", False)
check("card_payment_received", r"payment of .* (?:has been )?received (?:on|towards) your .*credit card|received towards your credit card", "transfer only")
check("cred_debits", r"\bcred\b|cred\.club|credclub", "transfer only")
check("amazon_pay_wallet_load", r"amazon pay wall|amazon pay in e|amazonpay wallet", "transfer only")
check("zomato_money", r"zomato money|\bfrom zomato\b.*balance|added to .*balance expires", None)
check("pluxee_wallet", r"pluxee", "spend")
check("reward_points", r"reward points?|\bpoints\b", False)
check("cashback", r"cashback", None)
check("credit_limit", r"credit limit|limit .*(?:enhanc|increas)", False)
check("card_consent_disbursal_offer", r"require consent to continue disbursement|pre-approved|eligible for", False)
check("broker_payable_info", r"payable to you for all trades|fund bal .* securities bal", False)
check("collect_requests", r"has requested money from you", False)
check("otp_with_amount", r"\botp\b|one-time password", False)
check("salary", r"salary", "income")
check("refund", r"refund|reversal|reversed", "refund")
check("failed_declined", r"failed|declined|unsuccessful|insufficient", False)
check("autopay_mandate", r"mandate|autopay|e-?nach|umrn", None)
json.dump(R, sys.stdout, indent=1); print()

# Card bill double count: card-side receipts vs bank-side debits of the same amount within 3 days
recv = [i for i in msgs if has(msgs[i], r"payment of .* (?:has been )?received (?:on|towards) your .*credit card|received towards your credit card") and booked_srv(srv.get(i))]
debits = [i for i in msgs if booked_srv(srv.get(i)) and i not in recv and re.search(r"debited|paid|sent|cred|bill ?pay|bbps", msgs[i]["body"], re.I)]
pairs = 0; pair_inr = 0
for r in recv:
    a = srv[r]["amount"]; tr = t(msgs[r])
    for d in debits:
        if abs(srv[d]["amount"] - a) < 0.01 and abs((t(msgs[d]) - tr).total_seconds()) <= 3 * 86400:
            pairs += 1; pair_inr += a; break
print(json.dumps({"card_payment_receipts_booked": len(recv), "with_matching_bank_debit_within_3_days": pairs, "double_counted_inr": round(pair_inr)}))

# Accounts & cards detected (server fields) vs distinct masks seen in text
acct = collections.Counter(); card = collections.Counter()
for i, s in srv.items():
    if booked_srv(s):
        b = re.sub(r"-[STPG]$", "", msgs[i]["sender"])
        if s.get("acct"): acct[(b, s["acct"])] += 1
        if s.get("card"): card[(b, s["card"])] += 1
print(json.dumps({"server_distinct_accounts": len(acct), "server_distinct_cards": len(card),
                  "accounts": sorted({f"{b}:{a[-2:]}**" for (b, a) in acct}), "cards": sorted({f"{b}:{c[-2:]}**" for (b, c) in card})}))
bad_cards = [c for (b, c) in card if re.fullmatch(r"20\d\d", c or "")]
print(json.dumps({"cards_that_look_like_years": len(bad_cards)}))

# Totals: what today's server would book as spend over 12 months, and how much of it is suspect
spend_ids = [i for i, s in srv.items() if booked_srv(s) and s.get("kind") == "spend"]
tot = sum(srv[i]["amount"] for i in spend_ids)
suspect = [i for i in spend_ids if has(msgs[i], r"statement|total of .* or minimum|amazon pay wall|amazon pay in e|blocked|reward|points")]
print(json.dumps({"server_spend_rows": len(spend_ids), "server_spend_inr": round(tot), "suspect_spend_rows": len(suspect), "suspect_spend_inr": round(sum(srv[i]['amount'] for i in suspect))}))
# Coverage: messages in Finance filter (smsft_fi) that neither parser books nor recognizes
fin = [i for i, m in msgs.items() if m.get("iosFilter") == "smsft_fi"]
neither = [i for i in fin if not booked_srv(srv.get(i)) and not booked_dev(dev.get(i))]
reasons = collections.Counter(srv[i]["reason"] for i in neither)
print(json.dumps({"ios_finance_tagged": len(fin), "not_booked_by_either": len(neither), "server_reasons": reasons.most_common(8)}))
# Phone vs server disagreement on booked amount or kind
dis = collections.Counter()
for i in msgs:
    s, d = srv.get(i), dev.get(i)
    bs, bd = booked_srv(s), booked_dev(d)
    if bs != bd: dis["one_books_other_not"] += 1
    elif bs and bd:
        if abs(s["amount"] - d["amount"]) > 0.01: dis["amount_differs"] += 1
        if s["kind"] != d["kind"]: dis["kind_differs"] += 1
print(json.dumps(dict(dis)))
