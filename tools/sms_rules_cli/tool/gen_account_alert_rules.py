#!/usr/bin/env python3
"""Generates the generalised account-alert rule files. Output goes to rules/sms/v2/generalization/.

Every example body is synthetic (invented names, masks, amounts). Nothing here is copied from a
private message.
"""
import json, sys, os

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
OUT = REPO + "/rules/sms/v2/generalization"

# ---- shared fragments (same shapes the existing GEN/GENZ rules use) ----
RS = r"(?:\b(?:rs\.?|inr)|₹)\s*:?\s*"
def AMT(name): return r"(?<%s>\d[\d,]*(?:\.\d{1,2})?)" % name
DATE = (r"(?<date>\d{4}-\d{2}-\d{2}(?:[: ]\d{2}:\d{2}(?::\d{2})?)?"
        r"|\d{1,2}[-/]\d{1,2}[-/]\d{2,4}(?:,?\s*\d{2}:\d{2}(?::\d{2})?)?"
        r"|\d{1,2}[-/ ]?[a-z]{3}[-/ ,]*\d{2,4}(?:,?\s*\d{2}:\d{2}(?::\d{2})?)?)")
BAL = (r"[\s\S]{0,200}?\b(?:avl|avbl|avail(?:able)?|total\s+avail(?:able)?|clear|current|new|closing|updated|remaining)?"
       r"\.?\s*bal(?:ance)?\.?\s*(?:is|of)?\s*[:\-]?\s*" + RS + AMT("bal"))

# date formats: the list the existing wildcard account rules use
_gen = json.load(open(REPO + "/rules/sms/v2/banks/others.json"))
DATE_FORMATS = next(r for r in _gen if r["id"] == "GEN-ACCT-LAST-C2-B")["emit"][0]["occurredAt"]["formats"]

def movement(direction, purpose, rail, evidence_only=False, counterparty=None, instrument=True, references=None, date=True):
    attrs = {"direction": direction, "purpose": purpose, "rail": rail}
    if evidence_only:
        attrs["evidenceOnly"] = True
    e = {"factType": "movement", "attrs": attrs,
         "amounts": [{"role": "posted", "from": "amt", "unit": "INR"}]}
    if date:
        e["occurredAt"] = {"from": "date", "formats": DATE_FORMATS}
    if instrument:
        e["instrument"] = {"kind": "bank_account", "maskFrom": "mask"}
    if counterparty:
        e["counterparty"] = counterparty
    if references:
        e["references"] = references
    return e

BAL_EMIT = {"factType": "balance_snapshot",
            "amounts": [{"role": "available_balance", "from": "bal", "unit": "INR"}],
            "instrument": {"sameAs": 0},
            "attrs": {"asOf": {"sameAs": 0, "field": "occurredAt"}}}

def rule(id_, family, senders, priority, pattern, emit, confidence, examples, reject=None, require=None, by="cbs-generalization"):
    m = {"pattern": pattern, "flags": "i"}
    if require: m["requireAll"] = require
    if reject: m["rejectAny"] = reject
    return {"id": id_, "version": 1, "family": family, "senders": senders, "priority": priority,
            "match": m, "emit": emit, "confidence": confidence, "examples": examples,
            "status": "active", "createdBy": by, "updatedAt": "2026-11-10T00:00:00Z"}

def ex(body, types, sender="VM-SAMPLEB-S"):
    return {"sender": sender, "body": body, "expectFactTypes": types}

# a condition or a warning quotes an amount without anything having happened
CONDITIONAL = ["if rs", "if inr", "if ₹", "if an amount", "if any amount", "if your a", "if a/c", "in case", "without your consent",
               "unauthoris", "unauthoriz", "beware", "fake"]
COMMON_REJECT = ["fail", "declin", "will be", " otp", "reject", "insufficient", "request", "loan", " emi",
                 "towards", "credit card", "card ending", "mandate", "sip ", "cheque book"] + CONDITIONAL

