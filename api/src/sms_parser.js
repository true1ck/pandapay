/**
 * UA-5.3 — SMS-to-transaction-fields parsing engine.
 *
 * Pure function: given a `parser_patterns` row (regex + field_map) and a raw
 * SMS body, extract structured transaction fields — or return a "no match"
 * result. Never fabricates a guess: any regex miss or unparseable numeric
 * field is a failure, not a best-effort partial transaction.
 *
 * field_map is jsonb like {"amount": 1, "merchant": 2, "last4": 3, "date": 4}
 * mapping a known field name -> capture group index (1-based, matching JS
 * regex exec() group indexing) in `regex`. Only "amount", "merchant",
 * "last4", "date", "instrument", "reference" and "direction" are recognized fields; anything else in field_map is
 * ignored rather than erroring, so a pattern can carry forward-compatible
 * extra keys without breaking older parser code.
 */

const KNOWN_FIELDS = [
  'amount', 'merchant', 'last4', 'date', 'instrument', 'reference',
  'direction', 'mcc', 'availableBalance', 'balance',
];
const MAX_MESSAGE_LENGTH = 20000;
const { isInvestmentFundingMessage, isBrokerSettlementMessage, isInvestmentFolioAllotment } = require('./recurring');

// OTP/security alerts can contain the same words as a transaction alert
// ("txn", "INR", "card ending") but must never become spending records.
// Keep this check before admin-configured patterns so a broad pattern cannot
// accidentally turn an OTP into a transaction.
const ADVISORY_WARNING_RE = /\b(?:(?:do\s+not|don't|never)\s+share\b[\s\S]{0,60}?\b(?:otp|pin|cvv|password|passcode|details|secret|code)\b|bank\s+never\s+asks\s+for\b[\s\S]{0,60}?\b(?:otp|pin|cvv|password|details))\b[^\n]*/gi;

function isSecurityOrOtpMessage(body) {
  const text = String(body || '').replace(ADVISORY_WARNING_RE, '').toLowerCase();
  return /\b(?:otp|one[-\s]?time password|verification code|security code|cvv|pin|passcode|secret code)\b/.test(text)
    || /\b(?:do not|don't|never)\s+share\b/.test(text)
    || /\b\d{4,8}\b[\s\S]{0,40}\bvalid\s+(?:for|till|until)\s+\d+\s*(?:minutes?|mins?|seconds?|secs?)\b/.test(text);
}

function isNonTransactionNoise(sender, body) {
  if (isInvestmentFolioAllotment(body)) return false;
  const cleanSender = String(sender || '').trim();
  if (cleanSender) {
    if (/^(?:\+?91[-\s]?|0)?[6-9]\d{9}$/.test(cleanSender)) return true;
    if (/^(?:\+?91[-\s]?|0)?140\d{7}$/.test(cleanSender)) return true;
    if (/^(?:[A-Za-z]{2}-)?\d{6}(?:-[A-Za-z])?$/.test(cleanSender)) return true;
  }
  const text = String(body || '').replace(/\s+/g, ' ');
  // Biller onboarding only enrols a service; it does not report a bill.
  // "Once the bill is generated" is a future promise, so it must be rejected
  // before the bill-ready keep-rule below. Any amount, due date or
  // AutoPay/mandate terms keep the message actionable.
  const billerOnboarding = /\b(?:added|registered|enrolled|linked|activated|subscribed|enabled)\b[\s\S]{0,80}\b(?:bill\s*pay|billpay|bill\s*payment(?:\s+service)?|biller|payee|e[- ]?bill|paperless|bill\s+fetch|bill\s+alerts?)\b/i.test(text)
    || /\b(?:bill\s*pay|billpay|biller|payee|e[- ]?bill|paperless|bill\s+fetch|bill\s+alerts?)\b[\s\S]{0,60}\b(?:added|registered|enrolled|linked|activated|subscribed|enabled|registration)\b/i.test(text)
    || /\b(?:bill\s+will\s+be\s+generated|bill\s+generation\s+date|we\s+will\s+notify\s+you\b[\s\S]{0,60}\bbill\b|(?:you\s+will\s+(?:receive|get)|we\s+will\s+(?:send|notify|inform))\b[\s\S]{0,50}\bbill\b|\bwill\s+(?:send|notify|inform|share)\b[\s\S]{0,40}\bbill\b|(?:once|when|after)\b[\s\S]{0,30}\bbill\b[\s\S]{0,15}\b(?:is\s+|gets\s+)?generated\b)/i.test(text);
  const hasCurrencyAmount = /(?:₹|\brs\.?|\binr)\s*[\d,]+|\b\d[\d,]*(?:\.\d{1,2})?\s*(?:₹|rs\.?|inr)\b/i.test(text);
  const hasDueDate = /\b(?:payment|amount|total|minimum)\s+due\b|\bdue\s+(?:date|on|by)\b|\bpay(?:ment)?\s+(?:by|before)\b/i.test(text);
  const hasMandate = /\b(?:auto\s*pay|autopay|e[- ]?mandate|mandate|standing\s+instruction|auto[- ]?debit)\b/i.test(text);
  const hasMovement = /\b(?:failed|declined|debited|credited|paid|charged|transferred|withdrawn)\b|\b(?:payment|transaction|txn)\b[\s\S]{0,20}\b(?:successful|completed|failed)\b/i.test(text);
  if (billerOnboarding && !hasCurrencyAmount && !hasDueDate && !hasMandate && !hasMovement) return true;
  const hasMaskedAccount = /\b(?:a\/?c|account|card)\b[\s\S]{0,25}\b(?:xx|\*{2,}|ending(?:\s+(?:with|in))?\s*\d{3,4})\b|\b(?:xx|\*{2,})\d{3,4}\b/i.test(text);

  const telecomCarrierNotice = (
    /\b(?:number\s+)?retention\s+charges?\b/i.test(text)
    || /\b(?:deducted|debited)\s+from\s+(?:top-?up|talktime|prepaid|main|core)\s+bal(?:ance)?\b/i.test(text)
    || /\b(?:from|on)\s+top-?up\s+bal(?:ance)?\b/i.test(text)
    || /\bno\s+usage\s+observed\b[\s\S]{0,40}\b(?:days?|recharge)\b/i.test(text)
    || /\brecharge\s+your\s+(?:jio|airtel|vi|vodafone|idea|bsnl)?\s*number\b[\s\S]{0,60}\bto\s+avoid\s+(?:these\s+)?charges\b/i.test(text)
    || (
      /\b(?:jio|airtel|vi|vodafone|idea|bsnl)\b/i.test(`${cleanSender} ${text}`)
      && /\b[6-9]\d{9}\b/.test(text)
      && /\b(?:recharge\s+now|(?:kindly\s+|please\s+)?recharge\s+your|validity\s+(?:is\s+)?expir|top-?up|talktime|retention)\b/i.test(text)
      && !/\b(?:successful|completed|done|received)\b/i.test(text)
      && !hasMaskedAccount
    )
  ) && !hasDueDate && !/\b(?:statement|bill)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b/i.test(text);
  if (telecomCarrierNotice) return true;

  // Repayment acknowledgments and loan eligibility checks that carry no
  // transaction amount or debit evidence are informational cross-sells.
  const repaymentCourtesyOrLoanUpsell = (
    /\b(?:we\s+have\s+)?received\s+your\s+(?:timely\s+)?repayment\b[\s\S]{0,60}\btowards?\s+your\s+(?:pay\s*later|credit\s*line|loan)\b/i.test(text)
    || /\b(?:check\s+your\s+)?(?:updated\s+)?personal\s+loan\s+eligibility\b/i.test(text)
    || /\bpersonal\s+loan\s+eligibility\s+here\b/i.test(text)
  ) && !hasCurrencyAmount;
  if (repaymentCourtesyOrLoanUpsell) return true;

  const loanOrCreditPowerMarketing = /\b(?:new\s+credit\s+alert|your\s+loan\s+limit\s+is\s+revised|(?:loan|credit)\s+limit\b[\s\S]{0,30}\b(?:revised|increased|enhanced|updated)|digital\s+credit\s+power\s+is\s+(?:now\s+)?active|updated\s+limit\s+here\b|view\s+your\s+updated\s+limit)\b/i.test(text) && !hasCurrencyAmount;
  if (loanOrCreditPowerMarketing) return true;

  const bettingOrGamblingSpam = /\b(?:betting\s+(?:site|app)|gullybet|casino|slots|aviator|cockfight|fancy\s+bet|teen\s+patti|online\s+gambling|huge\s+bonus\b[\s\S]{0,30}\b(?:bet|casino|slots|win)|gbets\.win)\b/i.test(text);
  if (bettingOrGamblingSpam) return true;
  if (/\b(?:payment|amount|minimum|total)\s+due\b|\bdue\s+date\b|\b(?:statement|bill|premium)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b/i.test(text)) return false;
  if (/\b(?:eligible\s+for\s+(?:[\w\s]{0,20}\s+)?(?:conversion|flexipay|emis?)|convert(?:ed|ing)?\b[\s\S]{0,60}?\b(?:in)?to\b[\s\S]{0,20}?\b(?:smart\s+|flexipay\s+|easy\s+)?emis?|can\s+(?:now\s+)?be\s+converted\s+(?:in)?to\s+emis?|flexipay\s+emis?)\b/i.test(text)
      && !/\b(?:has\s+been|was|is)\s+(?:debited|credited|charged|paid)\b/i.test(text)
      && !/\b(?:debited|charged)\s*(?:by|with|for)?\s*(?:₹|rs\.?|inr)/i.test(text)) return true;
  const completed = /\b(?:your\s+(?:txn|transaction)\s+of|txn\s+(?:of|for)|(?:has\s+been|was|is)\s+(?:debited|credited|charged|paid)|(?:debited|credited|spent|paid|charged|transferred|withdrawn|received)(?:\s+(?:by|with|for|towards|of|amounting\s+to))?\s*(?:₹|rs\.?|inr)|(?:₹|rs\.?|inr)\s*[\d,]+(?:\.\d{1,2})?\s*(?:has\s+been\s+)?(?:debited|credited|spent|paid|charged|transferred|withdrawn|received)|(?:sent|cash\s+withdrawal|withdrawal|auto[-\s]?debit)\s*(?:of|by)?\s*(?:₹|rs\.?|inr)|(?:recharge|payment|transaction|purchase|settlement|payout)\b[\s\S]{0,45}\b(?:successful|completed|initiated|processed))/i.test(text);
  if (completed || (/\b(?:cashback|refund)\b/i.test(text) && /\b(?:credited|received|deposited)\b/i.test(text)) || /\b(?:debit|credit)\s+hua\b/i.test(text)) return false;
  if (/\bautopay\s+(?:alert|reminder|scheduled|activation)\b|\bauto[-\s]?pay\b|\b(?:e[-\s]?mandate|mandate|standing\s+instruction)\b|\bmax(?:imum)?\s*limit\b/i.test(text)) return false;
  return /\b(?:offer|sale|discount|cashback|voucher|coupon|rewarding|shop\s+at|grab|buy\s+now|apply\s+now|prices?\s+slashed|treat\s+yourself|festive\s+shopping|eligible\s+for\s+conversion|convert\s+(?:to|into)\s+emi|international\s+roaming\s+pack)\b|\b(?:get|earn|save)\b[\s\S]{0,45}\b(?:reward|cashback|off|free|voucher)\b/i.test(text)
    || /\b(?:services?\s+(?:is|are|has\s+been)\s+(?:blocked|suspended)|visit\s+(?:your\s+)?nearest\s+branch|suspicious\s+(?:txns?|transactions?)\s+in\s+your\s+account|call\s+forwarding\s+is\s+(?:now\s+)?active|calls?\s+are\s+being\s+forwarded|to\s+deactivate\s+(?:this\s+)?service|transaction\s+check\s+alert|confirm\s+(?:the\s+)?(?:following\s+)?txn|sim\s+swap|reported\s+(?:your\s+)?fund\s+bal(?:ance)?|securities\s+bal(?:ance)?|excludes\s+your\s+bank|beware\s+(?:of\s+)?dealing\s+(?:in|on)\s+unsolicited\s+tips|unsolicited\s+tips|due\s+for\s+renewal|renew\s+now\s+with\s+policybazaar|wallet\s+balance\s+is\s+(?:rs\.?|inr)\s*0|add\s+money\s+to\s+wallet|report\s+spam|trai\s+dnd|telecommunications\s+act|sanchar\s+saathi|chakshu|online\s+investment\s+scams|traded\s+value\s+for\b|has\s+been\s+dispatched|has\s+been\s+delivered|card\s+usage\s+settings?|usage\s+(?:&|and)\s+transaction\s+limit|transaction\s+limits?\s+options?|limits?\s+(?:have|has)\s+been\s+updated|usage\s+options?\s+(?:have|has)\s+been\s+updated|ckyc\s+record|central\s+kyc\s+registry|out\s+for\s+delivery\s+with\s+cash\s+memo|pls\s+share\s+delivery\s+code|delivery\s+code\s+\d+)\b/i.test(text)
    || /\b(?:will\s+remain\s+open\s+and\s+fully\s+operational|available\s+at\s+our\s+branches\s+during\s+normal\s+working\s+hours|submission\s+of\s+positive\s+pay\s+details\s+is\s+mandatory)\b/i.test(text)
    || /\bdone\s+\d+\s+out\s+of\s+\d+\s+free\s+transactions\s+at\s+[\w\s]+atms\b/i.test(text)
    || /\b(?:cdsl|nsdl)\s*:\s*(?:debit|credit)\s+in\s+a\/c\b[\s\S]{0,40}\b(?:etf|bees|shares?|units?|mf)\b/i.test(text)
    || /\b(?:cdsl|nsdl)\s*:\s*(?:unpledge|pledge)\b/i.test(text)
    || /\b(?:updated\s+(?:your\s+)?address\s+under\s+folio|address\s+in\s+folio[^\w\n]*\w+\s+is\s+updated|based\s+on\s+feed\s+received\s+from\s+kra)\b/i.test(text)
    || /\b(?:track\s+it\s+using\s+this\s+ticket\s+id|ticket\s+id\s*:\s*\d+\s+on\s+the\s+help\s+section|we're\s+on\s+it\s+and\s+will\s+get\s+back\s+to\s+you\s+in\s+\d+[-–]\d+\s+hours)\b/i.test(text)
    || /\benable\s+online,\s+international\s+(?:and|&)\s+contactless\s+transactions\b/i.test(text)
    || /\byour\s+ekyc\s+has\s+been\s+successfully\s+completed\b/i.test(text)
    || /\bdue\s+to\s+scheduled\s+maintenance\b[\s\S]{0,80}\b(?:paused|unavailable|interrupted)\b/i.test(text)
    || /\bregistration\s+alert\s*:\s*device\s+name\b/i.test(text)
    || /\bcoupons?\s+expire\b/i.test(text)
    || /\b(?:order\b[\s\S]{0,40}\b(?:is\s+)?dispatched\s+through|order\s+(?:is\s+)?dispatched\s+through|we\s+have\s+received\s+your\s+order\s+id)\b/i.test(text)
    || /\blifetime[- ]free\s+credit\s+card\s+facility\s+has\s+been\s+enabled\b/i.test(text)
    || /\b(?:bse\s+trade\s+confirmation|welcome\s+to\s+nse,\s+you\s+have\s+been\s+registered\b|registered\s+with\s+[\w\s]+in\s+segment(?:\(s\))?|registered\s+with\s+[\w\s]+in\s+segment\(s\))\b/i.test(text)
    || /\b(?:puc\s+certificate\s+for\s+vehicle\b|your\s+itr\s+for\s+ay\b[\s\S]{0,30}\bawaits\s+at\s+the\s+e[- ]?filing\s+portal)\b/i.test(text)
    || /\b(?:(?:two\s+wheeler|car|motor|vehicle)?\s*insurance\s+for\b[\s\S]{0,50}\b(?:has\s+expired|expires\s+today|will\s+expire)\b|(?:two\s+wheeler|car|motor|vehicle)?\s*insurance\s+expired\b|renew\s+your\s+expired\s+(?:two\s+wheeler|car|motor|vehicle|health)?\s*insurance\b|will\s+expire\s+on\b[\s\S]{0,50}\b(?:premium\s+starts?\s+(?:just\s+)?(?:at\s+)?(?:rs\.?|inr)|instant\s+renewal,\s+visit|renew\s+before\s+expiry))\b/i.test(text)
    || /\b(?:claim\s+your\s+[\w\s]+(?:insta\s+)?emi\s+card|avail\s+card\s+with\s+limit\s+upto|use\s+card\s+loan\s+limit\s+of\b|complete\s+your\s+[\w\s]+emi\s+card\s+application)\b/i.test(text)
    || /\b(?:is\s+still\s+not\s+renewed|renew\s+to\s+avoid\s+unexpected\s+expenses|renew\s+before\s+expiry\s+on|registration\s+for\s+(?:fingerprint|face\s+id|biometric)|your\s+request\s+for\s+renewal\s+has\s+been\s+received\s+&\s+processed)\b/i.test(text)
    // Informational card/account controls carry no money movement, amount,
    // due date, balance or mandate. A completed debit, bill, balance snapshot
    // or credit limit with an amount has already returned false above.
    || /\btransaction\s+limits?\b[\s\S]{0,60}\b(?:has|have|is|are)\s+been\s+(?:updated|changed|modified|set)\b/i.test(text)
    || /\bsecurity\s+tip\b[\s\S]{0,80}\b(?:enable|set|disable|protect|never\s+share|keep\s+your)\b/i.test(text)
    || /\benable\s+online\s+(?:use|usage|transactions?)\b/i.test(text)
    || /\bset\s+limit\s+on\b[\s\S]{0,40}\b(?:credit\s+card|card)\b/i.test(text)
    || /\b(?:credit\s+card|card|account)\b[\s\S]{0,50}\bhas\s+been\s+linked\b/i.test(text)
    || /\blinked\s+for\s+(?:net\s*banking|internet\s+banking|mobile\s+banking)\b/i.test(text)
    || /\bunused\s+funds\b[\s\S]{0,100}\b(?:transferred|settled|settlement)\b/i.test(text)
    || /\bas\s+per\s+sebi\b[\s\S]{0,120}\bsettlement\b/i.test(text)
    || /\bday\s+of\s+settlement\b/i.test(text)
    || (/-p\s*$/i.test(String(sender || '')) && !/\b(?:txn|transaction|debited|credited|spent|paid|charged|received|refund|statement|bill\s+due)\b/i.test(text));
}

function isRejectedTransaction(body) {
  const text = String(body || '').toLowerCase();
  return /\b(?:declined|failed|failure|reversed|reversal|refund(?:ed)?|cancelled|canceled|credited)\b/.test(text);
}

// These alerts contain an amount and a card number but do not describe a
// purchase. They must be rejected before configured patterns and before the
// built-in fallbacks, otherwise a credit-card due reminder becomes spending.
function isNonTransactionAlert(body) {
  const text = String(body || '').toLowerCase();
  return /\b(?:payment|amount|minimum)\s+due\b/.test(text)
    || /\b(?:statement|bill|premium)\b[\s\S]{0,80}\bdue\b/.test(text)
    || /\b(?:statement|bill)\b[\s\S]{0,40}\b(?:generated|ready|available)\b/.test(text)
    || /\b(?:new\s+)?pin\b[\s\S]{0,40}\b(?:generated|created|set)\b/.test(text)
    || /\b(?:card|credit\s+card)\b[\s\S]{0,50}\b(?:dispatched|delivered|activated)\b/.test(text)
    // Card offers often say "Spend ₹15,000, get ₹250" and include the
    // masked card number. That is an offer condition, not a purchase alert.
    || /\bspend\s*(?:₹|rs\.?|inr)\s*[\d,]+[\s\S]{0,50}\b(?:get|earn|cashback|reward|voucher)\b/.test(text)
    || /\b(?:cashback|reward|voucher|offer|eligible|campaign)\b[\s\S]{0,80}\b(?:spend|card)\b/.test(text)
    || /\b(?:betting\s+(?:site|app)|gullybet|casino|slots|aviator|cockfight|fancy\s+bet|teen\s+patti|online\s+gambling|huge\s+bonus\b[\s\S]{0,30}\b(?:bet|casino|slots|win)|gbets\.win)\b/i.test(text);
}

// Bank-account UPI alerts often contain a four-digit account suffix. That
// suffix is not a card last-4, and a configured pattern must not be allowed to
// turn the alert into a credit-card transaction just because it mapped one of
// its capture groups to `last4` or `instrument`.
function isBankAccountUpiMessage(body) {
  const text = String(body || '').toLowerCase();
  return /\b(?:upi|a\/?c\.?|account)\b/.test(text)
    && (/\b(?:debit(?:ed)?|paid|spent|sent|transferred)\b/.test(text) || isWalletLoadMessage(text))
    && !/\b(?:credit|debit)\s+card\b/.test(text);
}

// Final guard for an account-shaped alert that did not contain enough data
// for any automatic parser (normally a missing amount). Complete account
// debits are handled by the built-in bank-debit parser above and do not enter
// the user's review queue.
function isAmbiguousAccountDebit(body) {
  const text = String(body || '').toLowerCase();
  return isBankAccountUpiMessage(text) && !/\bupi\b/.test(text);
}

// Account suffixes are useful for grouping spend, but they must never share
// the `last4` field used to resolve a physical card. Keep this as a separate
// masked identifier; the full account number is never stored or inferred.
function extractAccountLast4(body) {
  // A credit-card account is a card ledger, not a deposit account.
  if (/\bcredit\s+card\b/i.test(String(body || ''))) return null;
  const match = String(body || '').match(
    /\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+with)?|last\s*4)\s*)?[*xX.\s-]*(\d{4})\b/i,
  );
  return match ? match[1] : null;
}

// A four-digit account suffix is not enough to put an item in the Home
// "bank accounts" section. Investment/insurance alerts also contain account
// numbers, and some of them use the same debit/credit vocabulary as banks.
// Keep this predicate deliberately conservative: the account card should only
// represent a deposit/current/savings account, never a policy, demat,
// brokerage, or card ledger.
function isBankAccountMessage(body, sender = '') {
  const text = String(body || '').toLowerCase();
  if (!text) return false;
  const senderText = String(sender || '').toLowerCase();
  // Axio sender families describe a Pay Later liability as an "a/c" and use
  // words such as "credit" / "received" in loan offers and repayment status
  // messages. Neither is evidence of an owned deposit bank account.
  if (senderText.includes('axio') || /\b(?:pay\s+later|credit\s+line)\b/.test(text)) return false;
  const hasExplicitAccount = /\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+with)?|last\s*4)\s*)?[*xX.\s-]*\d{4}\b/i.test(text);
  if (/\bcredit\s+card\b/i.test(text)) return false;
  if (!hasExplicitAccount && /\bdebit\s+card\b/i.test(text)) return false;
  if (/\b(?:lic|life\s+insurance|policy|premium|demat|trading|broker(?:age|ing)?|portfolio|holdings?|folio|dp\s*id|client\s*id|nav|units?|shares?|stocks?|equity|sip|mutual\s+fund|investment|zerodha|groww|upstox|angel\s+one|dhan|paytm\s+money)\b/.test(text)) {
    return false;
  }

  const accountMarker = /\b(?:bank|a\/?c\.?|account|savings|current|upi|imps|neft|rtgs|atm)\b/.test(text);
  const bankIdentityMarker = /\b(?:bank|a\/?c\.?|savings|current|upi|imps|neft|rtgs|atm)\b/.test(text)
    || /(?:bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)/.test(senderText);
  const balanceMarker = /\b(?:(?:total\s+)?(?:available|avail|avl|current|closing|clr|new|remaining)\.?\s*(?:balance|bal)\b|bal(?:ance)?\.?\s*(?:is|:|-))/i.test(text);
  const movementMarker = /\b(?:debited|debit|credited|credit|paid|spent|sent|transferred|withdrawn|received|deposited)\b/.test(text);
  // The suffix must be accompanied by explicit account/bank language. A
  // balance phrase by itself is not enough because investment and policy
  // alerts can also contain "balance" wording.
  return accountMarker && bankIdentityMarker && (balanceMarker || movementMarker || isWalletLoadMessage(text));
}

