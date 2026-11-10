#!/usr/bin/env python3
"""Third held-out set: written after every fix, scored once, blind. All invented."""
import json, sys
ACCTS = [("A/c XX8163", "8163"), ("A/c No.11204/XXXXX395", "395"), ("account no XXXXXXXX2057", "2057"), ("A/c 7700XXXX4186", "4186"),
         ("Acct ending 9331", "9331"), ("a/c no. 00456123789", "3789"), ("CA A/c No. 9/CA/XXXX5074", "5074"), ("A/c *6628", "6628")]
AMTS = [("Rs.2,340.00", 234000), ("INR 1,25,000.00", 12500000), ("Rs 60", 6000), ("₹4,00,000", 40000000), ("Rs.999.99", 99999), ("INR 15000", 1500000)]
DATES = ["21/09/2026", "21-Sep-26", "21-09-2026", "2026-09-21", "21 Sep 2026", "21Sep26"]
BALS = ["Rs.31,205.40", "INR 5,60,000.00", "₹1,250", "Rs 88000.00"]
BANKS = ["Sample Peoples Co-op Bank", "SAMPLE ZILLA SAHAKARI BANK", "Sample Payments Bank", "SAMPLE CITIZEN CREDIT SOCIETY"]
SENDERS = ["VD-SMPPCB-S", "AX-SMPZSB-T", "JK-SMPPAY-S", "TDSMPCCSS", "BP-SMPBNK-G"]
P = ["SAMPLE DAIRY", "ANITA S", "SAMPLE BUILDERS", "M/S SAMPLE SEEDS"]
T = [
 ("C01 was X with amt. New balance", "{bank}: Your {acct} was {ed} with {amt} on {date}. New balance {bal}.", "cd"),
 ("C02 pipe separated", "{amt} {ed} | {acct} | {date} | Bal {bal}", "cd"),
 ("C03 Txn Alert: X amt to/from acct", "Txn Alert: {Ed} {amt} {tofrom} {acct} {date}. Clear Bal {bal}", "cd"),
 ("C04 stands X by", "Dear Sir/Madam, your {acct} stands {ed} by {amt} as on {date}.", "cd"),
 ("C05 dash separated", "{acct} - {amt} {ed} on {date}. Avl Bal - {bal}", "cd"),
 ("C06 We have X your acct", "We have {ed} your {acct} with {amt} on {date}. {bank}", "cd"),
 ("C07 added to / deducted from", "{amt} has been {added} your {acct} on {date}. Bal {bal}", "cd"),
 ("C08 IMPS credit/debit of", "IMPS {noun} of {amt} {tofrom} {acct} on {date}. RRN 432198765432", "cd"),
 ("C09 RD installment", "Your {acct} debited {amt} towards RD installment on {date}. Bal {bal}", "d"),
 ("C10 Pension credited", "Pension of {amt} credited to {acct} on {date}. {bank}", "c"),
 ("C11 paid from acct via UPI", "{amt} paid from {acct} to {payee} via UPI on {date}. Ref 432198765432", "d"),
 ("C12 Received amt by NEFT", "Received {amt} in {acct} from {payee} on {date} by NEFT. UTR SMPLN1234567", "c"),
 ("C13 ATM Cash Wdl", "ATM Cash Wdl {amt} from {acct} at SAMPLE NAGAR on {date}. Avl Bal {bal}", "d"),
 ("C14 Chq paid from", "Chq no 654321 for {amt} paid from {acct} on {date}. Bal {bal}", "d"),
 ("C15 By Clg credited in", "By Clg: {amt} credited in {acct} on {date}. Bal {bal}", "c"),
 ("C16 POS txn on card", "POS txn of {amt} at SAMPLE BAZAAR on card XX4321 on {date}.", "D"),
 ("C17 You've spent using card", "You've spent {amt} at SAMPLE CAFE using card ending 4321 on {date}.", "D"),
 ("C18 Hinglish", "{hing}", "cd"),
 ("C19 Loan EMI debited", "Loan EMI of {amt} debited from {acct} on {date}. Bal {bal}", "d"),
 ("C20 Dividend credited", "Dividend of {amt} credited to your {acct} on {date} by SAMPLE LTD.", "c"),
]
rows = []; n = 0
for tid, tmpl, dirs in T:
    for dch in dirs:
        credit = dch == "c"; card = dch == "D"; direction = "credit" if credit else "debit"
        for k in range(4):
            acct, digits = ACCTS[(n * 5 + k * 3) % len(ACCTS)]
            amt, minor = AMTS[(n + k * 5) % len(AMTS)]
            ed = "credited" if credit else "debited"
            date = DATES[(n + k) % len(DATES)]; bal = BALS[(n + k) % len(BALS)]
            hing = ("Aapke %s me %s jama hua on %s. Bal %s" % (acct, amt, date, bal)) if credit else ("Aapke %s se %s nikala gaya on %s. Bal %s" % (acct, amt, date, bal))
            v = dict(acct=acct, amt=amt, date=date, bal=bal, bank=BANKS[(n + k) % len(BANKS)], payee=P[(n + k) % len(P)], ed=ed, Ed=ed.capitalize(),
                     tofrom="to" if credit else "from", noun="credit" if credit else "debit", added="added to" if credit else "deducted from", hing=hing)
            rows.append({"id": "%s|%s|%d" % (tid.split()[0], direction, k), "tmpl": tid, "sender": SENDERS[(n + k) % len(SENDERS)], "body": tmpl.format(**v),
                         "truth": {"direction": direction, "minor": minor, "digits": "4321" if card else digits}})
        n += 1