# =====================================================================================
# Family 1 + 3: account-first alerts
#   "Your A/c No.<branch>/<XXXX123> has been credited|debited by|with Rs X [in TYPE] on DATE [. Info:] by MODE. Available Bal is Rs Y"
# =====================================================================================
ACCT_WORD = r"\b(?:a/?c(?:ct)?\.?|account|acc\.?)(?:\s*(?:no|number|num)\.?)?\s*[:\-]?\s*"
MASK = r"[x*•.]*\s?(?:\d{2,6}[x*•]{2,})?(?<mask>\d{2,18})"
ACCT = ACCT_WORD + r"(?:\d{1,8}\s*/\s*)?" + MASK
# The branch code is required: as printed ("40000/"), or as the engine leaves it once it has blanked it
# (two or more spaces). These rules exist for phones whose engine does not blank the prefix yet; with a
# plain account the richer GEN-ACCT rules read the same wording and must keep winning.
ACCT_BRANCH = ACCT_WORD + r"(?:\d{1,8}\s*/\s*(?:[a-z]{1,4}\s*/\s*)?|\s{2,})" + MASK
def head(verb, acct=None):
    return ((acct or ACCT) + r"\s+(?:has\s+been\s+|is\s+|was\s+)?" + verb + r"\s+(?:by|with|for|of)\s+" + RS + AMT("amt") +
            r"(?:\s*/-)?(?:\s+in\s+[a-z][a-z0-9 ]{0,24}?)?\s+(?:on|dated)\s+" + DATE)
TAIL = r"[\s.,;:\-]*(?:(?:info|narration|remarks|particulars|txn\s+type|mode)\s*[:\-]\s*)?by\s+"
NOMODE = r"(?=[\s.,;:\-]*(?:$|(?:avl|avbl|avail|available|bal|balance|closing|total)\b))"

CR_CLASSES = [  # key, label, rail, purpose, mode pattern, family, priority-bonus, confidence, sample mode text
    ("CASH", "cash", "cash", "p2p", r"(?:cash(?:\s+(?:deposit|dep))?|collection|cdm)\b", "acct_credit", 30, 0.93, "Cash"),
    ("CHQ", "cheque", "cheque", "p2p", r"(?:(?:inward\s+|outward\s+)?clearing|cheque|chq|chk)\b", "acct_credit", 30, 0.92, "Clearing Cheque No 123456"),
    ("NEFT", "NEFT", "neft", "p2p", r"neft\b", "neft_credit", 30, 0.93, "NEFT"),
    ("RTGS", "RTGS", "rtgs", "p2p", r"rtgs\b", "rtgs_credit", 30, 0.93, "RTGS"),
    ("IMPS", "IMPS", "imps", "p2p", r"imps\b", "imps_credit", 30, 0.93, "IMPS"),
    ("UPI", "UPI", "upi", "p2p", r"upi\b", "upi_credit", 30, 0.93, "UPI"),
    ("INT", "interest", "unknown", "interest", r"(?:interest|int(?:\.|\s+)?(?:pd|paid|cr|credit)?)\b", "interest", 30, 0.92, "Interest"),
    ("SAL", "salary", "unknown", "salary", r"salary\b", "salary", 30, 0.92, "Salary"),
    ("REV", "reversal or return", "unknown", "reversal", r"(?:reversal|reversed|return(?:ed)?|refund(?:ed)?)\b", "reversal", 30, 0.9, "Reversal"),
    ("TRF", "transfer", "unknown", "transfer", r"(?:transfer(?:\s+entry)?|trf|tfr|standing\s+instruction|deposit|dd|pay\s*order)\b", "acct_credit", 10, 0.9, "Transfer"),
]
DB_CLASSES = [
    ("CASH", "cash withdrawal", "cash", "atm", r"(?:cash(?:\s+withdrawal)?|withdrawal|withdrawl|self(?:\s+cheque)?|cwd)\b", "atm", 30, 0.92, "Cash"),
    ("CHQ", "cheque", "cheque", "purchase", r"(?:(?:inward\s+|outward\s+)?clearing|cheque|chq|chk)\b", "cheque", 30, 0.92, "Clearing Cheque No 123456"),
    ("NEFT", "NEFT", "neft", "p2p", r"neft\b", "neft_debit", 30, 0.93, "NEFT"),
    ("RTGS", "RTGS", "rtgs", "p2p", r"rtgs\b", "rtgs_debit", 30, 0.93, "RTGS"),
    ("IMPS", "IMPS", "imps", "p2p", r"imps\b", "imps_debit", 30, 0.93, "IMPS"),
    ("UPI", "UPI", "upi", "p2p", r"upi\b", "upi_debit", 30, 0.93, "UPI"),
    ("TRF", "transfer", "unknown", "transfer", r"(?:transfer(?:\s+entry)?|trf|tfr|standing\s+instruction|dd|pay\s*order)\b", "acct_debit", 10, 0.9, "Transfer"),
]