// Only accept an explicitly labelled available/current balance. The spend
// amount and the balance are often both present in one bank SMS; taking the
// first or last currency value would silently turn the spend into a balance.
function extractAvailableBalance(body) {
  const text = String(body || '');
  const match = text.match(
    /\b(?:(?:total|tot)\s+)?(?:avail(?:able)?|avl|current|closing|clr|new|remaining)?\.?\s*(?:bal(?:ance)?|a\/?c\s*bal(?:ance)?)\.?\s*(?:is|:|-)?\s*(?:(?:rs\.?|inr|₹)\s*){1,2}:?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)/i,
  ) || text.match(
    /\b(?:is|of)\s*(?:(?:rs\.?|inr|₹)\s*){1,2}:?\s*([\d,]+(?:\.\d{1,2})?)\s*(?:(?:dr\.?|cr\.?)?\s*(?:total\s*)?avail(?:able)?\.?\s*bal(?:ance)?\.?|\s*as\s+avail(?:able)?\.?\s*bal(?:ance)?\.?)/i,
  ) || text.match(
    /\b(?:bal|balance)\s*(?:is|:|-)?\s*(?:₹|rs\.?|inr)?\s*:?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)/i,
  );
  if (!match) return null;
  const amount = Number(match[1].replace(/,/g, ''));
  return Number.isFinite(amount) && amount >= 0 ? amount : null;
}

