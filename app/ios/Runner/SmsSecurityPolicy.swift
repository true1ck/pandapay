import Foundation

/// Equivalent to Dart SmsSecurityPolicy, covered by a common synthetic corpus.
/// The exception discounts only the exact terminal advisory for classification;
/// original message text and receive timestamps are never rewritten.
enum SmsSecurityPolicy {
  private static let advisory = #"(?i)\b(?:never\s*share|do\s*not\s*share|don't\s*share)\s*(?:your\s+)?otp\s*[/,]\s*pin\s*[/,]\s*cvv\b"#
  private static let suffix = #"^\s*[.!]?\s*(?:[-–—]\s*[A-Za-z][A-Za-z .&'\-]{0,79})?[.!]?\s*$"#
  private static let money = #"(?i)(?:\b(?:inr|rs\.?)|₹)\s*[:.]?\s*[0-9]"#
  private static let financial = #"(?i)\b(?:credited|debited|spent|paid|charged|withdrawn|deposited|received|transferred|(?:available|current|closing)\s+(?:balance|limit)|avl\.?\s*bal(?:ance)?)\b"#
  private static let authenticationContext = #"(?i)\b(?:log[\s-]*in|sign[\s-]*in|authenticat\w*|authori[sz]\w*|reset\w*|regenerat\w*|(?:use|enter|confirm|validate)\s+(?:your\s+)?(?:code|credential|password))\b"#
  private static let nonCredentialStatementInstruction = #"(?i)\benter\s+your\s+pan\s+as\s+the\s+password[.!](?=\s|$)"#
  private static let security = #"(?i)\b(?:otp|pin|cvv|passcode|password|secret\s*code|one[-\s]*time\s*(?:password|code)|verification\s*(?:code|number)|security\s*code|access\s*code|login\s*code|authentication\s*code|auth\s*code|authori[sz]ation\s*code|reset\s*(?:code|link))(?![a-z])|\b(?:do\s*not|don't|never)\s*share\b|\b[0-9]{4,8}\b[\s\S]{0,40}\bvalid\s+(?:for|till|until)\s+[0-9]+\s*(?:minutes?|mins?|seconds?|secs?)\b|\b(?:code|credential)\b[\s\S]{0,40}\b(?:expires?|expiry|expiration|valid|regenerat\w*)\b|\b(?:regenerat\w*|generat\w*)\b[\s\S]{0,30}\b(?:code|credential)\b"#
  static func sensitive(_ body: String) -> Bool {
    var evidence = body
    let pattern = try! NSRegularExpression(pattern: advisory)
    for match in pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
      guard let range = Range(match.range, in: body) else { continue }
      let before = String(body[..<range.lowerBound])
      let after = String(body[range.upperBound...])
      if after.range(of: suffix, options: .regularExpression) != nil,
         before.range(of: money, options: .regularExpression) != nil,
         before.range(of: financial, options: .regularExpression) != nil,
         before.range(of: authenticationContext, options: .regularExpression) == nil {
        evidence = "\(before) \(after)"
        break
      }
    }
    let checked = evidence.replacingOccurrences(of: nonCredentialStatementInstruction, with: " ", options: .regularExpression)
    return checked.range(of: security, options: .regularExpression) != nil
  }
}