BRANCH_ONLY = {("CR", k) for k in ("NEFT", "RTGS", "IMPS", "UPI", "INT", "SAL", "REV")} | {("DB", k) for k in ("CHQ", "NEFT", "RTGS", "IMPS", "UPI")}

def acct_rules():
    out = []
    for direction, verb, classes, word in (("credit", "(?:credited|deposited)", CR_CLASSES, "credited"),
                                           ("debit", "debited", DB_CLASSES, "debited")):
        tag = "CR" if direction == "credit" else "DB"
        for key, label, rail, purpose, mpat, fam, bonus, conf, sample in classes:
            for balance in (True, False):
                # The richer GEN-ACCT rules already read "by NEFT / UPI / cheque / salary ..." for a plain
                # account. These classes take the wording only when a branch code is printed, which those
                # rules cannot read on a phone whose engine does not blank it.
                branch_only = (tag, key) in BRANCH_ONLY
                pat = head(verb, ACCT_BRANCH if branch_only else None) + TAIL + mpat
                emit = [movement(direction, purpose, rail)]
                if balance:
                    pat += BAL
                    emit.append(BAL_EMIT)
                    body = "Your A/c No.12345/XXXXX678 has been %s by Rs.2500.00 on 14/08/2026 by %s. Available Bal is Rs.52500.50. SAMPLE DISTRICT CO-OP BANK LTD" % (word, sample)
                    types = ["movement", "balance_snapshot"]
                else:
                    body = "Your A/c No.12345/XXXXX678 has been %s by Rs.2500.00 on 14/08/2026 by %s." % (word, sample)
                    types = ["movement"]
                neg = "Your A/c No.12345/XXXXX678 will be %s by Rs.2500.00 on 14/08/2026 by %s. Available Bal is Rs.52500.50." % (word, sample)
                out.append(rule("CBS-ACCT-%s-%s%s" % (tag, key, "-B" if balance else ""), fam, ["*"],
                                ((452 if key == "SAL" else 328) if branch_only else 190 + bonus) + (5 if balance else 0), pat, emit, conf,
                                [ex(body, types), ex(neg, [])], reject=COMMON_REJECT))
        # no stated mode at all: still a real movement; typed as a transfer (money in / money out)
        for balance in (True, False):
            pat = head(verb) + NOMODE
            emit = [movement(direction, "transfer", "unknown")]
            body = "Dear Customer, Your A/c 8412 has been %s with INR 1,250.00 in SAVING On 03-Sep-24." % word
            types = ["movement"]
            if balance:
                # a balance must follow; the NOMODE lookahead already allows it
                pat = head(verb) + r"[\s.,;:\-]*" + BAL[len(r"[\s\S]{0,200}?"):]
                emit.append(BAL_EMIT)
                body += " Avbl Bal is INR 9,000.00."
                types = ["movement", "balance_snapshot"]
            out.append(rule("CBS-ACCT-%s-NOMODE%s" % (tag, "-B" if balance else ""),
                            "acct_credit" if direction == "credit" else "acct_debit", ["*"],
                            195 + (5 if balance else 0), pat, emit, 0.8,
                            [ex(body, types), ex(body.replace("has been", "will be"), [])], reject=COMMON_REJECT))
    return out

# =====================================================================================
# Family 5: label-first alerts ("Account No. 1234 CREDIT with amount Rs X on DATE. Balance: Rs Y")
# =====================================================================================
LABEL = (r"\baccount\s+(?:no|number|num)\.?\s*[x*•.]*\s?(?:\d{2,6}[x*•]{2,})?(?<mask>\d{2,18})\s+(?:%s)\s+with\s+amount\s+" + RS + AMT("amt") +
         r"\s+on\s+" + DATE)
