// Isolated-probe acquisition adapter. The main app does not compile this file.
import AppIntents
import Foundation

/// A String parameter can receive a Person through this public conversion
/// hook, without asking Shortcuts to resolve a bank ID as a Contact/phone/email.
/// The envelope keeps conversion provenance alongside the original address.
@available(iOS 16.0, macOS 13.0, *)
struct ProbeSenderTextResolver: Resolver {
  typealias Input = IntentPerson
  typealias Output = String

  func resolve(from input: IntentPerson, context: IntentParameterContext<String>) async throws -> String? {
    try ProbeSenderValue.encode(person: input)
  }
}

@available(iOS 16.0, macOS 13.0, *)
struct ProbeSenderValue {
  static let prefix = "pandapay.sender.v1:"
  static let maxBytes = 16_384
  let sender: String
  let evidence: String
  let conversion: String
  let parameterState: String
  private let text: String?
  private let person: [String: Any]

  static func encode(person: IntentPerson) throws -> String {
    var snapshot: [String: Any] = [
      "present": true, "handle": NSNull(), "handle_type": NSNull(),
      "name": NSNull(), "name_type": "unknown", "alias_count": person.aliases.count,
    ]
    if let handle = person.handle {
      switch handle.value {
      case .phoneNumber(let value): snapshot["handle"] = value; snapshot["handle_type"] = "phone_number"
      case .emailAddress(let value): snapshot["handle"] = value; snapshot["handle_type"] = "email_address"
      case .applicationDefined(let value): snapshot["handle"] = value; snapshot["handle_type"] = "application_defined"
      @unknown default: snapshot["handle_type"] = "unsupported"
      }
    }
    switch person.name {
    case .displayName(let value): snapshot["name"] = value; snapshot["name_type"] = "display_name"
    case .components(let value):
      snapshot["name"] = PersonNameComponentsFormatter.localizedString(from: value, style: .default)
      snapshot["name_type"] = "components"
    case .unknown: break
    @unknown default: snapshot["name_type"] = "unsupported"
    }
    // Aliases are counts only: unrelated addresses in a Contact are not the
    // address which sent this SMS and must never be selected by this adapter.
    let data = try JSONSerialization.data(withJSONObject: ["version": 1, "person": snapshot], options: [.sortedKeys])
    guard data.count + prefix.utf8.count <= maxBytes else { throw ConversionError.oversized }
    return prefix + String(decoding: data, as: UTF8.self)
  }

  /// A separate, genuinely typed Person parameter. Reuse the bounded evidence
  /// projection internally, without relying on a Shortcuts String resolver.
  static func direct(person: IntentPerson?) throws -> Self {
    guard let person else {
      return Self(sender: "", evidence: "missing_person", conversion: "direct_intent_person_v1",
        parameterState: "omitted_person", text: nil,
        person: ["present": false, "input_available": true])
    }
    let projected = decode(try encode(person: person))
    return Self(sender: projected.sender, evidence: projected.evidence,
      conversion: "direct_intent_person_v1", parameterState: projected.parameterState,
      text: nil, person: projected.person)
  }

  static func decode(_ raw: String?) -> Self {
    let absent: [String: Any] = ["present": false, "input_available": false]
    guard let raw else {
      return Self(sender: "", evidence: "missing_text", conversion: "none", parameterState: "omitted", text: nil, person: absent)
    }
    guard raw.hasPrefix(prefix) else {
      let empty = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return Self(sender: raw, evidence: empty ? "missing_text" : "text", conversion: "already_text",
        parameterState: raw.isEmpty ? "empty" : empty ? "whitespace" : "supplied_text", text: raw, person: absent)
    }
    guard raw.utf8.count <= maxBytes,
          let data = String(raw.dropFirst(prefix.count)).data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          object["version"] as? Int == 1,
          let person = object["person"] as? [String: Any], person["present"] as? Bool == true else {
      return Self(sender: "", evidence: "missing_text", conversion: "invalid_sender_envelope",
        parameterState: "invalid_envelope", text: nil, person: absent)
    }
    let handleType = person["handle_type"] as? String ?? ""
    let handle = person["handle"] as? String ?? ""
    let usable = ["phone_number", "email_address", "application_defined"].contains(handleType)
      && !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return Self(sender: usable ? handle : "", evidence: usable ? "handle" : "missing_person",
      conversion: "intent_person_resolver_v1", parameterState: usable ? "person_handle" : "person_without_handle",
      text: nil, person: person)
  }

  func diagnostics(action: String, parameter: String) -> [String: Any] {
    ["action": action, "parameter_id": parameter, "text": text.map { $0 as Any } ?? NSNull(),
     "person": person, "conversion": conversion, "parameter_state": parameterState]
  }

  enum ConversionError: Error { case oversized }
}
