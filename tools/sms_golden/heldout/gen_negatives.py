#!/usr/bin/env python3
"""Lookalikes that are NOT a completed money movement. Counting any of them is a false transaction. All invented."""
import json, sys
N = [
 # future / scheduled
 ("future", "Your A/c XX1234 will be debited by Rs.5000.00 on 14/08/2026 towards EMI. Maintain sufficient balance."),
 ("future", "Rs 12,500.00 will be credited to your A/c XXXXX731 within 2 working days."),
 ("future", "Dear Customer, your A/c No.40000/XXXXX731 is scheduled to be debited with Rs.2500.00 on 14-Aug-26 for standing instruction."),
 ("future", "EMI of Rs.8,450.00 for loan a/c XX9087 is due on 05/09/2026. It will be debited from A/c XX1234."),
 ("future", "Your FD of Rs.1,00,000 in A/c XX1234 will mature on 14/08/2026 and proceeds will be credited to your account."),
 ("future", "Annual maintenance charges of Rs.590 will be debited from your A/c XX1234 on 01/09/2026."),
 # failed / declined / reversed attempts
 ("failed", "Your A/c XX1234 could not be debited by Rs.5000.00 on 14/08/2026 due to insufficient balance."),
 ("failed", "Transaction of Rs.5000.00 from A/c XX1234 on 14/08/2026 has failed. Amount, if debited, will be reversed."),
 ("failed", "Debit of Rs 12,500.00 from your A/c XXXXX731 declined on 14-Aug-26. Reason: limit exceeded."),
 ("failed", "NEFT of Rs.25000 from A/c XX1234 to SAMPLE TRADERS was unsuccessful. Ref SAMP123456."),
 ("failed", "Your request to transfer Rs.5000.00 from A/c XX1234 is rejected."),
 ("failed", "ECS/NACH debit of Rs.3,500.00 on A/c XX1234 returned unpaid on 14/08/2026. Charges applicable."),
 # requests / pending
 ("pending", "We have received your request to debit Rs.5000.00 from A/c XX1234. It will be processed shortly."),
 ("pending", "Cheque no 123456 for Rs.20,000.00 deposited in A/c XX1234 on 14/08/2026 is sent for clearing. Amount will be credited on realisation."),
 ("pending", "Your NEFT request of Rs.25000 to SAMPLE TRADERS is under process. Ref SAMP123456."),
 ("pending", "Refund of Rs.499.00 has been initiated and will be credited to your A/c XX1234 in 5-7 working days."),
 ("pending", "Rs.5000.00 has been put on hold in your A/c XX1234 on 14/08/2026 against lien."),
 ("pending", "Amount of Rs.15000.00 blocked in your A/c XX1234 for IPO application SAMPLE LTD."),
 # balance / statement / information
 ("info", "Your A/c XX1234 available balance is Rs.52,500.50 as on 14/08/2026."),
 ("info", "Avl Bal in A/c XXXXX731 is INR 1,04,079.26 on 14-Aug-26. Sample Bank"),
 ("info", "Monthly summary for A/c XX1234: total credits Rs.50,000.00, total debits Rs.42,000.00 in Jul 2026."),
 ("info", "Your A/c XX1234 has not maintained minimum balance of Rs.5000. Charges of Rs.150 are applicable."),
 ("info", "Interest rate on your SB A/c XX1234 revised to 3.5% p.a. w.e.f. 14/08/2026."),
 ("info", "Cheque no 123456 of Rs.20,000.00 issued from A/c XX1234 has been returned unpaid."),
 ("info", "Your credit limit on card XX4321 is Rs.2,00,000. Available limit Rs.1,50,000."),
 ("info", "Mandate for Rs.5000.00 on A/c XX1234 towards SAMPLE MUTUAL FUND is registered successfully."),
 ("info", "Dear Customer, e-statement of A/c XX1234 for the period ending 31-Jul-26 has been sent to your email."),
 ("info", "Your account XX1234 KYC is due. Update before 14/08/2026 to avoid debit freeze."),
 ("info", "Loan of Rs.2,00,000 has been sanctioned against your A/c XX1234. Visit branch to complete formalities."),
 # offers / marketing
 ("promo", "Get a personal loan up to Rs.5,00,000 credited to your A/c in 10 minutes. Apply now."),
 ("promo", "Congratulations! Cashback of up to Rs.500 will be credited on your first UPI payment from A/c XX1234."),
 ("promo", "Pre-approved offer: Rs.3,00,000 can be credited to your account XX1234 instantly. T&C apply."),
 ("promo", "Open an FD with Rs.10,000 from your A/c XX1234 and earn 7.5% interest."),
 ("promo", "Pay your premium of Rs.4500 from A/c XX1234 and get Rs.200 cashback."),
 # security
 ("otp", "OTP 482913 to debit Rs.5000.00 from A/c XX1234. Valid for 5 minutes. Do not share."),
 ("otp", "Never share OTP. Bank never asks. Your A/c XX1234 was accessed on 14/08/2026."),
 ("otp", "123456 is your OTP for transaction of INR 12,500.00 at SAMPLE SHOP from A/c XX1234."),
 # dues and reminders
 ("due", "Premium of Rs.4500.00 towards Policy 000123456 is due on 14/08/2026."),
 ("due", "Your loan A/c XX9087 EMI of Rs.8,450.00 is overdue. Pay immediately to avoid charges."),
 ("due", "Minimum amount due Rs.2,500 and total due Rs.48,200 on card XX4321 by 20-Aug-26."),
 ("due", "Locker rent of Rs.1500 for A/c XX1234 is due. Kindly pay at the branch."),
 # other party / hypothetical
 ("other", "If Rs.5000.00 is debited from your A/c XX1234 without your consent, call 1800000000."),
 ("other", "Beware of fraud: messages saying Rs.10,000 credited to your A/c by mistake are fake."),
 ("other", "Dear Customer, to activate A/c XX1234 credit Rs.1000 minimum balance at any branch."),
]
with open(sys.argv[1], "w") as f:
    for i, (kind, body) in enumerate(N):
        f.write(json.dumps({"id": "N%02d|%s" % (i, kind), "kind": kind, "sender": ["VM-SMPLCB-S", "AD-SMPUCB-T", "JX-SMPGRB-S"][i % 3], "body": body}) + "\n")
print(len(N), "negative lookalikes")