def label_rules():
    out = []
    for direction, word, purpose in (("credit", "credit", "p2p"), ("debit", "debit", "transfer")):
        tag = "CR" if direction == "credit" else "DB"
        for balance in (True, False):
            pat = LABEL % word
            emit = [movement(direction, purpose, "unknown")]
            body = "Account  No. XXXXXX3456 %s with amount Rs. 1800.00 on 27-10-2026." % word.upper()
            types = ["movement"]
            if balance:
                pat += r"\.?\s*balance\s*:\s*" + RS + AMT("bal")
                emit.append(BAL_EMIT)
                body += " Balance: Rs.9800.00. [IN0000003]"
                types = ["movement", "balance_snapshot"]
            neg = "Account No. XXXXXX3456 %s FAILED for amount Rs. 1800.00 on 27-10-2026." % word.upper()
            out.append(rule("LBL-ACCT-%s%s" % (tag, "-B" if balance else ""), "acct_credit" if direction == "credit" else "acct_debit",
                            ["*"], 215 + (5 if balance else 0), pat, emit, 0.92 if balance else 0.9,
                            [ex(body, types, "BT-SAMPLEP-G"), ex(neg, [])], reject=["fail", "declin", "will be"] + CONDITIONAL))
    # India Post Payments Bank: the older IPPB-ACCT-DEBIT leaves the purpose "unknown", which the ledger does not
    # count. A new id (existing ids are never replaced by an import) at a higher priority supersedes it.
    pat = LABEL % "debit" + r"\.?\s*balance\s*:\s*" + RS + AMT("bal")
    out.append(rule("IPPB-ACCT-DEBIT-COUNTED", "acct_debit", ["DOPBNK", "IPPBMS"], 712, pat,
                    [movement("debit", "transfer", "unknown"), BAL_EMIT], 0.93,
                    [ex("Account No. XXXXXXXX3456 DEBIT with amount Rs. 900.00 on 29-07-2026. Balance: Rs.514.00.[IN0000004]",
                        ["movement", "balance_snapshot"], "BT-DOPBNK-G"),
                     ex("Account No. XXXXXXXX3456 DEBIT FAILED for amount Rs. 900.00 on 29-07-2026.", [], "DOPBNK-S")],
                    reject=["fail", "declin"]))
    return out

# =====================================================================================
# Family 2: "NEFT/RTGS/IMPS Txn of Rs X has been sent to IFSC-ACCOUNT-NAME with Ref no: REF"
#   a second notice for a payment the bank also reports as a debit: evidence only
# =====================================================================================
def sent_rules():
    out = []
    rails = [("COMBO", r"(?:neft\s*/\s*rtgs|rtgs\s*/\s*neft)", "unknown", 352, "NEFT/RTGS", "txnId"),
             ("NEFT", r"neft", "neft", 350, "NEFT", "neftUtr"), ("RTGS", r"rtgs", "rtgs", 350, "RTGS", "rtgsUtr"),
             ("IMPS", r"imps", "imps", 350, "IMPS", "impsRef")]
    for key, rpat, rail, prio, sample, refkey in rails:
        pat = (r"\b" + rpat + r"\s+(?:txn|transaction|transfer|payment|remittance)\s+of\s+" + RS + AMT("amt") +
               r"\s+(?:has\s+been\s+|is\s+|was\s+)?(?:successfully\s+)?(?:sent|transferred|remitted)\s+to\s+"
               r"(?:(?<ifsc>[a-z]{4}0[a-z0-9]{6})\s*-\s*)?(?:(?<bpre>[a-z0-9]{1,26}?)(?<bacc>\d{4})\s*-\s*)?"
               r"(?<payee>[a-z][a-z0-9 .&'/()-]{1,60}?)\s+(?:with|vide|having)\s+(?:ref(?:erence)?|utr|txn|transaction)\b"
               r"\s*(?:no\.?|number|id)?\s*[:\-]?\s*(?<ref_%s>[a-z0-9]{6,30})" % refkey)
        cp = {"nameFrom": "payee", "transforms": ["sanitizeNarration"], "accountMaskFrom": "bacc"}
        body = "Your %s Txn of Rs.25000 has been sent to SAMP0000123-CURR000123456-SAMPLE TRADERS with Ref no: SAMP52026110100001  THE SAMPLE DISTRICT CO-OPERATIVE BANK LTD" % sample
        out.append(rule("NEFT-SENT-NOTICE-" + key, "bill_receipt", ["*"], prio, pat,
                        [movement("debit", "p2p", rail, evidence_only=True, counterparty=cp, instrument=False, date=False)],
                        0.9,
                        [ex(body, ["movement"], "VA-SDCCBK-S"),
                         ex(body.replace("has been sent", "could not be sent"), [])],
                        reject=["fail", "declin", "reject", "return", "revers", "will be", "pending", "initiated"]))
    return out

