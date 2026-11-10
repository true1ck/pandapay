#!/usr/bin/env python3
"""Held-out generalisation corpus: account alerts in wordings and layouts that no rule in this change was written for.
Every value is invented. Each row carries the right answer (direction, amount, account digits)."""
import json, itertools, random, sys
random.seed(7)
ACCTS = [  # (text, digits the reader should end with)
    ("A/c No.40000/XXXXX731", "731"), ("A/c XXXXX731", "731"), ("A/c XX1234", "1234"), ("A/c no. XXXXXXXX5678", "5678"),
    ("A/c 12345678901", "8901"), ("a/c *4321", "4321"), ("A/c No 021/XXXX2468", "2468"), ("Acct XX9087", "9087"),
    ("account ending 6543", "6543"), ("A/C NO.XXXXXX3390", "3390"), ("SB A/c XXXX7712", "7712"), ("A/c 12XXXXXX89", "89"),
    ("A/c No.00123/CA/XXXX4410", "4410"), ("A/c ...1357", "1357"),
]
AMTS = [("Rs.5000.00", 500000), ("Rs 12,500.00", 1250000), ("INR 2,50,000.00", 25000000), ("₹750", 75000), ("Rs.400000", 40000000), ("Rs. 99.50", 9950), ("INR 1,00,000", 10000000), ("Rs.3500/-", 350000)]
DATES = ["14/08/2026", "14-08-2026", "14-Aug-26", "14Aug26", "14-Aug-2026", "14/08/26", "2026-08-14", "14 Aug 2026"]
BALS = ["Rs.52500.50", "INR 1,04,079.26", "Rs 9,800.00", "₹25,000"]
BANKS = ["SAMPLE DISTRICT CENTRAL CO-OP BANK LTD", "Sample Urban Co-op Bank", "SAMPLE GRAMIN BANK", "Sample Sahakari Bank Ltd", "-Sample Bank"]
SENDERS = ["VM-SMPLCB-S", "AD-SMPUCB-T", "JX-SMPGRB-S", "VASMPSHKS", "BT-SMPBNK-G"]
# templates: (id, direction-aware text with {acct} {amt} {date} {bal} {bank}, mine?)  V=verb slots
T = [
 # ---- account first ----
 ("AF01 has been X by .. on .. by Transfer + bal", "Your {acct} has been {ed} by {amt} on {date} by Transfer. Available Bal is {bal}. {bank}"),
 ("AF02 is X with .. on .. Avl Bal", "Your {acct} is {ed} with {amt} on {date}. Avl Bal {bal}. {bank}"),
 ("AF03 bare: X amt on date. Bal", "{acct} {ed} {amt} on {date}. Bal: {bal}"),
 ("AF04 Dear Customer account has been X with", "Dear Customer, your {acct} has been {ed} with {amt} on {date}. Balance is {bal}."),
 ("AF05 X INR on date -desc. Avl Bal", "Your {acct} {Ed} {amt} on {date} -{desc}. Avl Bal {bal}."),
 ("AF06 X for amt on date mode", "{bank}: {acct} {ed} for {amt} on {date} {mode}. Avl Bal {bal}"),
 ("AF07 X with amt on date. Info: desc", "{acct} {ed} with {amt} on {date}. Info: {desc}. Avl Bal {bal}"),
 ("AF08 has a credit/debit of", "Transaction alert: Your {acct} has a {noun} of {amt} on {date}. Bal {bal}"),
 ("AF09 X by amt Total Bal CR", "Your {acct} {ed} by {amt} Total Bal : {bal} CR Clr Bal : {bal} CR. {bank}"),
 ("AF10 Dear Member X by amt dtd", "Dear Member, your {acct} is {ed} by {amt} dtd {date}. Bal {bal}. {bank}"),
 ("AF11 CAPS X BY amt ON date BY mode/narr", "{ACCT} {ED} BY {amt} ON {date} BY {MODE}/SAMPLE NARRATION. BAL {bal}"),
 ("AF12 X with amt on date through mode", "Your {acct} has been {ed} with {amt} on {date} through {mode}. Clear Balance {bal}"),
 ("AF13 acct: amt Cr/Dr on date", "{bank} {acct}: {amt} {crdr} on {date}. Balance {bal}"),
 ("AF14 X towards desc", "Your {acct} has been {ed} by {amt} towards {desc} on {date}. Avl Bal {bal}"),
 ("AF15 X by amt on date (no mode, no bal)", "Your {acct} has been {ed} by {amt} on {date}."),
 ("AF16 X by amt (no date)", "Your {acct} has been {ed} by {amt}. Available Balance is {bal}. {bank}"),
 ("AF17 X by amt on date at time", "Your {acct} has been {ed} by {amt} on {date} at 10:15:20. Avl Bal: {bal}"),
 ("AF18 X amt via mode ref", "{acct} {ed} {amt} via {mode} Ref 432112345678 on {date}. Bal {bal}"),
 ("AF19 is X by amt on date by Cash", "Your {acct} is {ed} by {amt} on {date} by Cash. Bal is {bal}. {bank}"),
 ("AF20 X by amt on date by Clearing", "Your {acct} has been {ed} by {amt} on {date} by Clearing. Available Bal is {bal}."),
 # ---- amount first ----
 ("AM01 amt X to/from acct on date", "{amt} {ed} {tofrom} {acct} on {date}. Avl Bal {bal}"),
 ("AM02 amt has been X to/from your acct", "Dear Customer, {amt} has been {ed} {tofrom} your {acct} on {date}. Avl Bal {bal}. {bank}"),
 ("AM03 An amount of amt has been X", "An amount of {amt} has been {ED} {tofrom} your {acct} on {date}. Total Avail.bal {bal}"),
 ("AM04 amt is X to/from acct by mode", "Dear Customer, {amt} is {ed} {tofrom} {acct} on {date} by {mode}."),
 ("AM05 amt deposited/withdrawn", "{amt} {depwd} your {acct} on {date}. Avl Bal {bal}"),
 ("AM06 amt X thru mode", "{amt} {Ed} {tofrom} your {acct} on {date} thru {mode}. Bal {bal}"),
 ("AM07 Cash deposit/withdrawal of amt", "Cash {cashnoun} of {amt} {inof} {acct} on {date}. Bal {bal}"),
 ("AM08 Deposit/Withdrawal of amt made", "{Cashnoun} of {amt} made {inof} your {acct} on {date}."),
 ("AM09 Txn of amt done", "Txn of {amt} {ed} {tofrom} {acct} on {date}. Avl Bal {bal}"),
 ("AM10 amt Cr/Dr to acct", "{amt} {crdr}. {tofrom} {acct} on {date}. Avl Bal {bal}. {bank}"),
]
DESCS = ["SAMPLE TRADERS", "TRANSFER FROM SAMPLE PERSON", "NEFT SAMPLE CORP", "BY CASH", "CHQ 123456"]
def render(tid, tmpl, direction, acct, amt, date, bal, bank, mode):
    credit = direction == "credit"
    ed = "credited" if credit else "debited"
    v = dict(acct=acct, ACCT=acct.upper(), amt=amt, date=date, bal=bal, bank=bank, mode=mode, MODE=mode.upper(), ed=ed, Ed=ed.capitalize(), ED=ed.upper(),
             noun="credit" if credit else "debit", crdr="Cr" if credit else "Dr", tofrom="to" if credit else "from",
             depwd="deposited in" if credit else "withdrawn from", cashnoun="deposit" if credit else "withdrawal",
             Cashnoun="Deposit" if credit else "Withdrawal", inof="in" if credit else "from", desc=random.choice(DESCS))
    return tmpl.format(**v)
rows = []
n = 0
for tid, tmpl in T:
    for direction in ("credit", "debit"):
        # 6 deterministic samples per template and direction
        for k in range(6):
            acct, digits = ACCTS[(n * 5 + k * 3) % len(ACCTS)]
            amt, minor = AMTS[(n + k * 3) % len(AMTS)]
            date = DATES[(n + k) % len(DATES)]
            bal = BALS[(n + k) % len(BALS)]
            bank = BANKS[(n + k) % len(BANKS)]
            mode = ["NEFT", "IMPS", "UPI", "RTGS", "Transfer"][(n + k) % 5]
            sender = SENDERS[(n + k) % len(SENDERS)]
            body = render(tid, tmpl, direction, acct, amt, date, bal, bank, mode)
            rows.append({"id": "%s|%s|%d" % (tid.split()[0], direction, k), "tmpl": tid, "sender": sender, "body": body,
                         "truth": {"direction": direction, "minor": minor, "digits": digits, "acct": acct}})
        n += 1
with open(sys.argv[1], "w") as f:
    for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
print(len(rows), "held-out messages from", len(T), "layouts")