function withAvailableBalance(fields, body) {
  const balance = extractAvailableBalance(body);
  return balance === null ? fields : { ...fields, availableBalanceInr: balance };
}

function isWalletLoadMessage(body) {
  const text = String(body || '');
  // Require a wallet-ish noun within a short window after the load verb. A
  // bare "add funds" cannot win: broker alerts say "add funds back to your
  // Dhan account" as an instruction for the next action, which is not this
  // transaction. Named-wallet branches below carry the common real shapes.
  return /\b(?:wallet\s+load|load(?:ed|ing)?\s+(?:the\s+)?(?:paytm|phonepe|amazon\s*pay|mobikwik|wallet)|money\s+added\s+to\s+(?:the\s+)?wallet|add\s+(?:money|funds?)|top[ -]?up|money\s+added)\b[\s\S]{0,40}\b(?:paytm|phonepe|amazon\s*pay|mobikwik|wallet)\b/i.test(text)
    || /\b(?:paytm|phonepe|amazon\s*pay|mobikwik)\b[\s\S]{0,40}\b(?:add\s+(?:money|funds?)|top[ -]?up|wallet\s+load|added)\b/i.test(text)
    || /\b(?:added|loaded|credited)\s+to\s+(?:the\s+)?(?:paytm|phonepe|amazon\s*pay|mobikwik)\s+wallet\b/i.test(text)
    || /\b(?:paytm|phonepe|amazon\s*pay|mobikwik)\s+wallet\b[\s\S]{0,30}\b(?:added|loaded|credited)\b/i.test(text);
}

// A broker reporting a settlement payout is detected in recurring.js
// (isBrokerSettlementMessage) so the debit/investment collectors share the
// same notion and cannot register a payout as an outflow.

// UPI/QR transfers frequently address a person by name instead of an
// account suffix. When that name is the account owner's own profile name,
// the movement is a self transfer even though the SMS never says so. The
// match is deliberately strict: at least two significant tokens of the
// profile name must appear in the recipient/party text, so a namesake
// store ("Sujay Enterprises") or a relative sharing one name cannot count.
const OWN_NAME_NOISE = new Set(['mr', 'mrs', 'ms', 'shri', 'smt', 'dr', 'prof']);

function personNameTokens(value) {
  return (String(value || '').toLowerCase().match(/[a-z][a-z']+/g) || [])
    .filter((token) => token.length >= 3 && !OWN_NAME_NOISE.has(token));
}

function isOwnPersonName(candidate, ownUserName) {
  const nameTokens = personNameTokens(ownUserName);
  if (nameTokens.length < 2) return false; // ceiling: few owners have a one-token legal name; add initial handling if real profiles need it
  const candidateTokens = String(candidate || '').toLowerCase().match(/[a-z][a-z']+/g) || [];
  let matched = 0;
  for (const nameToken of nameTokens) {
    if (candidateTokens.some((token) =>
      token === nameToken
      || (token.length >= 2 && nameToken.startsWith(token))
      || (nameToken.length >= 2 && token.startsWith(nameToken)))) {
      matched += 1;
    }
  }
  return matched >= 2;
}

function isExplicitOwnAccountTransfer(body) {
  const text = String(body || '');
  return /\b(?:self[ -]?transfer|own\s+(?:bank\s+)?account|between\s+(?:my|your)\s+(?:bank\s+)?accounts)\b/i.test(text)
    || /\bfrom\s+your\b[\s\S]{0,100}\bto\s+your\b[\s\S]{0,80}\b(?:a\/?c\.?|account)\b/i.test(text);
}

// Some issuers describe an account payment as
// "Sent ... From <bank> A/C *1797 To <recipient>". An own-account
// destination is a transfer; an explicit person or merchant destination is
// money out and counts as spend.
function parseBuiltInAccountTransfer(sms) {
  const body = String(sms?.body || '');
  const explicitOwnTransfer = isExplicitOwnAccountTransfer(body);
  if (!isSuccessfulSpend(body)) {
    return { ok: false, reason: 'no_account_transfer_match' };
  }

  const sourceMatch = body.match(
    /\bfrom\b[\s\S]{0,80}?\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+(?:with|in))?|last\s*4)\s*)?[*xX.\s-]*\d{4}\b/i,
  ) || body.match(
    /\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+(?:with|in))?|last\s*4)\s*)?[*xX.\s-]*\d{4}\b(?=[\s\S]{0,35}\b(?:debited|sent|transferred|paid)\b)/i,
  );
  if (!sourceMatch) return { ok: false, reason: 'no_transfer_source_account' };

  const afterSource = body.slice(sourceMatch.index + sourceMatch[0].length);
  const recipientMatch = afterSource.match(
    /\b(?:to|towards?)\s+([A-Za-z][A-Za-z0-9 .&'\/-]{1,100}?)(?=\s+\b(?:on|ref(?:erence)?|txn(?:action)?|not\s+you|call|sms\s+block|via|upi|bal(?:ance)?|available|avl)\b|\s+[*xX-]*\d{4}\b|[.,;]|$)/i,
  );
  if (!recipientMatch && !/\bself[ -]?transfer\b/i.test(body)) {
    return { ok: false, reason: 'no_transfer_destination' };
  }

  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_transfer_amount' };
  const accountLast4 = extractAccountLast4(body);
  if (!accountLast4) return { ok: false, reason: 'no_transfer_source_suffix' };

  // Bank alerts commonly omit "your" and say simply
  // "from A/c XX2626 to HDFC Bank A/c XX9080". The destination account
  // suffix is stronger evidence than the recipient bank name alone. Treat it
  // as a transfer candidate so the debit cannot inflate spending; a later
  // account-pair matcher can confirm ownership when both account legs exist.
  const destinationAccountMatch = afterSource.match(
    /\b(?:to|towards?)\b[\s\S]{0,100}?\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending\s+with|last\s*4)\s*)?[*xX-]*(\d{4})\b/i,
  );
  const destinationAccountLast4 = destinationAccountMatch?.[1] || null;
  const accountToAccountCandidate = Boolean(destinationAccountLast4);
  const transferParty = recipientMatch?.[1]?.trim() || 'own account';
  // A UPI/QR debit to the owner's own name is a self transfer even when the
  // SMS says no "self transfer" words.
  const ownNameTransfer = isOwnPersonName(transferParty, sms?.ownUserName);
  const ownTransfer = explicitOwnTransfer
    || accountToAccountCandidate
    || ownNameTransfer;
  const transferKind = explicitOwnTransfer || ownNameTransfer
    ? 'account_to_account'
    : accountToAccountCandidate
    ? 'account_to_account_candidate'
    : 'payment_to_person';

  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  const referenceMatch = body.match(/\b(?:ref(?:erence)?|txn(?:\s*id)?)\s*(?:no\.?|id)?\s*[:#-]?\s*([A-Za-z0-9-]{6,})/i);

  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_account_transfer',
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      merchant: ownNameTransfer ? 'Transfer between own accounts' : 'Transfer to ' + transferParty,
      transferParty,
      transferKind,
      accountLast4,
      ...(destinationAccountLast4 ? { destinationAccountLast4 } : {}),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(referenceMatch ? { reference: referenceMatch[1] } : {}),
      instrument: 'upi_bank',
      entryKind: ownTransfer ? 'transfer' : 'spend',
    }, body),
  };
}