# =====================================================================================
# Family 4: SBI-style "Your A/C XXXXX1234 has credit|debit for <DESCRIPTION> of Rs X on DATE. Avl Bal Rs Y"
# =====================================================================================
SBI_HEAD = (r"\ba/?c\s*[x*•.]*\s?(?:\d{2,6}[x*•]{2,})?(?<mask>\d{2,18})\s+has\s+%s\s+for\s+(?<desc>%s)\s+of\s+" + RS + AMT("amt") + r"\s+on\s+" + DATE)
def kw(words): return r"[^\n]{0,60}?(?:%s)[^\n]{0,60}?" % words
SBI_CR = [  # key, desc pattern, purpose, rail, prio, confidence, sample desc
    # the tax words may be glued to other letters ("ITDTAX"), so they carry no trailing word boundary
    ("TAX", kw(r"\bitd|tax|\btds\b"), "tax", "unknown", 225, 0.92, "ITDTAX REFUND 2026-27 ACRPN123"),
    ("REFUND", kw(r"\b(?:refund|reversal|reversed|return(?:ed)?)\b"), "refund", "unknown", 224, 0.9, "REFUND FROM SAMPLE SHOP"),
    ("SAL", kw(r"\b(?:salary|payroll)\b"), "salary", "unknown", 223, 0.92, "SALARY SAMPLE PRIVATE LTD"),
    ("DIV", kw(r"\b(?:dividend|divd|div)\b"), "dividend", "unknown", 222, 0.92, "SAMPLE POWER CO FINAL DIVIDEND"),
    ("ANY", r"[^\n]{1,100}?", "p2p", "unknown", 210, 0.85, "TRANSFER FROM SAMPLE PERSON"),
]
SBI_DB = [
    ("ATM", kw(r"\b(?:atm|nfs|cash\s+(?:wdl|withdrawal))\b"), "atm", "cash", 225, 0.92, "ATM WDL SAMPLE BRANCH"),
    ("POS", kw(r"\b(?:pos|ecom|purchase|swipe)\b"), "purchase", "card", 224, 0.88, "POS SAMPLE SHOP"),
    ("ANY", r"[^\n]{1,100}?", "transfer", "unknown", 210, 0.85, "TRANSFER TO SAMPLE PERSON"),
]
def sbi_rules():
    out = []
    for direction, verb, classes, word in (("credit", "credit", SBI_CR, "credit"), ("debit", "debit", SBI_DB, "debit")):
        tag = "CR" if direction == "credit" else "DB"
        for key, dpat, purpose, rail, prio, conf, sample in classes:
            for balance in (True, False):
                pat = SBI_HEAD % (verb, dpat)
                emit = [movement(direction, purpose, rail)]
                body = "Your A/C XXXXX123456 has %s for %s of Rs 1,250.00 on 29/10/26." % (word, sample)
                types = ["movement"]
                if balance:
                    pat += BAL
                    emit.append(BAL_EMIT)
                    body += " Avl Bal Rs 1,04,079.26.-BANK"
                    types = ["movement", "balance_snapshot"]
                neg = body.replace("has %s for" % word, "has %s failed for" % word)
                out.append(rule("SBI-STYLE-%s-%s%s" % (tag, key, "-B" if balance else ""),
                                {"credit": "bank_credit", "debit": "acct_debit"}[direction], ["*"],
                                prio + (5 if balance else 0), pat, emit, conf,
                                [ex(body, types, "BG-SAMPLEB-S"), ex(neg, [])],
                                reject=["fail", "declin", "will be"] + CONDITIONAL + (["upi/"] if key == "ANY" else [])))
    return out