with open(sys.argv[1], "w") as f:
    for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
NEG = [
 "Your A/c XX8163 would be debited Rs 500 for non-maintenance of balance.",
 "Cheque of Rs 9,000 in favour of SAMPLE DAIRY issued from A/c XX8163 is stopped as requested.",
 "Dear Customer, deposit Rs 2,000 in A/c XX8163 to keep it active.",
 "Loan EMI of Rs 7,200 for A/c XX8163 is due on 05/10/2026.",
 "ATM withdrawal limit for A/c XX8163 is Rs 25,000 per day.",
 "Your A/c XX8163 can be credited with Rs 6,000 under the scheme after eKYC.",
 "Card XX4321: transaction of Rs 4,300 at SAMPLE STORE is on hold. Reply YES to confirm.",
 "Interest of Rs 320 will be credited to A/c XX8163 at quarter end.",
 "Dear Customer, your A/c XX8163 has been debit frozen. Contact branch.",
 "Your request to stop cheque 123456 of Rs 5,000 is accepted.",
 "Rs 3,000 is payable for locker of A/c XX8163 by 30/09/2026.",
 "Auto-debit of Rs 1,499 for SAMPLE OTT failed on A/c XX8163.",
 "Refund of Rs 899 for order 12345 is being processed.",
 "Balance in A/c XX8163 is Rs 12,400 as of 21/09/2026 18:00.",
 "Use UPI from A/c XX8163 and win cashback up to Rs 250.",
 "PIN for card XX4321 generated. Do not share. Txn limit Rs 40,000.",
 "Your SIP of Rs 5,000 in SAMPLE FUND is registered. First debit on 05/10/2026.",
 "Transfer of Rs 10,000 to ANITA S is scheduled for 05/10/2026.",
 "Dear Customer, Rs 15,000 loan top-up is available on A/c XX8163. Give a missed call.",
 "Your A/c XX8163 was not debited for Rs 2,340.00 due to a technical issue.",
]
with open(sys.argv[2], "w") as f:
    for i, b in enumerate(NEG):
        f.write(json.dumps({"id": "NC%02d" % i, "kind": "c", "sender": SENDERS[i % len(SENDERS)], "body": b}) + "\n")
print(len(rows), "set-C messages from", len(T), "layouts;", len(NEG), "set-C lookalikes")
