/// Disposable simulator data. These are invented examples, not customer SMS.
/// Kept separate from the Apple Messages provider: this is a test source only.
List<Map<String, Object>> iosPrototypeHistoryFixtures() {
  const merchants = [
    'BUNDL TECHNOLOGIES',
    'AMAZON',
    'SWIGGY',
    'BIG BAZAAR',
    'DMART',
    'APOLLO PHARMACY',
    'UBER',
    'IRCTC',
    'NETFLIX',
    'TEST CAFE',
  ];
  return List.generate(100, (i) {
    final received = DateTime.utc(2026, 7, 18, 4).add(Duration(days: i));
    final kind = i % 20;
    final amount = 100 + i * 37;
    final date =
        '${received.day.toString().padLeft(2, '0')}-'
        '${received.month.toString().padLeft(2, '0')}-${received.year}';
    final due = received.add(const Duration(days: 10));
    final dueDate =
        '${due.day.toString().padLeft(2, '0')}/'
        '${due.month.toString().padLeft(2, '0')}/${due.year}';
    final String body;
    final String expected;
    if (kind < 8) {
      // Two genuinely distinct equal-text payments on different original dates.
      body = (i == 0 || i == 20)
          ? 'Rs 349.00 spent on HDFC Bank Card ending 1234 at BUNDL TECHNOLOGIES.'
          : 'Rs $amount.00 spent on HDFC Bank Card ending 1234 at ${merchants[i % merchants.length]}.';
      expected = 'transaction';
    } else if (kind < 12) {
      body =
          'Rs.${amount + 5000}.0 credited to your HDFC Bank A/C *9080 from SAMPLE PERSON on $date. Ref ${99000000 + i}.';
      expected = 'transaction';
    } else if (kind < 15) {
      body =
          'Your HDFC Bank MoneyBack+ Credit Card statement is ready. Total due Rs $amount. Payment due date of your card is $dueDate.';
      expected = 'bill';
    } else if (kind < 17) {
      body = 'OTP 000000 for Rs $amount purchase at TEST STORE. Do not share.';
      expected = 'sensitive';
    } else if (kind < 19) {
      body =
          'Enjoy an exclusive offer: get 10% off your next order at TEST STORE. Apply now!';
      expected = 'ignored';
    } else {
      body = 'Your test parcel ${i + 1} will arrive tomorrow.';
      expected = 'ignored';
    }
    return <String, Object>{
      'id': 'PPH-${(i + 1).toString().padLeft(3, '0')}',
      'sender': 'VM-HDFCBK',
      'body': '$body [PANDAPAY_TEST]',
      'receivedAt': received.toIso8601String(),
      'capturedAt': '2026-10-26T10:00:00Z',
      'expected': expected,
    };
  });
}