# =====================================================================================
# Family 6: insurer / biller payment thank-you ("We thank you for your payment of Rs X towards your Policy Number N ...")
# =====================================================================================
def thanks_rules():
    pat = (r"\bthank\s+you\s+for\s+(?:your\s+|the\s+)?(?:premium\s+)?(?:payment|remittance)\s+of\s+" + RS + AMT("amt") +
           r"\s+(?:towards|for|against)\s+(?:your\s+)?(?:[a-z]{1,15}\s)?(?:[a-z]{1,15}\s)?(?:policy|premium)\b"
           r"(?:[\s\S]{0,300}?\b(?:regards|sincerely)[,:\s-]{0,5}(?<biller>[a-z][a-z .&'-]{3,60}?)\s{0,5}$)?")
    body = ("We thank you for your payment of Rs. 4500.00 towards your Policy Number 000123456. You can now download "
            "your premium receipt any time anywhere by clicking to https://example.invalid/r/abc Regards, Sample Life Insurance")
    return [rule("GENZ-INS-PAYMENT-THANKS", "bill_receipt", ["*"], 552, pat,
                 [movement("debit", "bill_payment", "unknown", evidence_only=True, instrument=False, date=False,
                           counterparty={"nameFrom": "biller", "transforms": ["upperTrim"]})],
                 0.9,
                 [ex(body, ["movement"], "CP-SAMPLEI-S"),
                  ex("We thank you for your payment of Rs. 4500.00 towards your Policy Number 000123456 regards Sample Life Insurance. Your payment failed.", [])],
                 reject=["not received", "failed", "bounced", "dishonour", " due"])]

def dump(name, rules):
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rules, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(name, len(rules))

if __name__ == "__main__":
    dump("account_alerts_account_first.json", acct_rules())
    dump("account_alerts_label_first.json", label_rules())
    dump("neft_sent_notices.json", sent_rules())
    dump("sbi_style_has_credit_for.json", sbi_rules())
    dump("payment_thanks_receipts.json", thanks_rules())


# =====================================================================================
# Typed replacements for rules that read a movement but left its purpose "unknown".
# The ledger never counts an unknown purpose and, at these confidences, never asks either, so the money
# simply went missing. An import adds new rule ids and never replaces an existing one, so each replacement is
# a new id one priority step above the rule it retires. Run AFTER the files above are written.
# =====================================================================================
import copy, glob, re
OLD_TOKEN = (r"(?:your\s+)?a/?c(?:ct)?\.?(?:\s*(?:no|number|num)\.?)?(?:\s+(?:ending|ends)(?:\s+(?:with|in))?)?\s*[:\-]?\s*"
             r"[x*•.]*\s?(?<mask>\d{2,18})")
# also: "SB A/c", "account", a branch code, and "Rs.3500/-"
NEW_TOKEN = (r"(?:your\s+)?(?:[a-z]{2,4}\s+)?(?:a/?c(?:ct)?\.?|account)(?:\s*(?:no|number|num)\.?)?(?:\s+(?:ending|ends)(?:\s+(?:with|in))?)?\s*[:\-]?\s*"
             r"(?:\d{1,8}\s*/\s*)?[x*•.]*\s?(?:\d{2,6}[x*•]{2,})?(?<mask>\d{2,18})")
OLD_AMT = r"(?<amt>\d[\d,]*(?:\.\d{1,2})?)\s+"
NEW_AMT = r"(?<amt>\d[\d,]*(?:\.\d{1,2})?)(?:\s*/-)?\s+"
TYPED = {  # old id -> (new id, purpose)
    "ICICI-ACCT-DEBIT-CHEQUE-CLEARING": ("ICICI-ACCT-DEBIT-CHEQUE-CLEARING-COUNTED", "purchase"),
    "SBI-ACCOUNT-UPI-CREDIT-FOR": ("SBI-ACCOUNT-UPI-CREDIT-FOR-COUNTED", "p2p"),
    "IPPB-ACCT-CREDIT": ("IPPB-ACCT-CREDIT-COUNTED", "p2p"),
}
for side, word in (("CR", "credit"), ("DR", "debit")):
    for rail in ("IMPS", "NEFT", "RTGS", "UPI", "PLAIN"):
        for b in ("", "-B"):
            purpose = "transfer" if rail == "PLAIN" else ("purchase" if (rail == "UPI" and side == "DR") else "p2p")
            TYPED["GENZ-ACCT-%s-ABBREV-%s%s" % (side, rail, b)] = ("ABBR-ACCT-%s-%s%s" % (side, rail, b), purpose)

