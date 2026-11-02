/// Word lists used by `redactSms`. Everything here is lower case.
///
/// The vocabulary is the safety net: a capitalised word that is neither in
/// [smsTemplateVocabulary] nor in the merchant catalogue is treated as a name
/// and replaced. A word missing from the list is therefore redacted (safe),
/// never leaked.
library;

/// Words that appear in the fixed text of Indian bank, card, wallet and
/// investment SMS. Contains no personal-name-like words on purpose.
final Set<String> smsTemplateVocabulary = _words('''
a an the and or of to in on at by for from with via per as is are was were be been being has have had will shall can may
not no nor your you yours our we us it its this that these those there here if when then than so also any all each other
such only both few more most some own same too very just do does did done get got given set let new old one two three
first last next previous prior after before during within without against between into onto upon over under above below up
down out off again further once now today tomorrow yesterday soon later earlier already still yet ever never always
rs inr usd rupees rupee paise amount amt balance bal avl avail available ledger limit limits lmt credit credited credits
debit debited debits card cards bank banks account accounts acct acc ac c savings current salary payment payments paid
pay pays payable bill bills billpay bbps due total minimum min max maximum outstanding statement estatement transaction
transactions txn txns trxn transfer transferred transfers trf sent send sending received receive receiving recd refund
refunded refunds reversal reversed reverse cashback reward rewards point points earned earn redeemed redemption redeem
withdrawn withdrawal withdrawals atm cash cheque check chq clearing cleared deposit deposited deposits dr cr ref
reference refno utr umrn rrn id no number num ending xx x xxx xxxx upi imps neft rtgs nach ach ecs emi loan loans
interest charges charge fee fees gst tax taxes insurance premium policy mandate mandates autopay auto registered
register successfully successful success failed fail failure declined decline unsuccessful pending processed
processing initiated initiate scheduled schedule cancelled canceled revoked paused resumed expired expires expiry valid
validity effective enhanced enhancement increase increased decrease decreased eligible eligibility offer offers offered
apply click link visit call sms block blocked unblock unblocked release released hold held lien asba ipo allotment
allotted allot application applied issue shares share units unit folio nav sip mutual fund funds demat trading broker
order orders delivery delivered dispatched shipped customer customers user users cardmember member holder dear sir madam
valued thank thanks thankyou welcome congratulations alert alerts update updated note notice notification information
info otp password pin cvv code verify verification secure security safe fraud dispute report contact support helpline
care service services app online net banking netbanking mobile wallet wallets prepaid recharge plan pack data merchant
merchants store shop purchase purchases spent spend spending used use using usage date time dated month months year
years day days hour hours minute minutes mins till until immediately ensure sufficient insufficient maintain
t&c tnc terms conditions regards team ltd pvt limited private public co inc llp
jan feb mar apr jun jul aug sep sept oct nov dec january february march april june july august september october
november december mon tue wed thu fri sat sun monday tuesday wednesday thursday friday saturday sunday am pm ist
hdfc icici sbi axis kotak amex american express citi citibank hsbc idfc yes indusind pnb canara bob baroda union idbi rbl
federal bandhan au standard chartered sc hdfcbk icicit sbicrd sbibnk axisbk kotakb
visa mastercard rupay diners
self joint primary secondary add money addmoney topup load loaded unload
vpa vpas payee payer beneficiary sender receiver remitter
confirm confirmed confirmation authorised authorized authorisation authorization preauth
generated generate avoid late fine penalty
worth equivalent value values
spends shopping offline international domestic contactless tap
dividend dividends maturity matured fd rd
please kindly ignore disregard reach
reply stop unsubscribe optout
p2p p2m p2a
accept acceptance cust si details more know login log activate activated enable disable approved approval
instant quick easy lakh lakhs crore upto free get claim reach t&c cheq bill billpay
q1 q2 q3 q4
''');

/// Words that end a name phrase after a trigger word ("to", "from", ...).
/// A subset of the vocabulary: function words and banking structure words.
final Set<String> smsStructuralWords = _words('''
a an the and or of to in on at by for from with via per as is are was were be been your you our
ac acct acc c account accounts card cards bank banks upi vpa imps neft rtgs nach ach rs inr
customer customers user users cardmember member holder valued sir madam
credit debit savings current wallet loan
hdfc icici sbi axis kotak amex american express citi hsbc idfc yes indusind pnb canara bob baroda union idbi rbl
federal bandhan au standard chartered
self joint
''');

/// Words that introduce a person, party or merchant.
final Set<String> smsNameTriggers = _words('''
to from by at for towards via dear hi hello hey mr mrs ms miss shri smt dr sri
beneficiary payee payer sender favouring favour merchant name info
''');

/// Honorifics swallowed together with the name that follows them.
final Set<String> smsTitles = _words('mr mrs ms miss shri smt dr sri');

/// Merchant and brand names that may survive redaction (lower case, one entry
/// per phrase). A name outside this list is replaced with `<PARTY>`.
final Set<String> smsMerchantCatalogue = {
  'swiggy', 'zomato', 'instamart', 'blinkit', 'zepto', 'bigbasket', 'dunzo',
  'amazon', 'flipkart', 'myntra', 'ajio', 'nykaa', 'meesho', 'netflix',
  'spotify', 'hotstar', 'disney', 'prime', 'youtube', 'google', 'apple',
  'microsoft', 'uber', 'ola', 'rapido', 'irctc', 'makemytrip', 'goibibo',
  'cleartrip', 'redbus', 'bookmyshow', 'paytm', 'phonepe', 'gpay', 'cred',
  'groww', 'zerodha', 'upstox', 'jio', 'airtel', 'vodafone', 'bsnl', 'tata',
  'bses', 'tneb', 'dmart', 'reliance', 'jiomart', 'croma', 'decathlon', 'ikea',
  'lenskart', 'pharmeasy', 'apollo', 'practo', 'starbucks', 'mcdonalds',
  'dominos', 'kfc', 'haldiram', 'ccd', 'lifestyle', 'westside', 'pantaloons',
  'zara', 'adidas', 'nike', 'puma', 'pluxee', 'sodexo', 'mobikwik',
  'freecharge', 'bharatpe', 'razorpay', 'juspay', 'payu', 'billdesk',
  'cashfree',
  'amazon pay', 'chai point', 'zomato money', 'swiggy instamart',
  'cafe coffee day', 'pizza hut', 'burger king', 'shoppers stop', 'pine labs',
  'ola money', 'tata power', 'reliance retail', 'google pay', 'apple services',
  'google play', 'disney hotstar', 'prime video', 'jio fiber',
  'airtel payments', 'cred club', 'american express', 'amazon pay in',
};

Set<String> _words(String text) => {
  for (final w in text.split(RegExp(r'\s+')))
    if (w.isNotEmpty) w.toLowerCase(),
};
