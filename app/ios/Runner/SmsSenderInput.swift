import AppIntents
import Foundation

/// Keep the original String input compatible and accept the Message's Person
/// directly in a separate optional field. A text-token conversion can become
/// empty in Shortcuts before an app-side String resolver ever receives it.
@available(iOS 16.0, macOS 13.0, *)
struct SmsSenderInput {
  enum Source: String {
    case text, personHandle = "person_handle", personWithoutHandle = "person_without_handle", missing
  }
  let text: String?
  let source: Source

  static func resolve(text: String?, person: IntentPerson?) -> Self {
    if let person, let handle = senderText(from: person) {
      return Self(text: handle, source: .personHandle)
    }
    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return Self(text: text, source: .text)
    }
    return Self(text: nil, source: person == nil ? .missing : .personWithoutHandle)
  }

  private static func senderText(from person: IntentPerson) -> String? {
    guard let handle = person.handle else { return nil }
    let text: String
    switch handle.value {
    case .phoneNumber(let value), .emailAddress(let value), .applicationDefined(let value): text = value
    @unknown default: return nil
    }
    // A contact name or one of several aliases is not the original SMS
    // address. Do not guess, query Contacts, or infer a bank from the body.
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }
}
