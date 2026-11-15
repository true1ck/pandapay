#!/usr/bin/env python3
"""Generates the labelled-payee debit rules (rules/sms/v2/generalization/labeled_payee_debit.json).

Many Indian banks print who was paid after a label ("Fvg: NAME", "favouring NAME", "in favour of NAME",
"Beneficiary: NAME", "Payee: NAME"). The old SMS pipeline read that label wherever it sat in the message. These
rules do the same: the account, the debit word and the amount are found first, then ANY text (a rail, a
reference, a date), then the label and the name after it. Nothing here depends on one bank's layout, so a bank
that rewords the rest of the alert is still read. The name ends at a stop word (balance, reference, a call-us
footer) or at punctuation.

Every example body is synthetic. Run: python tools/sms_rules_cli/tool/gen_labeled_payee_rules.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import gen_account_alert_rules as g  # noqa: E402  (shared fragments: RS, AMT, DATE, BAL, rule, ex, movement)

LABEL = r"(?:fvg|favou?ring|in\s+favou?r\s+of|beneficiary|payee)"
# a name ends at a stop word, or at punctuation that is not part of a name
STOP = (r"(?=\s+(?:avl|avbl|avail(?:able)?|bal(?:ance)?|clear|ref(?:erence)?|utr|txn|transaction|not\s+you|if\s+not|"
        r"call|sms|on|from|dated|via)\b|\s*[;,(]|\.(?:\s|$)|\s*$)")
ACCT = (r"\b(?:a/?c(?:ct)?\.?|account)(?:\s*(?:no|number|num)\.?)?\s*[:\-]?\s*[x*•.]*\s?(?<mask>\d{2,18})")
HEAD = (ACCT + r"\s+(?:has\s+been\s+|is\s+|was\s+)?debited(?:\s+(?:for|by|with|of))?\s*" + g.RS + g.AMT("amt") +
        r"(?:\s*/-)?(?:\s+(?:on|dated)\s+" + g.DATE + r")?")
# amount first: "Rs 500.00 debited from A/c XX1234 on 22-Oct-26 ..."
HEAD_AF = (g.RS + g.AMT("amt") + r"(?:\s*/-)?\s+(?:has\s+been\s+|is\s+|was\s+)?debited\s+(?:from\s+|in\s+|to\s+)?(?:your\s+)?" + ACCT +
           r"(?:\s+(?:on|dated)\s+" + g.DATE + r")?")
# up to 160 characters of anything (rail, reference number, narration), but never another debit or credit statement
FILLER = r"(?:(?!\b(?:debited|credited)\b)[\s\S]){0,160}?"
PAYEE = r"\b" + LABEL + r"\s*[:#\-]?\s*(?<payee>[A-Za-z][^\n]*?)" + STOP

REJECT = ["fail", "declin", "will be", " otp", "reject", "insufficient", "request", "unauthoris", "unauthoriz",
          "beware", "fake", "if rs", "if inr", "if ₹", "in case", " emi", "mandate", "credit card", "card ending", "sip "]


def rules():
    out = []
    for amount_first, balance in ((False, False), (False, True), (True, False), (True, True)):
        pat = (HEAD_AF if amount_first else HEAD) + FILLER + PAYEE
        emit = [g.movement("debit", "p2p", "unknown",
                           counterparty={"nameFrom": "payee", "transforms": ["sanitizeNarration"]})]
        if balance:
            pat += g.BAL
            emit.append(g.BAL_EMIT)
        # one positive example per rule, each with its own payee, amount and day (the test corpus draws rule
        # examples, so identical examples would look like one recurring charge)
        n = (1 if balance else 0) + (2 if amount_first else 0)
        names = ("Asha Rao", "Meera Iyer", "Neha Das", "Omar Khan")
        shape = ("Sample Bank A/c *1234 Debited Rs:%d.00 on %02d-10-2026 19:28:42 by Mob Bk ref no 61234567890%d, "
                 "Fvg: %s") % (2500 + 137 * n, 21 + n, n, names[n])
        shape2 = ("Your A/c No. XX1234 is debited for Rs. %d on %02d-Oct-26 through NEFT UTR 61234567890%d "
                  "in favour of %s") % (700 + 53 * n, 25 + n, n + 2, ("Ravi Kumar", "Kiran Shah", "Tara Nair", "Vikram Rao")[n])
        if amount_first:
            shape = ("Sample Bank: Rs %d.00 debited from A/c XX1234 on %02d-Oct-26 by UPI ref 61234567890%d Beneficiary: %s"
                     % (1250 + 61 * n, 22 + n, n, names[n]))
            shape2 = ("INR %d debited from your account no. 1234 by IMPS Ref %d on %02d-10-2026 fvg %s"
                      % (400 + 37 * n, 71234567800 + n, 22 + n, ("Ravi Kumar", "Kiran Shah", "Tara Nair", "Vikram Rao")[n]))
        types = ["movement"]
        if balance:
            shape += " Avl Bal Rs:594.92. Not you?Call 1800000000"
            shape2 += ". Avl Bal Rs 9,000.00"
            types = ["movement", "balance_snapshot"]
        if amount_first:
            future = shape.replace("debited", "will be debited", 1)
            credit = shape.replace("debited", "credited", 1)
        else:
            future = shape.replace("Debited", "will be Debited", 1)
            credit = shape.replace("Debited", "Credited", 1)
        negatives = [g.ex(future, []), g.ex(credit, [])]
        out.append(g.rule("GENZ-ACCT-DR-LABELED-PAYEE" + ("-AF" if amount_first else "") + ("-B" if balance else ""), "acct_debit", ["*"],
                          (428 if amount_first else 430) + (5 if balance else 0), pat, emit, 0.9,
                          [g.ex(shape, types), g.ex(shape2, types)] + negatives, reject=REJECT))
    return out


if __name__ == "__main__":
    g.dump("labeled_payee_debit.json", rules())
