#!/usr/bin/env python3
"""Second held-out set, written after the fixes and scored blind. New layouts, UPI and card alerts. All invented."""
import json, random, sys
random.seed(11)
ACCTS = [("A/c XX5521", "5521"), ("A/c No.30021/XXXXX846", "846"), ("account XXXXXX7783", "7783"), ("A/c no 4455XXXX9012", "9012"),
         ("Ac XX3141", "3141"), ("A/C 00998877665", "7665"), ("a/c ending 2718", "2718"), ("SB A/c No. 117/SB/XXXX6602", "6602"),
         ("Acct *9090", "9090"), ("A/c ...4242", "4242")]
AMTS = [("Rs.1,499.00", 149900), ("INR 75,000.00", 7500000), ("Rs 250", 25000), ("₹3,20,000", 32000000), ("Rs.18.75", 1875), ("INR 6000", 600000), ("Rs. 4,00,000.00", 40000000)]
DATES = ["03/09/2026", "03-Sep-26", "03-09-26", "2026-09-03", "03 Sep 2026", "03Sep26", "03.09.2026"]
BALS = ["Rs.10,250.75", "INR 2,03,400.00", "₹980", "Rs 45000.00"]
BANKS = ["Sample Mercantile Co-op Bank", "SAMPLE NAGARI SAHAKARI BANK", "Sample Small Finance Bank", "SAMPLE REGIONAL RURAL BANK"]
SENDERS = ["VK-SMPMCB-S", "BZ-SMPNSB-T", "JD-SMPSFB-S", "CPSMPRRBS", "TM-SMPBNK-S"]
P = ["SAMPLE STORES", "RAVI K", "SAMPLE ENTERPRISES", "M/S SAMPLE AGRO"]
T = [  # (id, text, directions)
 ("B01 is X INR amt on date. Current balance", "Your {acct} is {ed} {amt} on {date}. Current balance is {bal}.", "cd"),
 ("B02 Alert: amt has been X in your account", "{bank} Alert: {amt} has been {ed} {infrom} your {acct} on {date}.", "cd"),
 ("B03 key-value", "Amt {ed}: {amt}; {acct}; Date: {date}; Bal: {bal}", "cd"),
 ("B04 a sum of amt is X", "Dear Customer, a sum of {amt} is {ed} {tofrom} {acct} on {date}.", "cd"),
 ("B05 X by amt date time (no 'on')", "{acct} {ed} by {amt} {date} 14:22:10. Avbl Bal {bal}", "cd"),
 ("B06 Money Received", "Money Received - {amt} in your {acct} on {date} from {payee}. Bal {bal}", "c"),
 ("B07 Money Sent", "Money Sent - {amt} from {acct} on {date} to {payee}. Ref 432198765432", "d"),
 ("B08 withdrawn at ATM", "{amt} withdrawn at ATM from {acct} on {date}. Avl bal {bal}", "d"),
 ("B09 Salary credited", "Salary of {amt} credited to {acct} on {date}. {bank}", "c"),
 ("B10 Interest credited", "Interest of {amt} credited to your {acct} for the quarter. Bal {bal}", "c"),
 ("B11 debited towards cheque", "Your {acct} is debited with {amt} towards cheque no 123456 on {date}.", "d"),
 ("B12 NACH debit of", "NACH debit of {amt} from {acct} for {payee} on {date}.", "d"),
 ("B13 Transfer of amt successful", "Transfer of {amt} from {acct} to {payee} successful on {date}. UTR SMPL123456789012", "d"),
 ("B14 amt received in acct via IMPS", "{amt} received in {acct} from {payee} via IMPS on {date}. Ref 432198765432", "c"),
 ("B15 Thank you ... is X by", "Thank you for banking with us. Your {acct} is {ed} by {amt} on {date}. Avl Bal: {bal}", "cd"),
 ("B16 X with amt. Avail Bal (date)", "{acct} {ed} with {amt}. Avail Bal {bal} ({date})", "cd"),
 ("B17 all lower case", "your {acctl} has been {ed} for {amtl} on {date} bal {ball}", "cd"),
 ("B18 leading Dr/Cr", "{CRDR} {amt} {acct} {date}; Bal {bal}", "cd"),
 ("B19 Alert header + not-you footer", "{Noun} Alert! {amt} {ed} {tofrom} {acct}. Avl Bal {bal}. Not you? Call 1800123456", "cd"),
 ("B20 UPDATE: amt X (mode Ref No)", "UPDATE: {amt} {ed} {tofrom} {acct} on {date} (NEFT Ref No SMPLN12345678). Available balance: {bal}", "cd"),
 ("B21 UPI debit to VPA", "{amt} debited from {acct} to VPA sample@okbank on {date}. UPI Ref 432198765432. Bal {bal}", "d"),
 ("B22 debited and credited to vpa", "Your {acct} is debited for {amt} on {date} and credited to sample@ybl (UPI Ref no 432198765432)", "d"),
 ("B23 UPI received from person", "You have received {amt} from SAMPLE PERSON (sample@upi) in {acct}. UPI Ref 432198765432", "c"),
 ("B24 credit card spent", "{amt} spent on your Sample Bank Credit Card ending 4321 at SAMPLE STORE on {date}. Avl limit {bal}", "D"),
 ("B25 debit card used", "Your debit card XX4321 was used for {amt} at SAMPLE MART on {date}. Bal {bal}", "D"),
 ("B26 card txn done", "Txn of {amt} done on card ending 4321 at SAMPLE FUEL on {date}.", "D"),
]
rows = []; n = 0
for tid, tmpl, dirs in T:
    for dch in dirs:
        direction = "credit" if dch == "c" else "debit"
        card = dch == "D"
        for k in range(5):
            acct, digits = ACCTS[(n * 3 + k * 7) % len(ACCTS)]
            amt, minor = AMTS[(n + k * 2) % len(AMTS)]
            credit = direction == "credit"
            ed = "credited" if credit else "debited"
            v = dict(acct=acct, acctl=acct.lower(), amt=amt, amtl=amt.lower(), date=DATES[(n + k) % len(DATES)], bal=BALS[(n + k) % len(BALS)],
                     ball=BALS[(n + k) % len(BALS)].lower(), bank=BANKS[(n + k) % len(BANKS)], payee=P[(n + k) % len(P)], ed=ed,
                     tofrom="to" if credit else "from", infrom="in" if credit else "from", CRDR="Cr" if credit else "Dr", Noun="Credit" if credit else "Debit")
            rows.append({"id": "%s|%s|%d" % (tid.split()[0], direction, k), "tmpl": tid, "sender": SENDERS[(n + k) % len(SENDERS)], "body": tmpl.format(**v),
                         "truth": {"direction": direction, "minor": minor, "digits": "4321" if card else digits}})
        n += 1
