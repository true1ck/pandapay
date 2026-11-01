import AppIntents
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}
func fixturePerson(_ handle: IntentPerson.Handle?,
                   name: IntentPerson.Name = .displayName("Synthetic contact"),
                   aliases: [IntentPerson.Handle] = []) -> IntentPerson {
  IntentPerson(identifier: .unknown, name: name, handle: handle, aliases: aliases)
}
func roundTrip(_ person: IntentPerson) throws -> ProbeSenderValue {
  ProbeSenderValue.decode(try ProbeSenderValue.encode(person: person))
}

let cases: [(IntentPerson.Handle, String, String)] = [
  (.init(applicationDefined: "TESTBANK-S"), "TESTBANK-S", "application_defined"),
  (.init(phoneNumber: "+919000000000"), "+919000000000", "phone_number"),
  (.init(emailAddress: "sender@example.test"), "sender@example.test", "email_address"),
  (.init(applicationDefined: "TEST-देवनागरी-🧾"), "TEST-देवनागरी-🧾", "application_defined"),
]
for (handle, expected, type) in cases {
  let converted = try roundTrip(fixturePerson(handle))
  require(converted.sender == expected, "preserve exact primary sender handle")
  require(converted.evidence == "handle", "primary handle evidence")
  require(converted.conversion == "intent_person_resolver_v1", "explicit resolver provenance")
  require(converted.parameterState == "person_handle", "typed handle parameter state")
  let diagnostics = converted.diagnostics(action: "synthetic", parameter: "sender")
  let raw = diagnostics["person"] as! [String: Any]
  require(raw["handle"] as? String == expected && raw["handle_type"] as? String == type,
          "raw typed evidence accompanies resolved address")
  require(diagnostics["text"] is NSNull, "typed conversion is not falsely labelled direct text")
}

for (raw, state) in [("TESTBANK-S", "supplied_text"), ("", "empty"), (" \n", "whitespace"),
                     ("SYNTHETIC-🧾", "supplied_text")] {
  let input = ProbeSenderValue.decode(raw)
  require(input.sender == raw, "legacy String is byte-for-byte unchanged")
  require(input.parameterState == state && input.conversion == "already_text", "legacy state preserved")
  require(input.evidence == (raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "missing_text" : "text"),
          "legacy text evidence reflects presence")
  require(input.diagnostics(action: "original", parameter: "senderPerson")["text"] as? String == raw,
          "direct raw String remains inspectable")
}
let omitted = ProbeSenderValue.decode(nil)
require(omitted.sender.isEmpty && omitted.parameterState == "omitted", "nil differs from empty")
require(omitted.conversion == "none" && omitted.evidence == "missing_text", "omission is not a conversion result")
require(omitted.diagnostics(action: "original", parameter: "senderPerson")["text"] is NSNull,
        "nil stays null in diagnostic input")

let aliases: [IntentPerson.Handle] = [.init(applicationDefined: "ALIASBANK-S"), .init(phoneNumber: "+919000000001")]
for person in [fixturePerson(nil),
               fixturePerson(nil, name: .displayName("TESTBANK-S")),
               fixturePerson(nil, name: .unknown, aliases: aliases),
               fixturePerson(.init(applicationDefined: " \n"), aliases: aliases)] {
  let converted = try roundTrip(person)
  require(converted.sender.isEmpty && converted.evidence == "missing_person", "no primary handle stays missing")
  require(converted.parameterState == "person_without_handle", "typed input is distinct from absent input")
}
let aliasEnvelope = try ProbeSenderValue.encode(person: fixturePerson(nil, aliases: aliases))
require(!aliasEnvelope.contains("ALIASBANK-S") && !aliasEnvelope.contains("+919000000001"),
        "unrelated contact aliases are not serialized or selected")
let aliasSnapshot = try roundTrip(fixturePerson(nil, aliases: aliases)).diagnostics(action: "synthetic", parameter: "sender")
require((aliasSnapshot["person"] as! [String: Any])["alias_count"] as? Int == 2, "alias count remains diagnostic")
var components = PersonNameComponents()
components.givenName = "Synthetic"; components.familyName = "Contact"
let named = try roundTrip(fixturePerson(nil, name: .components(components)))
require(named.sender.isEmpty, "a formatted contact name cannot become the SMS address")
require((named.diagnostics(action: "synthetic", parameter: "sender")["person"] as! [String: Any])["name_type"] as? String == "components",
        "name provenance survives separately")

