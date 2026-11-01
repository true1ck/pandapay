import AppIntents
import Foundation

func require(_ value: Bool, _ label: String) {
  guard value else { fatalError(label) }
}

func person(_ handle: IntentPerson.Handle?) -> IntentPerson {
  IntentPerson(identifier: .unknown, name: .displayName("Synthetic contact"), handle: handle)
}

for handle in [IntentPerson.Handle(phoneNumber: "+919000000000"),
               IntentPerson.Handle(emailAddress: "sender@example.test"),
               IntentPerson.Handle(applicationDefined: "VM-TESTBK")] {
  let expected: String
  switch handle.value {
  case .phoneNumber(let text), .emailAddress(let text), .applicationDefined(let text): expected = text
  @unknown default: fatalError("unsupported fixture")
  }
  let input = SmsSenderInput.resolve(text: nil, person: person(handle))
  require(input.text == expected && input.source == .personHandle, "preserve original supplied handle and its evidence")
}
let empty = SmsSenderInput.resolve(text: nil, person: nil)
require(empty.text == nil && empty.source == .missing, "both omitted inputs remain missing")
let nameOnly = SmsSenderInput.resolve(text: nil, person: person(nil))
require(nameOnly.text == nil && nameOnly.source == .personWithoutHandle, "distinguish a person lacking an address from no person")
let blank = SmsSenderInput.resolve(text: " \n", person: person(.init(phoneNumber: " \n")))
require(blank.text == nil && blank.source == .personWithoutHandle, "blank addresses remain missing")
let aliases = IntentPerson(identifier: .unknown, name: .unknown, handle: nil,
                          aliases: [.init(phoneNumber: "+919000000000"), .init(phoneNumber: "+919000000001")])
require(SmsSenderInput.resolve(text: nil, person: aliases).text == nil, "do not guess which contact alias sent an SMS")
let bankNameOnly = IntentPerson(identifier: .unknown, name: .displayName("VM-TESTBK"), handle: nil)
require(SmsSenderInput.resolve(text: nil, person: bankNameOnly).text == nil, "a display name alone does not establish a sender address")
let legacy = SmsSenderInput.resolve(text: "VM-TESTBK", person: nil)
require(legacy.text == "VM-TESTBK" && legacy.source == .text, "existing text caller remains compatible")
let fallback = SmsSenderInput.resolve(text: "VM-TESTBK", person: person(nil))
require(fallback.text == "VM-TESTBK" && fallback.source == .text, "optional person does not break a supplied text sender")
let direct = SmsSenderInput.resolve(text: "Synthetic contact", person: person(.init(phoneNumber: "+919000000000")))
require(direct.text == "+919000000000" && direct.source == .personHandle, "prefer the explicit Message handle over legacy text")

// The old field stays String; the Person field is additive and optional.
struct SenderContractIntent: AppIntent {
  static let title: LocalizedStringResource = "Synthetic Sender Contract"
  @Parameter(title: "Sender (text)", inputConnectionBehavior: .never) var sender: String?
  @Parameter(title: "Sender from Message", mode: .emailOrPhone, inputConnectionBehavior: .never) var senderPerson: IntentPerson?
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: SmsSenderInput.resolve(text: sender, person: senderPerson).text ?? "")
  }
}
var intent = SenderContractIntent()
require(intent.sender == nil && intent.senderPerson == nil, "optional omission stays nil")
intent.sender = "VM-TESTBK"
require(intent.sender == "VM-TESTBK" && intent.senderPerson == nil, "saved text remains a text input")
intent.senderPerson = person(.init(applicationDefined: "VM-DIRECT"))
require(SmsSenderInput.resolve(text: intent.sender, person: intent.senderPerson).text == "VM-DIRECT", "direct typed input reaches extraction")
print("PASS: additive person sender, legacy text compatibility, explicit input evidence and no contact-name/alias inference")