with open(sys.argv[1], "w") as f:
    for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
NEG = [
 "Your A/c XX5521 will be credited with Rs 45,000 salary on 1st of next month.",
 "Standing instruction for Rs.5000 from A/c XX5521 to SAMPLE STORES is set up successfully.",
 "Dear customer, your request for cheque book for A/c XX5521 is processed. Charges Rs 100 may apply.",
 "Bill of Rs 1,250.00 for consumer no 123456 is generated. Due date 20-09-2026.",
 "Your UPI mandate of Rs 999 for SAMPLE OTT is created successfully.",
 "You have a pending collect request of Rs.500 from sample@upi. Approve in app.",
 "Rs 5000 will be auto-debited from A/c XX5521 on 05/10/2026 for SIP.",
 "Limit of Rs 50,000 set for UPI transactions on A/c XX5521.",
 "Your loan application for Rs 3,00,000 is approved. Amount will be disbursed to A/c XX5521.",
 "Reminder: Recharge of Rs 299 expires tomorrow.",
 "Unable to process debit of Rs 2,500 from A/c XX5521. Please retry.",
 "Txn of Rs 1,200.00 on card ending 4321 at SAMPLE STORE was declined.",
 "Dear Customer, your A/c XX5521 has been credited with 500 reward points.",
 "IPO: Rs 15,000 blocked in A/c XX5521 for SAMPLE LTD application.",
 "Your refund request of Rs 499 has been received.",
 "E-mandate for Rs.2000 monthly towards SAMPLE INSURANCE is approved on A/c XX5521.",
 "Total outstanding on your card ending 4321 is Rs 23,456.00. Minimum due Rs 1,200.",
 "Your A/c XX5521 balance is below Rs 1000. Credit funds to avoid charges.",
 "Cheque no 654321 for Rs 12,000 presented on A/c XX5521 could not be cleared.",
 "Rs 2,000 cashback can be credited to your A/c XX5521 on recharge of Rs 599. Offer valid till 30 Sep.",
 "Your FD no 12345 of Rs 50,000 is renewed for 12 months at 7.1%.",
 "KYC for A/c XX5521 pending. Debit transactions of above Rs 10,000 will be restricted.",
 "Dear Customer, Rs 350.00 is the charge for SMS alerts on A/c XX5521 per quarter.",
 "UPI payment of Rs 780 to sample@okbank is pending. Check status after some time.",
]
with open(sys.argv[2], "w") as f:
    for i, b in enumerate(NEG):
        f.write(json.dumps({"id": "NB%02d" % i, "kind": "b", "sender": SENDERS[i % len(SENDERS)], "body": b}) + "\n")
print(len(rows), "set-B messages from", len(T), "layouts;", len(NEG), "set-B lookalikes")
