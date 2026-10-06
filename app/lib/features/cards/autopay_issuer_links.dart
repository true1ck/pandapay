/// Official issuer destinations used for managing autopay.
///
/// PandaPay does not have an issuer mandate API, so these links are only
/// navigation helpers. They never change a card setting and never claim that
/// autopay is enabled. Unknown issuers intentionally return null rather than
/// sending a user to an unverified third-party page.
String? officialAutopayUrl({String? issuerName, required String cardName}) {
  final text = '${issuerName ?? ''} $cardName'.toLowerCase();
  if (text.contains('sbi') || text.contains('state bank')) {
    return 'https://www.sbicard.com/';
  }
  if (text.contains('hdfc')) return 'https://www.hdfcbank.com/';
  if (text.contains('icici')) return 'https://www.icicibank.com/';
  if (text.contains('axis')) return 'https://www.axisbank.com/';
  if (text.contains('kotak')) return 'https://www.kotak.com/';
  if (text.contains('pnb') || text.contains('punjab national')) {
    return 'https://www.pnbcard.in/';
  }
  if (text.contains('idfc')) return 'https://www.idfcfirstbank.com/';
  if (text.contains('rbl')) return 'https://www.rblbank.com/';
  if (text.contains('indusind')) return 'https://www.indusind.com/';
  if (text.contains('amex') || text.contains('american express')) {
    return 'https://www.americanexpress.com/in/';
  }
  if (text.contains('yes bank')) return 'https://www.yesbank.in/';
  return null;
}