// Bank-account credit alerts are the incoming counterpart to the debit
// parsers above. Keep this deliberately conservative: a positive credit must
// be explicit, tied to an account/bank (or a named refund/cashback), and must
// not mention a credit-card bill. This prevents balances, card offers, and
// generic "credit" language from becoming fake income.
function parseBuiltInAccountCredit(sms) {
  const body = String(sms?.body || '');
  if (isSecurityOrOtpMessage(body)) return { ok: false, reason: 'security_message' };
  if (/\b(?:credit|debit)\s+card\b/i.test(body)) {
    return { ok: false, reason: 'credit_card_message' };
  }

  // Incoming receipts must describe a completed movement, not a promise.
  if (/\b(?:declined|failed|failure|cancelled|canceled|pending|processing|initiated)\b/i.test(body)
      || /\b(?:will|shall|would|to)\s+be\s+(?:credited|received|deposited|refunded|reversed)\b/i.test(body)
      || /\b(?:not|never)\s+(?:been\s+)?(?:credited|received|deposited|refunded|reversed)\b/i.test(body)
      || isNonTransactionAlert(body)) {
    return { ok: false, reason: 'not_a_completed_credit' };
  }

  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_account_credit_match' };

  const incomingMarker = /\b(?:credited|received|deposited|refunded|reversed)\b/i.test(body)
    // "We have transferred Rs X to your bank account" is the same event with
    // a passive transferred verb; only allow it when the target is the
    // user's own account so debit phrasing never mines false credits.
    || /\btransferred\b[\s\S]{0,30}\bto\s+(?:your|the\s+user'?s)\b/i.test(body);
  const accountEvidence = /\b(?:a\/?c\.?|account|savings|bank|wallet)\b/i.test(body);
  const namedIncoming = /\b(?:money|amount|payment|funds?)\b[\s\S]{0,40}\b(?:received|credited|deposited)\b/i.test(body);
  if (!incomingMarker || (!accountEvidence && !namedIncoming)) {
    return { ok: false, reason: 'no_account_credit_match' };
  }

  // A balance announcement is not itself an incoming transaction.
  if (/\b(?:available|closing|current|clr|new|available\s+balance|bal(?:ance)?)\b[\s\S]{0,30}\b(?:is|:|of)\b/i.test(body)
      && !/\b(?:credited|received|deposited|salary|cashback|refund|reversal)\b/i.test(body)) {
    return { ok: false, reason: 'balance_only_alert' };
  }

  const accountReferences = body.match(/\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+(?:with|in))?|last\s*4)\s*)?[*xX.\s-]*\d{4}\b/gi) || [];
  const destinationAccount = body.match(/\bto\s+your\b[\s\S]{0,70}\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*[*xX-]*\s*(\d{4})\b/i);
  const creditedAccount = body.match(/\b(?:credited|received|deposited)\b[\s\S]{0,70}\b(?:to|into|in)\s+(?:(?:your|the)\s+)?(?:[A-Za-z]+\s+){0,3}(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*[*xX-]*\s*(\d{4})\b/i);
  const partyMatch = body.match(/\b(?:from|by|via)\s+(?!(?:₹|rs\.?|inr)(?:\b|\s|\d)|\d+[\s.,])([A-Za-z][A-Za-z0-9 .&'@_/-]{1,80}?)(?=\s+(?:on|for|ref(?:erence)?|txn|utr|a\/?c\.?|account|bal(?:ance)?|avl|available)\b|[.,;]|$)/i);
  // Money received from the owner's own name is the other leg of a UPI/QR
  // self transfer — not earned income and not an unclassified credit.
  const ownTransfer = isExplicitOwnAccountTransfer(body)
    || isOwnPersonName(partyMatch?.[1]?.trim(), sms?.ownUserName);
  const accountLast4 = creditedAccount?.[1]
    || (ownTransfer && destinationAccount ? destinationAccount[1] : extractAccountLast4(body));
  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  const referenceMatch = body.match(/\b(?:ref(?:erence)?|txn(?:\s*id)?|utr)\s*(?:no\.?|id)?\s*[:#-]?\s*([A-Za-z0-9-]{6,})/i);
  const lower = body.toLowerCase();
  const salaryCredit = /\bsalary\b/i.test(body);
  const nonIncomeCredit = /\b(?:refund(?:ed)?|chargeback|reversal|reversed|cashback|reward|rewards|points?|miles?|loan|personal\s+loan|credit\s+line|investment|mutual\s+fund|shares|equity\s+shares?|stocks?|demat|portfolio|cash\s+deposit|gift|reimburse(?:ment|d)?|expense\s+claim)\b/i.test(body);
  const earnedIncomeCredit = !nonIncomeCredit
    && !/\bsalary\s+advance\b/i.test(body)
    && /\b(?:salary|wages?|payroll|pension|interest|dividend|rent|commission|consulting|business\s+(?:receipt|income)|invoice\s+paid)\b/i.test(body);
  const cashbackCredit = /\bcashback\b/i.test(body);
  const rewardCredit = /\b(?:reward|rewards|points?|miles?)\b/i.test(body);
  const refundCredit = /\b(?:refund(?:ed)?|chargeback)\b/i.test(body);
  const reversalCredit = /\b(?:reversal|reversed)\b/i.test(body);
  const loanDisbursement = /\b(?:loan|personal\s+loan|salary\s+advance|credit\s+line)\b[\s\S]{0,70}\b(?:credited|received|disbursed|disbursement)\b/i.test(body);
  const investmentProceeds = /\b(?:redeemed?|redemption|sold|sale\s+proceeds?|withdrawn?)\b[\s\S]{0,80}\b(?:mutual\s+fund|sip|investment|shares?|stocks?|equity|zerodha|groww|upstox|angel\s+one|dhan|demat|portfolio)\b/i.test(body)
    || /\b(?:mutual\s+fund|sip|investment|shares?|stocks?|equity|zerodha|groww|upstox|angel\s+one|dhan|demat|portfolio)\b[\s\S]{0,80}\b(?:redeemed?|redemption|sold|sale\s+proceeds?|withdrawn?)\b/i.test(body);
  const cashDeposit = /\bcash\s+(?:deposit|deposited)\b/i.test(body);
  const giftCredit = /\b(?:gift|gifted|present)\b/i.test(body);
  const reimbursementCredit = /\b(?:reimburse(?:ment|d)?|expense\s+claim)\b/i.test(body);
  const brokerSettlement = isBrokerSettlementMessage(body);
  const walletLoad = !brokerSettlement && isWalletLoadMessage(body);
  const incomingBankTransferCandidate = !ownTransfer
    && !walletLoad
    && !brokerSettlement
    && !earnedIncomeCredit
    && !cashbackCredit
    && !rewardCredit
    && !refundCredit
    && !reversalCredit
    && !loanDisbursement
    && !investmentProceeds
    && !cashDeposit
    && !giftCredit
    && !reimbursementCredit
    && (/\bfrom\b[\s\S]{0,80}\b(?:bank|a\/?c\.?|account)\b/i.test(body)
      // Two masked account references identify a movement between accounts,
      // even when the credit alert does not say "own" or "self". Keep it as
      // a transfer candidate until the opposite debit is paired.
      || accountReferences.length >= 2);
  const transferKind = ownTransfer
    ? 'account_to_account'
    : brokerSettlement
    ? 'investment_proceeds'
    : walletLoad
    ? 'wallet_load'
    : refundCredit
    ? 'refund'
    : reversalCredit
    ? 'reversal'
    : cashbackCredit || rewardCredit
    ? 'reward'
    : loanDisbursement
    ? 'loan_disbursement'
    : investmentProceeds
    ? 'investment_proceeds'
    : cashDeposit
    ? 'cash_deposit'
    : giftCredit
    ? 'gift_received'
    : reimbursementCredit
    ? 'reimbursement'
    : incomingBankTransferCandidate
    ? 'incoming_bank_transfer_candidate'
    : 'unclassified_credit';
  const rawParty = partyMatch?.[1]?.trim();
  const partyIsBankingChannel = rawParty && /^(?:mob(?:ile)?\s*(?:bk|banking)|net\s*(?:bk|banking)|internet\s*banking|upi|imps|neft|rtgs|yono|rinb|inb|sbi|vpa|rs\.?|inr|re\.?|\d+)$/i.test(rawParty);
  const merchant = ownTransfer
    ? 'Transfer between own accounts'
    : brokerSettlement
    ? 'Investment proceeds'
    : walletLoad
    ? 'Wallet load'
    : refundCredit
    ? 'Refund'
    : reversalCredit
    ? 'Reversal'
    : cashbackCredit || rewardCredit
    ? 'Reward or cashback'
    : loanDisbursement
    ? 'Loan disbursement'
    : investmentProceeds
    ? 'Investment proceeds'
    : cashDeposit
    ? 'Cash deposit'
    : giftCredit
    ? 'Gift received'
    : reimbursementCredit
    ? 'Reimbursement'
    : incomingBankTransferCandidate
    ? 'Bank transfer'
    : salaryCredit
    ? 'Salary'
    : (!partyIsBankingChannel && rawParty) || 'Money received';

  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_account_credit',
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      merchant,
      ...(accountLast4 ? { accountLast4 } : {}),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(referenceMatch ? { reference: referenceMatch[1] } : {}),
      instrument: /\b(?:wallet|cashback)\b/i.test(lower) ? 'wallet' : 'upi_bank',
      ...(!earnedIncomeCredit || ownTransfer || incomingBankTransferCandidate || walletLoad || brokerSettlement
        ? { transferKind }
        : {}),
      entryKind: earnedIncomeCredit && !ownTransfer ? 'income' : 'transfer',
    }, body),
  };
}

// Some bank-account transfer alerts do not say "UPI". They identify a
// beneficiary with a bank-specific label such as "Fvg:" (favouring) and
// identify the channel as mobile banking. That is enough evidence to import
// the payment as a cardless bank spend, while still keeping a bare account
// debit in the review queue. The transaction remains reward-ineligible until
// it is linked to a card; this only fixes detection and history completeness.
function parseBuiltInBeneficiaryDebit(sms) {
  const body = String(sms?.body || '');
  if (!isSuccessfulSpend(body) || !isBankAccountUpiMessage(body) || /\bupi\b/i.test(body)) {
    return { ok: false, reason: 'no_beneficiary_debit_match' };
  }
  const channelMatch = /\b(?:by\s+mob(?:ile)?\s*(?:bk|bank)|mobile\s+bank(?:ing)?|imps|neft)\b/i.test(body);
  if (!channelMatch) return { ok: false, reason: 'no_beneficiary_debit_match' };

  const beneficiaryMatch = body.match(
    /\b(?:fvg|favou?ring|beneficiary|payee)\s*[:#-]?\s*([A-Za-z][A-Za-z0-9 .&'\/-]{1,80}?)(?=\s+(?:avl|available|bal(?:ance)?|ref(?:erence)?|txn|transaction|on|from)\b|[.,;]|$)/i,
  );
  if (!beneficiaryMatch) return { ok: false, reason: 'no_beneficiary_debit_match' };

  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_beneficiary_debit_match' };
  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  const referenceMatch = body.match(/\b(?:ref(?:erence)?|txn(?:\s*id)?)\s*(?:no\.?|id)?\s*[:#-]?\s*([A-Za-z0-9-]{6,})/i);

  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_beneficiary_debit',
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      merchant: beneficiaryMatch[1].trim(),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(referenceMatch ? { reference: referenceMatch[1] } : {}),
      ...(extractAccountLast4(body) ? { accountLast4: extractAccountLast4(body) } : {}),
      // This is a cardless bank-account debit. Keep it separate from
      // physical-card reward rules; the account suffix is retained only for
      // source-account grouping.
      instrument: 'upi_bank',
      entryKind: 'spend',
    }, body),
  };
}

// When a bank does not include a named beneficiary, the account debit is
// still a real outgoing transaction. Import it cardlessly instead of sending
// the user to a manual queue. A specific merchant/beneficiary parser always
// runs first, so this fallback only supplies a human-readable bank-transfer
// label when the issuer gives us no better name.
function parseBuiltInAccountDebit(sms) {
  const body = String(sms?.body || '');
  if (
    !isSuccessfulSpend(body)
    || !isBankAccountUpiMessage(body)
    || /\bupi\b/i.test(body)
    || /\b(?:credit|debit)\s+card\b/i.test(body)
  ) {
    return { ok: false, reason: 'no_account_debit_match' };
  }

  if (/\bfrom\b[\s\S]{0,80}\b(?:a\/?c\.?|account)\b[\s\S]{0,80}\bto\s+[A-Za-z]/i.test(body)) {
    return { ok: false, reason: 'unverified_account_transfer' };
  }

  // Without a beneficiary or an explicit own-account destination, the debit
  // could be a purchase, loan, transfer, or cash movement. Ask for review.
  const payeeMatch = body.match(/\b(?:at|to|for|fvg|beneficiary|payee)\s+([A-Za-z][A-Za-z0-9 .&'@_/-]{1,80})/i);
  if (!payeeMatch || /^(?:rs|inr|rupees?)(?:\b|$)/i.test(payeeMatch[1])) {
    return { ok: false, reason: 'ambiguous_account_debit' };
  }
  const accountLast4 = extractAccountLast4(body);
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_account_debit_match' };

  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  const referenceMatch = body.match(/\b(?:ref(?:erence)?|txn(?:\s*id)?)\s*(?:no\.?|id)?\s*[:#-]?\s*([A-Za-z0-9-]{6,})/i);
  const walletLoad = isWalletLoadMessage(body);

  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_account_debit',
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      merchant: walletLoad ? 'Wallet load' : 'Bank transfer',
      ...(accountLast4 ? { accountLast4 } : {}),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(referenceMatch ? { reference: referenceMatch[1] } : {}),
      instrument: 'upi_bank',
      ...(walletLoad ? { transferKind: 'wallet_load' } : {}),
      entryKind: walletLoad ? 'transfer' : 'spend',
    }, body),
  };
}

function parseBuiltInWalletSpend(sms) {
  const body = String(sms?.body || '');
  const sender = String(sms?.sender || '');
  if (isSecurityOrOtpMessage(body)) return { ok: false, reason: 'security_message' };
  if (isWalletLoadMessage(body)) return { ok: false, reason: 'wallet_load' };

  const walletDebit = body.match(
    /\b(?:debited\s+from|paid\s+from|deducted\s+from|spent\s+from|debited\s+using)\b[\s\S]{0,35}\b([a-zA-Z0-9]+)\s+wallet\b|\b([a-zA-Z0-9]+)\s+wallet\b[\s\S]{0,35}\b(?:debited|paid|deducted)\b/i
  );
  const isWalletDebit = Boolean(walletDebit) || /\bfrom\s+(?:your\s+)?wallet\b|\bwallet\s+balance\b/i.test(body);
  if (!isWalletDebit) return { ok: false, reason: 'no_wallet_spend_match' };
  if (!isSuccessfulSpend(body)) return { ok: false, reason: 'not_a_successful_spend' };

  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_wallet_spend_amount' };

  const amazonPay = body.match(/\b(Amazon\s+Pay)\s+wallet\b/i)?.[1];
  let rawProvider = walletDebit?.[1] || walletDebit?.[2];
  if (rawProvider && ['your', 'the', 'my', 'a', 'an', 'our'].includes(rawProvider.toLowerCase())) {
    rawProvider = null;
  }
  let walletProvider = amazonPay || rawProvider;
  if (!walletProvider) {
    const senderClean = sender.replace(/^[A-Za-z]{2}-|-[A-Za-z]$/g, '').trim();
    if (/mobikw|mbkwik/i.test(senderClean)) {
      walletProvider = 'MobiKwik';
    } else if (/paytm/i.test(senderClean)) {
      walletProvider = 'Paytm';
    } else if (/amzn|amazon/i.test(senderClean)) {
      walletProvider = 'Amazon Pay';
    } else if (/phonepe/i.test(senderClean)) {
      walletProvider = 'PhonePe';
    } else if (senderClean && senderClean.length <= 12 && !/^\d+$/.test(senderClean)) {
      walletProvider = senderClean;
    } else {
      walletProvider = 'Wallet';
    }
  }

  const merchantMatch = body.match(/\b(?:at|to|for)\s+([A-Za-z0-9][A-Za-z0-9 ._&@-]{1,80}?)(?=\s+(?:from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl)\b|\s*\(|[.,]|$)/i);
  let merchant = merchantMatch ? merchantMatch[1].trim() : null;
  if (merchant && /^(?:your\s+)?(?:\w+\s+)?wallet$/i.test(merchant)) {
    merchant = null;
  }

  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  const referenceMatch = body.match(/\b(?:ref(?:erence)?|txn(?:\s*id)?)\s*(?:no\.?|id)?\s*[:#-]?\s*([A-Za-z0-9-]{6,})/i);

  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_wallet_spend',
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      ...(merchant ? { merchant } : {}),
      accountLast4: walletProvider,
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(referenceMatch ? { reference: referenceMatch[1] } : {}),
      instrument: 'wallet',
      entryKind: 'spend',
    }, body),
  };
}

function inferInstrument(body) {
  const text = String(body || '').toLowerCase();
  const walletDebit = /\b(?:debited\s+from|paid\s+from|deducted\s+from|spent\s+from|debited\s+using)\b[\s\S]{0,35}\b([a-zA-Z0-9]+)\s+wallet\b|\b([a-zA-Z0-9]+)\s+wallet\b[\s\S]{0,35}\b(?:debited|paid|deducted)\b/i.test(text);
  if (walletDebit || /\bfrom\s+(?:your\s+)?wallet\b|\bwallet\s+balance\b/i.test(text)) {
    return 'wallet';
  }
  // An account/UPI debit wins before any generic "debit" wording. The
  // suffix after A/c is an account suffix, never a card last-4.
  if (isBankAccountUpiMessage(text)) return 'upi_bank';
  if (/\bdebit\s+card\b/.test(text)) return 'debit_card';
  // ATM/cash-withdrawal alerts commonly say only "Card x1234" and identify
  // the card as DC in the fraud footer. They are not credit-card purchases.
  if (/\b(?:atm|withdrawn|cash\s+withdrawal)\b/.test(text) && !/\bcredit\s+card\b/.test(text)) return 'debit_card';
  if (/\b(?:block\s+dc|dc\s*\d{4})\b/.test(text) && !/\bcredit\s+card\b/.test(text)) return 'debit_card';
  if (/\bcredit\s+card\b/.test(text)) return 'credit_card';
  // A suffix identifies a card, not its type. Match the device's explicit
  // credit-account evidence; an ordinary balance or bank name is insufficient.
  if (/\bcard\b/.test(text) && /\b(?:avl\.?\s*(?:lmt|limit)|available\s+(?:credit|limit)|credit\s+limit|outstanding|statement|minimum\s+amount\s+due|total\s+amount\s+due|amount\s+due)\b/.test(text)) return 'credit_card';
  return null;
}

function extractMcc(body) {
  const match = String(body || '').match(
    /\b(?:mcc|merchant\s+category(?:\s+code)?)\s*[:#-]?\s*(\d{4})\b/i
  );
  return match ? match[1] : null;
}

function isSuccessfulSpend(body) {
  const text = String(body || '').toLowerCase();
  if (isSecurityOrOtpMessage(text)) return false;
  if (isRejectedTransaction(text)) return false;
  if (isCardBillNotice(text)) return false;
  if (isNonTransactionAlert(text)) return false;
  return /\b(?:spent|debited|debit|paid|purchase|purchased|charged|withdrawn|sent|transferred)\b/.test(text)
    || /\b(?:payment|purchase|transaction)\b[\s\S]{0,80}\b(?:successful|successfully|completed)\b/.test(text)
    // Issuer rewards-accomplishment alerts ("Your txn of ₹1,018 at M on
    // your X card earned you 5% rewards!") carry no standard completion
    // verb. Accept the txn-of-of shape only when it is not a pending
    // attempt (isRejectedTransaction already excludes declined/failed).
    || (/\b(?:your\s+)?txn\s+(?:of|for)\s*(?:₹|rs\.?|inr)?\s*[\d,.]+/.test(text)
        && !/\b(?:initiated|pending|processing|in\s+progress|in\s+process)\b/.test(text))
    || isWalletLoadMessage(text);
}

function isAxioPayLaterSender(sender) {
  return /axio/i.test(String(sender || ''));
}

// Amazon Pay Later (Axio) credit drawdown: the user consumed Pay Later balance
// at a merchant. These messages use "availing/availed Pay Later credit of Rs X"
// without a standard debit verb, so the generic grammar drops them without this
// dedicated handler. Must run before isNonTransactionNoise so it is not
// swallowed by the repaymentCourtesyOrLoanUpsell noise guard.
function parseBuiltInPayLaterDrawdown(sms) {
  if (!isAxioPayLaterSender(sms?.sender)) return { ok: false, reason: 'not_axio_sender' };
  const body = String(sms?.body || '');
  const m = body.match(/\bavail(?:ing|ed)\s+(?:(?:amazon\s+)?pay\s+later\s+)?credit\s+of\s+(?:Rs\.?\s*)(\d+(?:\.\d+)?)/i);
  if (!m) return { ok: false, reason: 'no_pay_later_drawdown_match' };
  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_pay_later_drawdown',
    fields: {
      amountInr: parseFloat(m[1]),
      merchant: 'Amazon Pay Later',
      entryKind: 'spend',
      instrument: 'other',
      accountLast4: 'Amazon Pay Later',
    },
  };
}

// Paying a credit-card bill is a movement of money between the user's bank
// account and the card, not a new merchant purchase. Some issuers phrase the
// alert as "payment received towards your credit card" and some as an account
// debit towards the card bill. Only the explicit card-payment direction is
// accepted here; a normal purchase made *on* a credit card must remain spend.
function parseBuiltInCardBillPayment(sms) {
  const body = String(sms?.body || '');
  if (isSecurityOrOtpMessage(body)) return { ok: false, reason: 'security_message' };
  if (/\b(?:payment|amount|minimum)\s+due\b|\bdue\s+on\b/i.test(body)
      && !/\b(?:paid|payment)\s+(?:successfully|completed)\b|\bpayment\s+received\b/i.test(body)) {
    return { ok: false, reason: 'card_bill_reminder' };
  }
  const lower = body.toLowerCase();
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_card_bill_payment_match' };

  const towardCard = /\b(?:payment|amount)\b[\s\S]{0,90}\b(?:received|credited)\b[\s\S]{0,90}\btowards?\b[\s\S]{0,50}\bcredit\s+card\b/i.test(body)
    || /\b(?:payment|paid|debited|debit)\b[\s\S]{0,90}\btowards?\b[\s\S]{0,50}\b(?:your\s+)?credit\s+card(?:\s+bill|\s+account)?\b/i.test(body)
    || /\bcredit\s+card\s+(?:bill|payment)\b[\s\S]{0,90}\b(?:received|credited|debited|paid|successful|completed)\b/i.test(body)
    || /\b(?:paid|payment|debited)\b[\s\S]{0,90}\b(?:to|for)\s+(?:(?:your|the|axis|hdfc|icici|sbi|bank|flipkart)\s+){0,5}credit\s+card(?:\s+bill)?\b/i.test(body)
    // A normal purchase can say "payment ... on your credit card ...
    // successful". Only the explicit bill form is safe here; generic
    // payment wording is handled above when it says received/credited/
    // towards.
    || /\bbill\b[\s\S]{0,60}\b(?:for|on|of)\s+(?:(?:your|the|axis|hdfc|icici|sbi|bank|flipkart)\s+){0,5}credit\s+card\b[\s\S]{0,90}\b(?:paid|received|successful|completed)\b/i.test(body)
    // Issuer and bill-pay apps often abbreviate the same event as CC PMT,
    // CARD BILL PAY, or "towards your card" without the words credit card.
    || /\b(?:card\s+bill\s*(?:payment|pmt)|cc\s*(?:bill\s*)?(?:payment|pmt)|card\s+bill\s+pay)\b[\s\S]{0,90}\b(?:paid|received|debited|successful|completed|credited)\b/i.test(body)
    || /\b(?:payment|paid|debited|debit|transferred)\b[\s\S]{0,90}\b(?:towards?|for|to)\s+(?:your\s+)?(?:card|cc)\b/i.test(body)
    || /\b(?:imps|neft|upi)\b[\s\S]{0,80}\b(?:cc|credit\s+card)\s*(?:bill\s*)?(?:pmt|payment)\b/i.test(body);
  if (!towardCard) return { ok: false, reason: 'no_card_bill_payment_match' };

  const last4Match = body.match(/\b(?:credit\s+card|card)\b[\s\S]{0,50}?(?:ending(?:\s+with)?|x{1,4}|\*{1,4}|last\s*4|no\.?)\D{0,5}(\d{4})\b/i);
  const instrument = /\b(?:a\/?c\.?|account|savings)\b[\s\S]{0,60}\b(?:debited|debit|paid)\b/i.test(lower)
    ? 'upi_bank'
    : 'other';
  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_card_bill_payment',
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      ...(last4Match ? { last4: last4Match[1] } : {}),
      merchant: 'Credit card bill payment',
      transferKind: 'card_bill',
      instrument,
      entryKind: 'transfer',
    }, body),
  };
}

// A card issuer can also report a refund, reversal, cashback, or generic
// statement credit against the card liability. These are real adjustments to
// the card account, but they are never a new purchase or earned income. Keep
// them as transfer rows so the event remains visible without inflating either
// total. Card bill receipts are intentionally handled by the bill-payment
// parser above and must win first.
function parseBuiltInCardCredit(sms) {
  const body = String(sms?.body || '');
  if (isSecurityOrOtpMessage(body) || !/\b(?:credit|debit)\s+card\b|\bcard\b/i.test(body)) {
    return { ok: false, reason: 'no_card_credit_match' };
  }
  if (/\b(?:payment|amount|minimum)\s+due\b|\bdue\s+on\b/i.test(body)) {
    return { ok: false, reason: 'card_bill_reminder' };
  }
  if (/\b(?:declined|failed|pending|processing|initiated|cancelled|canceled)\b/i.test(body)
      && !/\b(?:reversed|refunded|credited)\b/i.test(body)) {
    return { ok: false, reason: 'not_a_completed_card_credit' };
  }
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_card_credit_match' };
  const adjustmentMarker = /\b(?:credited|received|refunded|refund|cashback|reward|statement\s+credit|balance\s+adjustment)\b/i.test(body)
    || (/\b(?:reversed|reversal)\b/i.test(body) && /\b(?:posted|applied|credited)\b/i.test(body));
  if (!adjustmentMarker) {
    return { ok: false, reason: 'no_card_credit_match' };
  }
  const refund = /\b(?:refund(?:ed)?|reversed?|chargeback)\b/i.test(body);
  const reward = /\b(?:cashback|reward|rewards|points?|miles?)\b/i.test(body);
  const transferKind = refund ? 'refund' : reward ? 'reward' : /\breversed?|reversal\b/i.test(body) ? 'reversal' : 'card_adjustment';
  const last4Match = body.match(/\b(?:credit\s+card|card)\b[\s\S]{0,50}?(?:ending(?:\s+with)?|x{1,4}|\*{1,4}|last\s*4|no\.?)\D{0,5}(\d{4})\b/i);
  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_card_credit',
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      ...(last4Match ? { last4: last4Match[1] } : {}),
      merchant: refund ? 'Refund' : reward ? 'Reward or cashback' : transferKind === 'reversal' ? 'Reversal' : 'Card statement adjustment',
      transferKind,
      instrument: inferInstrument(body) || 'other',
      entryKind: 'transfer',
    }, body),
  };
}