let invalidEnvelopes = [
  ProbeSenderValue.prefix + "not-json",
  ProbeSenderValue.prefix + "{}",
  ProbeSenderValue.prefix + #"{"version":2,"person":{"present":true}}"#,
  ProbeSenderValue.prefix + #"{"version":1,"person":{"present":false}}"#,
  ProbeSenderValue.prefix + String(repeating: "x", count: ProbeSenderValue.maxBytes),
]
for raw in invalidEnvelopes {
  let input = ProbeSenderValue.decode(raw)
  require(input.sender.isEmpty && input.parameterState == "invalid_envelope", "invalid envelope cannot become address")
  require(input.conversion == "invalid_sender_envelope", "invalid conversion is visible")
}
let unknownHandle = ProbeSenderValue.decode(ProbeSenderValue.prefix + #"{"version":1,"person":{"present":true,"handle":"NOT-AN-ADDRESS","handle_type":"unsupported"}}"#)
require(unknownHandle.sender.isEmpty, "unsupported handle type is not trusted")
do {
  _ = try ProbeSenderValue.encode(person: fixturePerson(.init(applicationDefined: String(repeating: "🧾", count: ProbeSenderValue.maxBytes))))
  fatalError("oversized typed payload was encoded")
} catch ProbeSenderValue.ConversionError.oversized {}

// Compile the actual public resolver builder on an optional String parameter.
// Assigning an already encoded result tests preservation; automatic iPhone
// dispatch of Person -> String remains a separate real-device qualification.
struct SyntheticResolverIntent: AppIntent {
  static let title: LocalizedStringResource = "Synthetic Probe Resolver"
  @Parameter(title: "Sender", inputConnectionBehavior: .never,
             resolvers: { ProbeSenderTextResolver() }) var sender: String?
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: ProbeSenderValue.decode(sender).sender)
  }
}
var intent = SyntheticResolverIntent()
require(intent.sender == nil, "optional published String stays optional")
let envelope = try ProbeSenderValue.encode(person: fixturePerson(.init(applicationDefined: "TESTBANK-S")))
intent.sender = envelope
let converted = ProbeSenderValue.decode(intent.sender)
require(converted.sender == "TESTBANK-S", "custom-resolver String output is preserved by property wrapper")

let date = HistoryRangeRequest.isoDate("2026-09-01T10:00:00.000Z")!
let request = "{\"version\":2,\"run_id\":\"\(UUID().uuidString)\",\"start_inclusive\":\"2026-09-01T00:00:00.000Z\",\"end_exclusive\":\"2026-09-02T00:00:00.000Z\"}"
let range = DeviceHistoryRangeInbox()
try range.register(request); _ = try range.boundary(request, end: false)
let diagnostics = converted.diagnostics(action: "synthetic", parameter: "sender")
require(try! range.capture(request, body: "Synthetic sender acquisition fixture", sender: converted.sender,
  date: date, evidence: converted.evidence, senderDiagnostics: diagnostics) == "accepted", "converted primary handle reaches range inbox")
let rangeRow = (range.snapshot()["records"] as! [[String: Any]]).single!
require(rangeRow["sender"] as? String == "TESTBANK-S" && rangeRow["senderEvidence"] as? String == "handle", "range preserves sender and evidence")
require((rangeRow["senderDiagnostics"] as? [String: Any])?["conversion"] as? String == "intent_person_resolver_v1", "range preserves conversion provenance")
let live = DeviceLiveMessageInbox()
require(live.capture(body: "Synthetic sender acquisition fixture", sender: converted.sender, receivedAt: date,
  evidence: converted.evidence, handler: "synthetic", allowedBundle: true, senderDiagnostics: diagnostics) == "pending", "converted primary handle reaches live inbox")
let liveRow = (live.snapshot()["records"] as! [[String: Any]]).single!
require(liveRow["sender"] as? String == "TESTBANK-S" && liveRow["senderEvidence"] as? String == "handle", "live preserves sender and evidence")
require((liveRow["senderDiagnostics"] as? [String: Any])?["conversion"] as? String == "intent_person_resolver_v1", "live preserves conversion provenance")
require(try! range.finish(request, found: 1)["status"] as? String == "completed", "converted input participates in range completion")
print("PASS: public resolver declaration; typed primary handles; legacy/nil/blank compatibility; name/alias exclusion; Unicode; envelope guards; native live/range provenance")

// The MessageEntity Sender is an outer MessagePerson entity. Its public Person
// property must arrive as IntentPerson, not be rendered into a String first.
// This declaration deliberately has no emailOrPhone mode and no custom resolver.
struct SyntheticDirectMessagePersonIntent: AppIntent {
  static let title: LocalizedStringResource = "Synthetic Direct Message Person"
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  @Parameter(title: "Message body", inputConnectionBehavior: .never) var body: String?
  @Parameter(title: "Sender Person", inputConnectionBehavior: .never) var sender: IntentPerson?
  @Parameter(title: "Original Message Date", inputConnectionBehavior: .never) var receivedAt: Date?