def typed_supersedes():
    new_rules, touched = [], {}
    for path in sorted(glob.glob(REPO + "/rules/sms/v2/**/*.json", recursive=True)):
        if "/senders/" in path or path.endswith(("typed_replacements.json",)):
            continue
        raw = open(path, encoding="utf-8").read()
        try: data = json.loads(raw)
        except Exception: continue
        if not isinstance(data, list): continue
        changed = False
        for r in data:
            if not isinstance(r, dict) or r.get("id") not in TYPED: continue
            new_id, purpose = TYPED[r["id"]]
            n = copy.deepcopy(r)
            n["id"] = new_id; n["version"] = 1; n["status"] = "active"; n["priority"] = r["priority"] + 1
            n["createdBy"] = "cbs-generalization"; n["updatedAt"] = "2026-11-10T00:00:00Z"
            for e in n["emit"]:
                if e["factType"] == "movement" and e["attrs"].get("purpose") == "unknown":
                    e["attrs"]["purpose"] = purpose
            if r["id"].startswith("GENZ-ACCT-"):
                p = n["match"]["pattern"]
                assert OLD_TOKEN in p and OLD_AMT in p, r["id"]
                n["match"]["pattern"] = p.replace(OLD_TOKEN, NEW_TOKEN).replace(OLD_AMT, NEW_AMT, 1)
            new_rules.append(n)
            if r.get("status") != "retired":
                r["status"] = "retired"; r["version"] = r.get("version", 1) + 1; r["updatedAt"] = "2026-11-10T00:00:00Z"; changed = True
        if changed:
            open(path, "w", encoding="utf-8").write(json.dumps(data, indent=2, ensure_ascii=False) + ("\n" if raw.endswith("\n") else ""))
            touched[path] = True
    assert len(new_rules) == len(TYPED), (len(new_rules), len(TYPED))
    return sorted(new_rules, key=lambda r: r["id"])

# "Rs X has been debited from your A/c N [on DATE]" with nothing after it that names a payee or a rail. The broker
# rule BRK-DEMAT-NSDL-DEBIT-01 (priority 520, any sender) reads this wording as a share movement and drops it;
# this sits just above it. Wording that names a payee, a rail or a purpose is left to the richer rules below.
NOTHING_MORE = r"(?![\s.,;:\-]*(?:to|towards|for|at|via|by|thru|through|using|info|ref|upi|neft|imps|rtgs|vpa|and|against)\b)"

def amount_first_rules():
    out = []
    tok = (r"(?:[a-z]{2,4}\s+)?(?:a/?c(?:ct)?\.?|account)(?:\s*(?:no|number|num)\.?)?(?:\s+(?:ending|ends)(?:\s+(?:with|in))?)?\s*[:\-]?\s*"
           r"(?:\d{1,8}\s*/\s*)?[x*•.]*\s?(?:\d{2,6}[x*•]{2,})?(?<mask>\d{2,18})(?!\d)")
    core = (RS + AMT("amt") + r"(?:\s*/-)?\s+(?:has\s+been\s+|is\s+|was\s+)?debited\s+from\s+your\s+" + tok +
            # Nothing that names a payee, a rail or a purpose may follow, with or without a date. Written as two
            # branches because an optional date followed by one check lets the pattern skip the date to dodge it.
            r"(?:\s+(?:on|dated)\s+" + DATE + NOTHING_MORE + r"|(?!\s+(?:on|dated)\s)" + NOTHING_MORE + r")")
    for balance in (True, False):
        pat = core
        emit = [movement("debit", "transfer", "unknown")]
        body = "Dear Customer, Rs 12,500.00 has been debited from your A/c XX1234 on 14/08/26."
        types = ["movement"]
        if balance:
            pat += BAL; emit.append(BAL_EMIT); body += " Avl Bal INR 1,04,079.26. SAMPLE CO-OP BANK"; types = ["movement", "balance_snapshot"]
        out.append(rule("AMTF-ACCT-DB-FROM-YOUR%s" % ("-B" if balance else ""), "acct_debit", ["*"], 521 + (5 if balance else 0), pat, emit, 0.85,
                        [ex(body, types), ex(body.replace("has been debited", "will be debited"), [])],
                        reject=["fail", "declin", "will be", " otp", "reject", "insufficient", "request", "loan", " emi", "nsdl", "cdsl", "shares", "units", "mandate"] + CONDITIONAL))
    return out

if __name__ == "__main__":
    dump("typed_replacements.json", typed_supersedes())
    dump("amount_first_plain_debit.json", amount_first_rules())