function parseBuiltInNonSpendDebit(sms) {
  const body = String(sms?.body || '');
  if (!isSuccessfulSpend(body)) return { ok: false, reason: 'no_non_spend_debit' };
  const cashWithdrawal = /\b(?:cash\s+withdrawal|withdrawn\s+from\b[\s\S]{0,50}\bcard|withdrawn\s+(?:from|at)\s+(?:an?\s+)?atm|atm\b[\s\S]{0,60}\bwithdrawn|atm\s+(?:txn|transaction|w\/d))\b/i.test(body);
  const feeCharge = !cashWithdrawal && /\b(?:bank\s+charge|service\s+charge|processing\s+fee|convenience\s+fee|late\s+fee|annual\s+fee|maintenance\s+fee|finance\s+charge|interest\s+charge|interest\s+(?:on\s+)?(?:loan|emi)|(?:loan|emi)\s+interest|commission|brokerage\s+fee|gst\s+on\s+(?:fee|charge))\b/i.test(body);
  const loanRepayment = !cashWithdrawal && !feeCharge && /\b(?:loan|personal\s+loan|home\s+loan|car\s+loan|education\s+loan|emi|equated\s+monthly\s+installment|instalment)\b[\s\S]{0,90}\b(?:paid|payment|debited|repaid|repayment|deducted|transferred)\b/i.test(body);
  const investment = !cashWithdrawal
    && !loanRepayment
    && !feeCharge
    && isInvestmentFundingMessage(body);
  if (!cashWithdrawal && !loanRepayment && !feeCharge && !investment) return { ok: false, reason: 'no_non_spend_debit' };
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_non_spend_amount' };
  const last4Match = body.match(/\b(?:card)\b[\s\S]{0,45}?(?:ending(?:\s+with)?|x{1,4}|\*{1,4}|last\s*4|no\.?)\D{0,5}(\d{4})\b/i);
  const accountLast4 = extractAccountLast4(body);
  return {
    ok: true,
    patternId: null,
    parserKind: cashWithdrawal
      ? 'builtin_cash_withdrawal'
      : loanRepayment
      ? 'builtin_loan_repayment'
      : feeCharge
      ? 'builtin_fee_charge'
      : 'builtin_investment_debit',
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      merchant: cashWithdrawal
        ? 'Cash withdrawal'
        : loanRepayment
        ? 'Loan or EMI repayment'
        : feeCharge
        ? 'Bank or service fee'
        : 'Investment contribution',
      ...(last4Match ? { last4: last4Match[1] } : {}),
      ...(accountLast4 ? { accountLast4 } : {}),
      instrument: cashWithdrawal && last4Match ? 'debit_card' : 'upi_bank',
      ...(cashWithdrawal ? { transferKind: 'cash_withdrawal' } : {}),
      ...(loanRepayment ? { transferKind: 'loan_repayment' } : {}),
      ...(feeCharge ? { transferKind: 'fee' } : {}),
      entryKind: cashWithdrawal || loanRepayment ? 'transfer' : feeCharge ? 'spend' : 'investment',
    }, body),
  };
}

