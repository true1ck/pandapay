/// Security veto shared by native-equivalent intake, triage and local parsing.
/// Only an established, terminal advisory on a financial alert is discounted
/// for classification. Original text is never changed for storage or parsing.
class SmsSecurityPolicy {
  static final _advisory = RegExp(
    r"\b(?:never\s*share|do\s*not\s*share|don't\s*share)\s*(?:your\s+)?otp\s*[/,]\s*pin\s*[/,]\s*cvv\b",
    caseSensitive: false,
  );
  static final _suffix = RegExp(
    r"^\s*[.!]?\s*(?:[-–—]\s*[A-Za-z][A-Za-z .&'\-]{0,79})?[.!]?\s*$",
  );
  static final _money = RegExp(
    r'(?:\b(?:inr|rs\.?)|₹)\s*[:.]?\s*[0-9]',
    caseSensitive: false,
  );
  static final _financial = RegExp(
    r'\b(?:credited|debited|spent|paid|charged|withdrawn|deposited|received|transferred|(?:available|current|closing)\s+(?:balance|limit)|avl\.?\s*bal(?:ance)?)\b',
    caseSensitive: false,
  );
  // Never discount the advisory on authentication/reset instructions, even
  // when they also mention a transaction and money.
  static final _authenticationContext = RegExp(
    r'\b(?:log[\s-]*in|sign[\s-]*in|authenticat\w*|authori[sz]\w*|reset\w*|regenerat\w*|(?:use|enter|confirm|validate)\s+(?:your\s+)?(?:code|credential|password))\b',
    caseSensitive: false,
  );
  static final _security = RegExp(
    r"\b(?:otp|pin|cvv|passcode|password|secret\s*code|one[-\s]*time\s*(?:password|code)|verification\s*(?:code|number)|security\s*code|access\s*code|login\s*code|authentication\s*code|auth\s*code|authori[sz]ation\s*code|reset\s*(?:code|link))(?![a-z])"
    r"|\b(?:do\s*not|don't|never)\s*share\b"
    r'|\b[0-9]{4,8}\b[\s\S]{0,40}\bvalid\s+(?:for|till|until)\s+[0-9]+\s*(?:minutes?|mins?|seconds?|secs?)\b'
    r'|\b(?:code|credential)\b[\s\S]{0,40}\b(?:expires?|expiry|expiration|valid|regenerat\w*)\b'
    r'|\b(?:regenerat\w*|generat\w*)\b[\s\S]{0,30}\b(?:code|credential)\b',
    caseSensitive: false,
  );

  static bool sensitive(String body) {
    var evidence = body;
    for (final match in _advisory.allMatches(body)) {
      final prefix = body.substring(0, match.start);
      final suffix = body.substring(match.end);
      if (_suffix.hasMatch(suffix) &&
          _money.hasMatch(prefix) &&
          _financial.hasMatch(prefix) &&
          !_authenticationContext.hasMatch(prefix)) {
        // Keep the signoff and all other content under the same security veto.
        // Digits/credential assignments after the advisory prevent exemption.
        evidence = '$prefix $suffix';
        break;
      }
    }
    return _security.hasMatch(evidence);
  }
}