  func senderValue() throws -> ProbeSenderValue {
    // This adapter receives the typed Person directly. The earlier String
    // custom-resolver experiment has distinct provenance and is not invoked.
    try ProbeSenderValue.direct(person: sender)
  }
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: try senderValue().sender)
  }
}
var typed = SyntheticDirectMessagePersonIntent()
require(typed.sender == nil && typed.body == nil && typed.receivedAt == nil, "direct typed optional inputs remain omitted")
let missingTyped = try typed.senderValue()
require(missingTyped.sender.isEmpty && missingTyped.parameterState == "omitted_person", "missing typed Person stays missing with typed omission state")
require(missingTyped.evidence == "missing_person" && missingTyped.conversion == "direct_intent_person_v1", "typed omission is not mislabelled as a String resolver")
let omittedPersonSnapshot = missingTyped.diagnostics(action: "direct_message_person", parameter: "sender")["person"] as! [String: Any]
require(omittedPersonSnapshot["present"] as? Bool == false && omittedPersonSnapshot["input_available"] as? Bool == true, "omitted typed value is distinct from a receiver without a Person field")
typed.request = request
typed.body = "Synthetic direct Person acquisition fixture"
typed.receivedAt = date
typed.sender = fixturePerson(.init(applicationDefined: "DIRECTBANK-S"))
let direct = try typed.senderValue()
require(direct.sender == "DIRECTBANK-S" && direct.evidence == "handle", "direct typed application-defined sender survives property binding")
require(direct.conversion == "direct_intent_person_v1" && direct.parameterState == "person_handle", "direct Person path is not mislabelled as the custom String resolver")
let directDiagnostics = direct.diagnostics(action: "direct_message_person", parameter: "sender")
require(((directDiagnostics["person"] as? [String: Any])?["handle_type"] as? String) == "application_defined", "direct raw typed handle kind survives")
require(((directDiagnostics["person"] as? [String: Any])?["handle"] as? String) == "DIRECTBANK-S", "direct raw primary address survives")
let typedRange = DeviceHistoryRangeInbox()
try typedRange.register(typed.request); _ = try typedRange.boundary(typed.request, end: false)
require(try! typedRange.capture(typed.request, body: typed.body ?? "", sender: direct.sender,
  date: typed.receivedAt, evidence: direct.evidence, senderDiagnostics: directDiagnostics) == "accepted", "typed Person bypasses String conversion into range inbox")
let typedRangeRow = (typedRange.snapshot()["records"] as! [[String: Any]]).single!
require(typedRangeRow["sender"] as? String == "DIRECTBANK-S", "range keeps actual directly supplied handle")
require((typedRangeRow["senderDiagnostics"] as? [String: Any])?["conversion"] as? String == "direct_intent_person_v1", "range preserves direct Person provenance")
require(HistoryRangeRequest.isoDate(typedRangeRow["receivedAt"] as! String) == date, "typed input keeps its associated original date")
let typedLive = DeviceLiveMessageInbox()
require(typedLive.capture(body: typed.body, sender: direct.sender, receivedAt: typed.receivedAt,
  evidence: direct.evidence, handler: "direct_message_person", allowedBundle: true,
  senderDiagnostics: directDiagnostics) == "pending", "typed Person bypasses String conversion into live inbox")
let typedLiveRow = (typedLive.snapshot()["records"] as! [[String: Any]]).single!
require(typedLiveRow["sender"] as? String == "DIRECTBANK-S", "live keeps directly supplied primary handle")
require((typedLiveRow["senderDiagnostics"] as? [String: Any])?["action"] as? String == "direct_message_person", "direct typed source is distinguishable from resolver experiments")
require((typedLiveRow["senderDiagnostics"] as? [String: Any])?["conversion"] as? String == "direct_intent_person_v1", "live preserves direct Person provenance")
typed.sender = fixturePerson(nil, name: .displayName("DIRECTBANK-S"), aliases: aliases)
let typedNameOnly = try typed.senderValue()
require(typedNameOnly.sender.isEmpty && typedNameOnly.evidence == "missing_person" && typedNameOnly.parameterState == "person_without_handle", "direct Person names and aliases never replace the original primary address")
require(typedNameOnly.conversion == "direct_intent_person_v1", "typed no-handle evidence keeps direct provenance")
typed.sender = nil
let clearedTyped = try typed.senderValue()
require(clearedTyped.sender.isEmpty && clearedTyped.parameterState == "omitted_person", "clearing typed optional sender does not reuse previous handle")
print("PASS: optional direct IntentPerson parameter without email/phone mode or custom resolver; application-defined address and date retained in native inboxes; omitted sender stays missing")

extension Array {
  var single: Element? { count == 1 ? first : nil }
}