function parseInvestmentFolioAllotment(sms) {
  const body = String(sms?.body || '');
  if (!isInvestmentFolioAllotment(body)) {
    return { ok: false, reason: 'not_folio_allotment' };
  }
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  const amountInr = amountMatch ? Number(amountMatch[1].replace(/,/g, '')) : null;
  const schemeMatch = body.match(/\b(?:scheme|fund(?:\s+name)?)\s*[:\-]\s*([A-Za-z0-9_][-A-Za-z0-9 .&'/()]{2,60})/i);
  const inFundMatch = body.match(/\bin\s+([A-Za-z0-9][-A-Za-z0-9 .&'/()]{2,60}?)(?=(?:\s+(?:processed|successful|completed|allotted|for\b|at\s+nav|with\s+nav|nav|on\s+\d|folio)|[.,;]|$))/i);
  const towardsMatch = body.match(/\btowards?\s+([A-Za-z0-9][-A-Za-z0-9 .&'/()]{2,60}?)(?=(?:\s+(?:processed|successful|completed|allotted|folio)|[.,;]|$))/i);
  const merchant = schemeMatch?.[1]?.trim() || inFundMatch?.[1]?.trim() || towardsMatch?.[1]?.trim() || null;
  const folioMatch = body.match(/\bfolio(?:\s*no\.?|\s*number)?\s*[:#-]?\s*([A-Za-z0-9/-]+)\b/i)?.[1];

  return {
    ok: false,
    reason: 'mf_folio_unit_allotment',
    isObservation: true,
    fields: {
      ...(amountInr && Number.isFinite(amountInr) ? { amountInr } : {}),
      ...(merchant ? { merchant } : {}),
      ...(folioMatch ? { folio: folioMatch } : {}),
    },
  };
}

/** Broker acknowledgements are investment movements, not income or spend. */
function parseBuiltInInvestmentMovement(sms) {
  const body = String(sms?.body || '');
  if (isInvestmentFolioAllotment(body)) {
    return { ok: false, reason: 'mf_folio_unit_allotment' };
  }
  if (!isInvestmentFundingMessage(body)) {
    return { ok: false, reason: 'no_investment_movement_match' };
  }
  const investmentProceeds = /\b(?:redeemed?|redemption|sold|sale\s+proceeds?|withdrawn?)\b[\s\S]{0,80}\b(?:mutual\s+fund|sip|investment|shares?|stocks?|equity|zerodha|groww|upstox|angel\s+one|dhan|demat|portfolio)\b/i.test(body)
    || /\b(?:mutual\s+fund|sip|investment|shares?|stocks?|equity|zerodha|groww|upstox|angel\s+one|dhan|demat|portfolio)\b[\s\S]{0,80}\b(?:redeemed?|redemption|sold|sale\s+proceeds?|withdrawn?)\b/i.test(body);
  if (/\b(?:autopay|auto[- ]?pay|mandate|standing\s+instruction)\b/i.test(body) &&
      (!/\b(?:debited|credited|paid|transferred|invested|purchased|bought|funds?\s+added|money\s+added)\b/i.test(body)
       || /\b(?:txn\s*amt|amount)\s*[:.]?\s*(?:₹|rs\.?|inr)?\s*0(?:\.00?)?\b/i.test(body)
       || /\b(?:max(?:imum)?\s*limit|autopay\s+activation\s+successful)\b/i.test(body))) {
    return { ok: false, reason: 'investment_mandate_setup' };
  }
  if (/\b(?:will|shall|would|to)\s+be\s+(?:added|credited|deposited|transferred)\b/i.test(body)) {
    return { ok: false, reason: 'future_investment_movement' };
  }
  if (/\b(?:declined|failed|failure|cancelled|canceled|pending|processing|reversed|refund(?:ed)?)\b/i.test(body)) {
    return { ok: false, reason: 'unsuccessful_investment_movement' };
  }
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_investment_amount' };
  const amountInr = Number(amountMatch[1].replace(/,/g, ''));
  if (!Number.isFinite(amountInr) || amountInr <= 0) {
    return { ok: false, reason: 'no_investment_amount' };
  }
  const provider = body.match(/\b(?:zerodha|groww|upstox|angel\s+one|dhan|paytm\s+money|indmoney|5paisa|motilal\s+oswal|icici\s+direct|hdfc\s+securities)\b/i)?.[0];
  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  const referenceMatch = body.match(/\b(?:ref(?:erence)?|txn(?:\s*id)?|utr)\s*(?:no\.?|id)?\s*[:#-]?\s*([A-Za-z0-9-]{6,})/i);
  const accountLast4 = extractAccountLast4(body);
  const bankInstrument = /\b(?:upi|imps|neft|rtgs|bank|a\/?c\.?)\b/i.test(body);
  return {
    ok: true,
    patternId: null,
    parserKind: 'builtin_investment_movement',
    fields: withAvailableBalance({
      amountInr,
      merchant: investmentProceeds ? 'Investment proceeds' : provider || 'Investment contribution',
      ...(accountLast4 ? { accountLast4 } : {}),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(referenceMatch ? { reference: referenceMatch[1] } : {}),
      instrument: bankInstrument ? 'upi_bank' : 'other',
      ...(investmentProceeds ? { transferKind: 'investment_proceeds' } : {}),
      entryKind: investmentProceeds ? 'transfer' : 'investment',
    }, body),
  };
}

function parseBuiltInUpiDebit(sms) {
  const body = String(sms?.body || '');
  if (!isSuccessfulSpend(body)) return { ok: false, reason: 'no_builtin_upi_match' };
  const instrument = inferInstrument(body);
  if (instrument !== 'upi_bank') return { ok: false, reason: 'no_builtin_upi_match' };
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_builtin_upi_match' };
  const amountInr = Number(amountMatch[1].replace(/,/g, ''));
  if (!Number.isFinite(amountInr) || amountInr <= 0) return { ok: false, reason: 'no_builtin_upi_match' };
  // UPI alerts commonly put the reference in parentheses immediately after
  // the payee ("to ekart (UPI Ref ...)"). Stop before that metadata so it
  // cannot become part of the merchant name.
  const merchantMatch = body.match(/\bmerchant\s*[:\-]\s*([A-Za-z0-9_][-A-Za-z0-9 ._&@*'/-]{1,80}?)(?=\s+(?:from|for|on|before|is|has|was|processed|successful|completed|approved|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available)\b|\s*\(|[.,;]|$|\r|\n)/i)
    || body.match(/\b(?:created\s+towards|subscription\s+to|initiated\s+by)\s+([A-Za-z0-9_][-A-Za-z0-9 ._&@*'/-]{1,80}?)(?=\s+(?:from|for|on|before|is|has|was|processed|successful|completed|approved|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available)\b|\s*\(|[.,;]|$|\r|\n)/i)
    || body.match(/\b(?:to|at|for)\s+([A-Za-z0-9][A-Za-z0-9 ._&@-]{1,80}?)(?=\s+(?:from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available)\b|\s*\(|[.,]|$)/i);
  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  const referenceMatch = body.match(/\b(?:upi\s*)?(?:ref(?:erence)?|txn(?:\s*id)?)\s*(?:no\.?|id)?\s*[:#-]?\s*([A-Za-z0-9-]{6,})/i);
  const walletLoad = isWalletLoadMessage(body);
  return {
    ok: true,
    patternId: null,
    fields: withAvailableBalance({
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      ...(merchantMatch ? { merchant: merchantMatch[1].trim() } : {}),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(referenceMatch ? { reference: referenceMatch[1] } : {}),
      ...(extractMcc(body) ? { mcc: extractMcc(body) } : {}),
      instrument,
      ...(walletLoad ? { merchant: 'Wallet load', transferKind: 'wallet_load' } : {}),
      entryKind: walletLoad ? 'transfer' : 'spend',
    }, body),
  };
}

/**
 * Does this message announce a card BILL rather than a purchase?
 *
 * An issuer's AutoPay notice states the amount that will be deducted for a
 * card bill ("AutoPay Alert! Your HDFC Bank Credit Card 8708 bill, Total
 * Amt: Rs.10944, will be deducted from your A/C 1797 on 09/OCT/2026"). Read
 * as a spend it invents a transaction for money that has not moved, and it
 * moves the card's limit state with it. The device parser already classifies
 * these as bill obligations; this keeps the server in step.
 */
function isCardBillNotice(body) {
  const text = String(body || '');
  if (/\bauto[-\s]?pay\s+(?:alert|reminder|scheduled|activation)\b/i.test(text)) return true;
  if (/\b(?:autopay\s+activation\s+successful|max(?:imum)?\s*limit)\b/i.test(text)) return true;
  if (/\b(?:txn\s*amt|amount)\s*[:.]?\s*(?:₹|rs\.?|inr)?\s*0(?:\.00?)?\b/i.test(text) &&
      /\b(?:autopay|auto[-\s]?pay|mandate|standing\s+instruction)\b/i.test(text)) return true;
  return (
    /\bwill\s+be\s+(?:auto[-\s]?)?(?:deducted|debited)\b/i.test(text) &&
    /\b(?:credit\s+card|card)\b[\s\S]{0,60}\bbill\b/i.test(text)
  );
}

function parseBuiltInCardSpend(sms) {
  const body = String(sms?.body || '');
  if (isCardBillNotice(body)) return { ok: false, reason: 'card_bill_notice' };
  if (!isSuccessfulSpend(body)) return { ok: false, reason: 'no_builtin_card_match' };
  const last4Match = body.match(/\b(?:credit|debit)\s+card\s+(?:no\.?\s*)?(\d{4})\b/i)
    || body.match(/\b(?:credit|debit)\s+card\b[\s\S]{0,60}?(?:ending(?:\s+with)?|x{1,4}|\*{1,4}|\.{3,}|last\s*4|no\.?)\D{0,5}(\d{4})/i)
    || body.match(/\bcard\s+(?:no\.?\s*)?(\d{4})\b/i)
    || body.match(/\bcard\b[\s\S]{0,40}?(?:ending(?:\s+with)?|x{1,4}|\*{1,4}|\.{3,}|last\s*4|no\.?)\D{0,5}(\d{4})/i);
  if (!last4Match) return { ok: false, reason: 'no_builtin_card_match' };
  const instrument = inferInstrument(body) || 'other';
  if (!['credit_card', 'debit_card', 'other'].includes(instrument)) return { ok: false, reason: 'no_builtin_card_match' };
  const amountMatch = body.match(/(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!amountMatch) return { ok: false, reason: 'no_builtin_card_match' };
  const amountInr = Number(amountMatch[1].replace(/,/g, ''));
  if (!Number.isFinite(amountInr) || amountInr <= 0) return { ok: false, reason: 'no_builtin_card_match' };
  // Some issuers put the merchant immediately after the card suffix:
  // "Card XX9008 on OPENAI *CHATGPT. Avl Limit ...". Prefer that clause,
  // then fall back to the more common "at MERCHANT" form. The candidate
  // must begin with a letter so a later customer-care number cannot become
  // the merchant when the message also contains "to 921...".
  const merchantMatch = body.match(/\bmerchant\s*[:\-]\s*([A-Za-z0-9_][-A-Za-z0-9 ._&@*'/-]{1,80}?)(?=\s+(?:from|for|on|before|is|has|was|processed|successful|completed|approved|avl|available|bal(?:ance)?|if\s+not|to\s+dispute|call|sms\s+block|card|bank|account|a\/c|max\s*limit|txn)\b|\s*\(|[.,;]|$|\r|\n)/i)
    || body.match(/\b(?:created\s+towards|subscription\s+to|initiated\s+by)\s+([A-Za-z0-9_][-A-Za-z0-9 ._&@*'/-]{1,80}?)(?=\s+(?:from|for|on|before|is|has|was|processed|successful|completed|approved|avl|available|bal(?:ance)?|if\s+not|to\s+dispute|call|sms\s+block)\b|\s*\(|[.,;]|$|\r|\n)/i)
    || body.match(/\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\s+\d{1,2}:\d{2}(?::\d{2})?\s*(?:IST\s+)?([A-Za-z_][A-Za-z0-9 &*._'/-]{1,60}?)(?=\s+(?:avl|available|limit|not\s+you|sms\s+block|call)\b|[.;]|$|\r|\n)/i)
    || body.match(/\b(?:credit\s+|debit\s+|bank\s+)?card\b[^.;]{0,40}?\bon\s+([A-Za-z_][A-Za-z0-9 ._&@*'/-]{1,80}?)(?=\s+(?:from|avl|available|bal(?:ance)?|if\s+not|to\s+dispute|call|sms\s+block)\b|[.;]|$)/i)
    || body.match(/\b(?:at|to|for)\s+([A-Za-z_][A-Za-z0-9 ._&@-]{1,80}?)(?=\s+(?:from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block|was|is|has|successful|completed)\b|[.,]|$)/i);
  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  return {
    ok: true,
    patternId: null,
    fields: {
      amountInr: Number(amountMatch[1].replace(/,/g, '')),
      last4: last4Match[1],
      ...(merchantMatch ? { merchant: merchantMatch[1].trim().replace(/^_+/, '') } : {}),
      ...(dateMatch ? { date: dateMatch[1] } : {}),
      ...(extractMcc(body) ? { mcc: extractMcc(body) } : {}),
      instrument,
      entryKind: 'spend',
    },
  };
}

/**
 * Does `sender` match a pattern's `sender_pattern`? sender_pattern is a
 * plain substring/prefix match (e.g. 'HDFCBK' matching 'VM-HDFCBK-S' or
 * 'AD-HDFCBK'), NOT a regex — these values come from admin-entered short
 * alphanumeric SMS sender IDs, not attacker-controlled input, but treating
 * them as literal text (not compiled as regex) avoids any surprise from a
 * stray regex metacharacter in an admin's typo.
 */
function senderMatches(senderPattern, sender) {
  if (!senderPattern) return true; // no restriction configured
  if (!sender) return false;
  return sender.toUpperCase().includes(senderPattern.toUpperCase());
}

/**
 * Parse one SMS body against one parser_patterns row.
 *
 * @param {{regex: string, field_map: object, sender_pattern?: string}} pattern
 * @param {{body: string, sender?: string}} sms
 * @returns {{ok: true, fields: {amountInr?: number, merchant?: string, last4?: string, date?: string}}
 *          | {ok: false, reason: string}}
 */
function parseSms(pattern, sms) {
  if (!pattern || typeof pattern.regex !== 'string' || !pattern.regex) {
    return { ok: false, reason: 'invalid_pattern' };
  }
  if (!sms || typeof sms.body !== 'string' || !sms.body.trim()) {
    return { ok: false, reason: 'empty_body' };
  }
  if (sms.body.length > MAX_MESSAGE_LENGTH) {
    return { ok: false, reason: 'body_too_long' };
  }
  if (isSecurityOrOtpMessage(sms.body)) {
    return { ok: false, reason: 'security_message' };
  }
  if (!senderMatches(pattern.sender_pattern, sms.sender)) {
    return { ok: false, reason: 'sender_mismatch' };
  }

  let re;
  try {
    re = new RegExp(pattern.regex);
  } catch (err) {
    return { ok: false, reason: 'invalid_regex' };
  }

  const match = re.exec(sms.body);
  if (!match) {
    return { ok: false, reason: 'no_regex_match' };
  }

  const fieldMap = pattern.field_map || {};
  const fields = {};

  for (const fieldName of KNOWN_FIELDS) {
    const groupIndex = fieldMap[fieldName];
    if (groupIndex === undefined || groupIndex === null) continue;
    const raw = match[groupIndex];
    if (raw === undefined) {
      // field_map points at a group the regex doesn't have / didn't
      // capture in this instance — a malformed pattern, not a partial win.
      return { ok: false, reason: `missing_capture_for_${fieldName}` };
    }

    if (fieldName === 'amount') {
      const cleaned = raw.replace(/,/g, '').trim();
      const amount = Number(cleaned);
      if (!Number.isFinite(amount) || amount <= 0) {
        return { ok: false, reason: 'unparseable_amount' };
      }
      fields.amountInr = amount;
    } else if (fieldName === 'last4') {
      const digits = raw.trim();
      if (!/^\d{4}$/.test(digits)) {
        return { ok: false, reason: 'unparseable_last4' };
      }
      fields.last4 = digits;
    } else if (fieldName === 'date') {
      fields.date = raw.trim();
    } else if (fieldName === 'merchant') {
      const merchant = raw.trim();
      if (!merchant) {
        return { ok: false, reason: 'unparseable_merchant' };
      }
      fields.merchant = merchant;
    } else if (fieldName === 'mcc') {
      const mcc = raw.trim();
      if (!/^\d{4}$/.test(mcc)) return { ok: false, reason: 'unparseable_mcc' };
      fields.mcc = mcc;
    } else if (fieldName === 'availableBalance' || fieldName === 'balance') {
      const cleaned = raw.replace(/,/g, '').trim();
      const balance = Number(cleaned);
      if (!Number.isFinite(balance) || balance < 0) {
        return { ok: false, reason: 'unparseable_available_balance' };
      }
      fields.availableBalanceInr = balance;
    } else if (fieldName === 'instrument' || fieldName === 'reference' || fieldName === 'direction') {
      const value = raw.trim();
      if (!value) return { ok: false, reason: `unparseable_${fieldName}` };
      fields[fieldName] = value;
    }
  }

  if (fields.amountInr === undefined) {
    // Amount is the one field every downstream consumer (cap/milestone/
    // points math in POST /transactions) requires — a pattern that doesn't
    // even map "amount" is not usable, regardless of what else it captured.
    return { ok: false, reason: 'no_amount_field_mapped' };
  }

  const direction = String(fields.direction || '').toLowerCase();
  if (direction && /credit|refund|reversal|failed|declin/.test(direction)) {
    return { ok: false, reason: 'not_a_successful_spend' };
  }
  if (!direction && !isSuccessfulSpend(sms.body)) {
    return { ok: false, reason: 'not_a_successful_spend' };
  }
  if (isBankAccountUpiMessage(sms.body)) {
    // Never carry an account suffix into transaction.last4. It could match a
    // user's unrelated card and silently corrupt card attribution.
    delete fields.last4;
    fields.instrument = 'upi_bank';
    const accountLast4 = extractAccountLast4(sms.body);
    if (accountLast4) fields.accountLast4 = accountLast4;
    const availableBalance = extractAvailableBalance(sms.body);
    if (availableBalance !== null) fields.availableBalanceInr = availableBalance;
  } else {
    // Raw-message evidence is stronger than a pattern's mapped instrument.
    // This prevents a stale/broad pattern from turning a debit-card alert
    // into a credit-card spend merely because its field_map says
    // `instrument=credit_card`.
    const inferredInstrument = inferInstrument(sms.body);
    const mappedInstrument = String(fields.instrument || '').trim().toLowerCase();
    fields.instrument = inferredInstrument
      || (['credit_card', 'debit_card'].includes(mappedInstrument) ? mappedInstrument : null)
      || 'other';
  }
  fields.entryKind = 'spend';
  return { ok: true, fields };
}

/**
 * Try a raw SMS against a list of candidate parser_patterns (already
 * filtered to `channel = 'sms', is_active = true` by the caller's SQL — this
 * function doesn't touch the DB), highest-priority first. `patterns` should
 * be pre-sorted by whatever the caller considers priority (e.g. version
 * DESC); this just returns the first one that matches, or a failure
 * carrying the last-tried reason if none did.
 *
 * @param {Array<object>} patterns
 * @param {{body: string, sender?: string}} sms
 */
function parseConservativeBankSpend(sms) {
  if (!sms || typeof sms.body !== 'string' || !sms.body.trim()) {
    return { ok: false, reason: 'empty_body' };
  }
  if (sms.body.length > MAX_MESSAGE_LENGTH) {
    return { ok: false, reason: 'body_too_long' };
  }

  const body = sms.body.replace(/\s+/g, ' ').trim();
  const lower = body.toLowerCase();

  // These are opposite/non-spend events or secrets. A generic fallback must
  // prefer a missed import over turning any of them into spend.
  if (isNonTransactionAlert(body)
      || /\b(otp|one[ -]?time password|verification code|payment due|amount due|minimum due|credited|refund(?:ed)?|reversal|reversed|declined|failed|cancelled)\b/i.test(body)) {
    return { ok: false, reason: 'non_spend_or_sensitive_message' };
  }
  if (isCardBillNotice(body)) {
    return { ok: false, reason: 'card_bill_notice' };
  }
  if (!/\b(spent|spend|debited|purchase|purchased|used|transaction|txn)\b/i.test(body)) {
    return { ok: false, reason: 'no_spend_marker' };
  }
  // Require card context, but leave the card type unknown without evidence.
  if (!/\b(card|credit card)\b/i.test(body)) {
    return { ok: false, reason: 'no_card_marker' };
  }

  const currencyAmount = body.match(/(?:₹|\bINR\b|\bRS\.?)(?:\s*:?\s*)([0-9][0-9,]*(?:\.\d{1,2})?)/i);
  if (!currencyAmount) return { ok: false, reason: 'no_amount_found' };
  const amountInr = Number(currencyAmount[1].replace(/,/g, ''));
  if (!Number.isFinite(amountInr) || amountInr <= 0) {
    return { ok: false, reason: 'unparseable_amount' };
  }

  const last4 = body.match(/(?:ending|end(?:ing)?\s+in|xx+|x{2,}|card\s*(?:no\.?|number)?\s*[*x-]*)\s*([0-9]{4})\b/i);
  const fields = {
    amountInr,
    // Keep the fallback conservative, but preserve an explicit debit-card
    // signal so a purchase on a debit card is not labelled as credit-card
    // spend before the richer built-in parser gets a chance to run.
    instrument: inferInstrument(body) || 'other',
    entryKind: 'spend',
  };
  if (last4) fields.last4 = last4[1];

  const merchant = body.match(/\bmerchant\s*[:\-]\s*([A-Za-z0-9_][-A-Za-z0-9 &*._'/-]{1,60}?)(?=\s+(?:on|using|via|ref|txn|avl|available|bal(?:ance)?|if\s+not|to\s+dispute|call|sms\s+block)\b|[.;]|$|\r|\n)/i)
    || body.match(/\b(?:created\s+towards|subscription\s+to|initiated\s+by)\s+([A-Za-z0-9_][-A-Za-z0-9 &*._'/-]{1,60}?)(?=\s+(?:on|using|via|ref|txn|avl|available|bal(?:ance)?|if\s+not|to\s+dispute|call|sms\s+block)\b|[.;]|$|\r|\n)/i)
    || body.match(/\b(?:credit\s+|debit\s+|bank\s+)?card\b[^.;]{0,40}?\bon\s+([A-Za-z_][A-Za-z0-9 &*._'/-]{1,60}?)(?=\s+(?:on|using|via|ref|txn|avl|available|bal(?:ance)?|if\s+not|to\s+dispute|call|sms\s+block)\b|[.;]|$)/i)
    || body.match(/\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\s+\d{1,2}:\d{2}(?::\d{2})?\s*(?:IST\s+)?([A-Za-z_][-A-Za-z0-9 &*._'/-]{1,60}?)(?=\s+(?:avl|available|limit|not\s+you|sms\s+block|call)\b|[.;]|$|\r|\n)/i)
    || body.match(/\b(?:at|to)\s+([A-Za-z0-9_][A-Za-z0-9 &*._'/-]{1,60}?)(?=\s+(?:on|using|via|ref|txn|avl|available|bal(?:ance)?|if\s+not|to\s+dispute|call|sms\s+block|for\s+card)\b|[.;]|$)/i);
  if (merchant) {
    const value = merchant[1].trim().replace(/^_+/, '').replace(/[.,;:-]+$/, '').trim();
    if (value && !/^(your|card|account|a\/c)$/i.test(value) && !/^\+?\d[\d\s-]{5,}$/.test(value)) fields.merchant = value;
  }

  const dateMatch = body.match(/\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3,})[-/.]\d{2,4})\b/);
  if (dateMatch) fields.date = dateMatch[1];

  return { ok: true, fields, parserKind: 'conservative_fallback' };
}

function patternPriority(pattern, result) {
  const mappedFields = Object.keys(result.fields || {}).length;
  const senderSpecific = pattern.sender_pattern ? 1000 : 0;
  const version = Number(pattern.version) || 0;
  return senderSpecific + mappedFields * 100 + version;
}

// A configured pattern can identify a payment without mapping its payee.
// Reuse the card parser only for the missing display field, and only when its
// amount, card suffix and instrument agree with the accepted parse.
function enrichMissingCardMerchant(result, sms) {
  if (!result.ok || result.fields?.merchant) return result;
  const card = parseBuiltInCardSpend(sms);
  if (!card.ok || !card.fields.merchant) return result;
  const fields = result.fields;
  if (fields.amountInr !== card.fields.amountInr ||
      !fields.last4 || fields.last4 !== card.fields.last4 ||
      fields.instrument !== card.fields.instrument) return result;
  return { ...result, fields: { ...fields, merchant: card.fields.merchant } };
}

function parseSmsAgainstPatterns(patterns, sms) {
  if (isSecurityOrOtpMessage(sms?.body)) {
    return { ok: false, reason: 'security_message' };
  }
  if (isInvestmentFolioAllotment(sms?.body)) {
    return parseInvestmentFolioAllotment(sms);
  }
  const payLaterDrawdown = parseBuiltInPayLaterDrawdown(sms);
  if (payLaterDrawdown.ok) return payLaterDrawdown;
  if (isNonTransactionNoise(sms?.sender, sms?.body)) {
    return { ok: false, reason: 'non_transaction_message' };
  }
  // Run before the generic "credited" rejection: a positive card-payment
  // receipt is intentionally retained as a non-spend transfer.
  const billPayment = parseBuiltInCardBillPayment(sms);
  if (billPayment.ok) return billPayment;
  const investmentMovement = parseBuiltInInvestmentMovement(sms);
  if (investmentMovement.ok) return investmentMovement;
  const nonSpendDebit = parseBuiltInNonSpendDebit(sms);
  if (nonSpendDebit.ok) return nonSpendDebit;
  const cardCredit = parseBuiltInCardCredit(sms);
  if (cardCredit.ok) return cardCredit;
  const accountCredit = parseBuiltInAccountCredit(sms);
  if (accountCredit.ok) return accountCredit;
  const walletSpend = parseBuiltInWalletSpend(sms);
  if (walletSpend.ok) return walletSpend;
  if (isRejectedTransaction(sms?.body)) {
    return { ok: false, reason: 'not_a_successful_spend' };
  }
  if (isCardBillNotice(sms?.body)) {
    return { ok: false, reason: 'card_bill_notice' };
  }
  if (isNonTransactionAlert(sms?.body)) {
    return { ok: false, reason: 'not_a_transaction_alert' };
  }
  const accountTransfer = parseBuiltInAccountTransfer(sms);
  if (accountTransfer.ok) return accountTransfer;
  const beneficiaryDebit = parseBuiltInBeneficiaryDebit(sms);
  if (beneficiaryDebit.ok) return beneficiaryDebit;
  const accountDebit = parseBuiltInAccountDebit(sms);
  if (accountDebit.ok) return accountDebit;
  if (isAmbiguousAccountDebit(sms?.body)) {
    return { ok: false, reason: 'ambiguous_account_debit' };
  }
  const configuredPatterns = Array.isArray(patterns) ? patterns : [];
  let lastReason = configuredPatterns.length > 0 ? 'no_regex_match' : 'no_transaction_match';
  const matches = [];
  for (const pattern of configuredPatterns) {
    const result = parseSms(pattern, sms);
    if (result.ok) {
      matches.push({
        ...result,
        patternId: pattern.id,
        parserKind: 'configured_pattern',
        priority: patternPriority(pattern, result),
      });
      continue;
    }
    lastReason = result.reason;
  }
  if (matches.length > 0) {
    matches.sort((left, right) => right.priority - left.priority);
    const { priority: _, ...best } = matches[0];
    return enrichMissingCardMerchant(best, sms);
  }

  const builtin = parseBuiltInUpiDebit(sms);
  if (builtin.ok) return builtin;
  const fallback = parseConservativeBankSpend(sms);
  if (fallback.ok) return enrichMissingCardMerchant({ ...fallback, patternId: null }, sms);

  // Keep the issuer-independent card parser as a final fallback for card
  // alerts whose wording is outside the conservative generic grammar.
  const cardBuiltin = parseBuiltInCardSpend(sms);
  if (cardBuiltin.ok) return cardBuiltin;
  return { ok: false, reason: lastReason };
}

/**
 * Build the `parser_failures.redacted_shape` value from a raw SMS body:
 * digits -> '#', then collapse letters run of length>=2 to 'X' to avoid
 * leaking merchant/name text, per the table's
 * `redacted_shape_has_no_digits` CHECK and its "no raw content" intent.
 */
function redactSmsShape(body) {
  return String(body || '')
    .replace(/\d/g, '#')
    .replace(/[A-Za-z]{2,}/g, 'X');
}

const MONTHS = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
  jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
};

/**
 * Turns the raw date string a pattern captured into a real Date.
 *
 * `parseSms` deliberately leaves `fields.date` as the bank's own text —
 * there is no single format across Indian issuers, and the parser's job is
 * extraction, not interpretation. This is the interpretation half, kept
 * separate so it stays unit-testable against real strings.
 *
 * DAY-FIRST throughout. Every pattern this feeds is an Indian bank message,
 * where 03/04/26 is 3 April, never 4 March. Guessing month-first would put
 * spend in the wrong month for two-thirds of the year while looking
 * perfectly plausible.
 *
 * Returns null — never a fallback to "today" — on anything it cannot read
 * with confidence, including impossible dates (31 February) and dates in
 * the future, which are always a misparse rather than a real transaction.
 * A wrong date is worse than no date: it files spend in the wrong week and
 * month, and it moves the transaction outside the ±1-day window that
 * cross-channel duplicate detection relies on, so the same swipe gets
 * counted twice.
 *
 * [reference] is the message's own timestamp, used only to resolve a
 * two-digit year and to reject the future. Defaults to now.
 */
function parseTransactionDate(raw, reference = new Date()) {
  if (!raw || typeof raw !== 'string') return null;
  const text = raw.trim();
  if (!text) return null;

  let year = null;
  let month = null;
  let day = null;

  // ISO first: 2026-04-03. Unambiguous, so it never reaches the day-first
  // branches below.
  let m = text.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/);
  if (m) {
    [year, month, day] = [Number(m[1]), Number(m[2]), Number(m[3])];
  }

  // 03-04-26, 3/4/2026, 03.04.26
  if (year === null) {
    m = text.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2}|\d{4})$/);
    if (m) {
      day = Number(m[1]);
      month = Number(m[2]);
      year = Number(m[3]);
    }
  }

  // 03-Apr-26, 3 Apr 2026, 03Apr26
  if (year === null) {
    m = text.match(/^(\d{1,2})[-\s]?([A-Za-z]{3,})[-\s]?(\d{2}|\d{4})$/);
    if (m) {
      day = Number(m[1]);
      month = MONTHS[m[2].slice(0, 3).toLowerCase()] ?? null;
      year = Number(m[3]);
    }
  }

  // Apr 03, 2026 / Apr 3 2026
  if (year === null) {
    m = text.match(/^([A-Za-z]{3,})[-\s]+(\d{1,2}),?[-\s]+(\d{2}|\d{4})$/);
    if (m) {
      month = MONTHS[m[1].slice(0, 3).toLowerCase()] ?? null;
      day = Number(m[2]);
      year = Number(m[3]);
    }
  }

  if (year === null || month === null || day === null) return null;
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) return null;

  // A two-digit year is this century. Banks do not text about 1926.
  if (year < 100) year += 2000;

  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  const parsed = new Date(year, month - 1, day);
  // Round-trip check: JS rolls 31 February forward into March rather than
  // rejecting it, so an impossible date would otherwise parse "successfully"
  // into the wrong day.
  if (
    parsed.getFullYear() !== year ||
    parsed.getMonth() !== month - 1 ||
    parsed.getDate() !== day
  ) {
    return null;
  }

  // A future date is a misparse, not a transaction. One day of slack covers
  // timezone skew between the device, the bank and this server.
  const limit = new Date(reference.getTime() + 24 * 60 * 60 * 1000);
  if (parsed > limit) return null;

  return parsed;
}

// Some card alerts print the actual swipe time immediately after the bank's
// transaction date. Use it only when the timezone is explicit; otherwise a
// guessed timezone could move a purchase into the wrong day or month.
function parseSmsTransactionTimestamp(rawDate, body, reference = new Date()) {
  const explicit = String(body || '').match(/\b(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s+IST\b/i);
  const date = parseTransactionDate(rawDate || explicit?.[1], reference);
  if (!date || !explicit) return { date, precise: false };
  const printedDate = parseTransactionDate(explicit[1], reference);
  if (!printedDate || printedDate.getFullYear() !== date.getFullYear()
      || printedDate.getMonth() !== date.getMonth()
      || printedDate.getDate() !== date.getDate()) return { date, precise: false };
  const hour = Number(explicit[2]);
  const minute = Number(explicit[3]);
  const second = Number(explicit[4] || 0);
  if (hour > 23 || minute > 59 || second > 59) return { date, precise: false };
  const timestamp = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate(), hour, minute, second)
    - 330 * 60 * 1000);
  return timestamp <= new Date(reference.getTime() + 24 * 60 * 60 * 1000)
    ? { date: timestamp, precise: true }
    : { date, precise: false };
}

module.exports = {
  parseSms,
  parseSmsAgainstPatterns,
  parseConservativeBankSpend,
  parseBuiltInCardBillPayment,
  parseBuiltInAccountTransfer,
  parseBuiltInAccountCredit,
  parseBuiltInWalletSpend,
  isInvestmentFolioAllotment,
  parseBuiltInPayLaterDrawdown,
  parseInvestmentFolioAllotment,
  senderMatches,
  redactSmsShape,
  parseTransactionDate,
  parseSmsTransactionTimestamp,
  isAmbiguousAccountDebit,
  isExplicitOwnAccountTransfer,
  KNOWN_FIELDS,
  isSecurityOrOtpMessage,
  isNonTransactionNoise,
  extractAvailableBalance,
  isCardBillNotice,
  isBankAccountMessage,
};
