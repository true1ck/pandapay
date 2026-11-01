# Historical Message sender wrapper — 1 November 2026

## Finding and evidence boundary

Apple's installed iOS **26.4 and 26.5 simulator runtime images** publish the same Messages entity schema: a historical Message's **Sender** property is a `MessagePerson` entity. That entity contains a separate **Person** property whose type is `IntentPerson`.

This establishes a real type distinction to address in the probe. It does **not** establish the runtime contents of either property on the user's iPhone, prove why the prior conversion returned empty text, or verify that the iPhone's variable picker exposes the nested property. The inspected runtime images are not a dump of the phone's Messages data.

Only first-party compiled App Intents metadata and public SDK declarations were inspected. No SMS database, customer message, private API invocation or device test was used for this finding. The metadata's location inside ChatKit is evidence for properties published to Shortcuts, not a proposal to link ChatKit or call its private implementation.

## Exact first-party metadata locations

**iOS 26.4:**

```text
/Library/Developer/CoreSimulator/Volumes/iOS_23E244/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/ChatKit.framework/Metadata.appintents/extract.actionsdata
```

**iOS 26.5:**

```text
/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/ChatKit.framework/Metadata.appintents/extract.actionsdata
```

The corresponding `Applications/MobileSMS.app/Extensions/MessagesActionExtension.appex/Metadata.appintents/extract.actionsdata` files expose the conversation focus-filter action. The Message and Conversation entities examined here are in the ChatKit metadata above.

## Published sender schema

| Entity | Property identifier | Published title | Type | Optional |
| --- | --- | --- | --- | --- |
| `MessageEntity` | `author` | Sender | Entity: `MessagePerson` | No |
| `MessagePerson` | `person` | Person | Intent value: `IntentPerson` | No |
| `MessageEntity` | `conversation` | Conversation | Entity: `ConversationEntity` | No |

Both `MessageEntity` and `MessagePerson` are discoverable in the inspected metadata. `MessagePerson` is transient and publishes exactly one property, `person`.

Relevant schema fragments, containing only names and types:

```json
{
  "entity": "MessageEntity",
  "property": "author",
  "valueType": {
    "entity": {"wrapper": {"typeName": "MessagePerson"}}
  }
}
```

```json
{
  "entity": "MessagePerson",
  "property": "person",
  "title": "Person",
  "valueType": {
    "intents": {"wrapper": {"typeIdentifier": 3}}
  }
}
```

`typeIdentifier: 3` in the intents value-type family corresponds to `IntentPerson` in the app's compiled typed Person parameter. It must not be confused with identifiers in the separate primitive value-type family.

`MessagePerson.transferableContentTypes` advertises this representation for both export and import:

```json
{
  "exportableTypes": [
    {"contentType": "com.apple.appintents.IntentPerson"}
  ],
  "importableTypes": [
    {"contentType": "com.apple.appintents.IntentPerson"}
  ]
}
```

It does **not advertise a String transfer representation**. This is narrower than claiming that every Shortcuts text rendering must fail: dynamic display representations and other system conversions are not fully described by this static metadata.

The public SDK's `IntentPerson` provides a primary `handle`, `name`, `identifier` and `aliases`. A handle can contain a phone number, email address or application-defined value. A name, contact identifier or secondary alias alone does not establish which address sent the message.

## Why the current routes may lose the value

The current direct String parameter expects String, while the new custom converter's input is `IntentPerson`. Neither input type is the outer `MessagePerson` entity returned by historical Message → Sender. Rendering that outer entity in a Text action also does not explicitly extract its nested `person` property.

This is a **supported inference from the published types**, not a verified runtime root cause. In particular:

- The empty String observed at the receiver does not reveal the original wrapper's internal contents.
- An implicit `MessagePerson` → `IntentPerson` transfer may be possible because that representation is advertised; whether it occurs in the user's current binding is unverified.
- The custom String converter compiles, but the current extracted action metadata still lists ordinary String resolution inputs and does not advertise a Person input for that field. Compiling the converter does not prove Shortcuts invokes it.
- Earlier nonempty text captures remain valid observations. They do not prove every acquisition context produces the same source type or conversion behavior.

## Proposed correction in the isolated probe

Use an explicit second property extraction and a **new typed Person receiver**, preserving the existing String actions for comparison. Do not change a published String parameter's type in place or modify main PandaPay during this probe work.

Proposed Shortcut sequence inside the existing message repeat:

1. Add **Set Variable**, setting a named variable such as `Sender entity` to **Repeat Item → Message → Sender**. This step should preserve the returned entity; do not insert Text to render it.
2. Use the saved entity variable's **Person** property as the new receiver's Person input. The intended path is **Sender entity → Message Person → Person**. A separate property-extraction action/output may be needed to make the second dereference available.
3. Keep the existing body, original receive date and range request variables connected to the same repeated message and original request. Leave the String control receiver available so one run can compare the acquisition routes.

The Build 11 experiment used the public `IntentPerson?` type without specifying a mode. This was later shown to default to `.contact` and failed on the phone; the declaration below records the failed candidate, not a recommendation:

```swift
@Parameter(title: "Sender Person", inputConnectionBehavior: .never)
var person: IntentPerson?
```

Omitting `mode` uses the framework's default contact picker presentation. The compiled type being `IntentPerson?` alone did not make the receiving action accept the Message sender wrapper.

The actual action name and user-facing picker steps must be checked against the compiled build and the user's iPhone UI before they are presented as verified instructions. If **Message Person → Person** is absent in that picker, do not tell the user to force its type to Text or Contact and report success. That would require another supported route to be established.

At handler entry, preserve the supplied typed evidence. Use the exact nonblank primary handle, including `.applicationDefined`, when available. Keep a supplied display name, identifier and alias count separate from the selected sender. A missing primary handle must remain explicit; do not substitute a body-inferred bank label or choose an arbitrary alias.

## Attributes and Conversation alternatives

| Exposed property | Actual type or content | Limitation |
| --- | --- | --- |
| Message → Attributes (`attributes`) | Array of `MessageAttribute`; inspected enum has only `pinned` | Not an author/address dictionary |
| Conversation → Participants (`recipients`) | Array of `MessagePerson` | Each item can expose nested Person, but participants are not automatically the author of a particular message |
| Conversation → Display Name (`displayName`) | String | A conversation/contact label is not necessarily an address |
| Conversation → Group Name (`conversationName`) | Optional String | A user-defined group name is not a sender |
| Conversation → Conversation GUID (`conversationGUID`) | Optional String | Opaque identifier; the schema does not document a transport/address encoding |
| Message → GUID (`GUID`) | Optional String | Source identifier, not a sender or transaction reference |
| Conversation → Attributes (`attributes`) | Array of `ConversationAttribute`; inspected enum has only `muted` | No author information |

Conversation → Participants → each Message Person → Person is an alternate structured source worth distinguishing if needed. It cannot silently replace Message → Sender → Person: groups, multiple participants and messages sent by the device owner make such substitution ambiguous. Likewise, an observed GUID must not be parsed using an assumed `service;...;address` format and promoted to a captured sender without a supported contract.

## Static verification without customer content

The following read-only check verifies the inspected first-party schema in both installed runtime images. It prints field names/types only and does not open a message store or run a Shortcut.

```python
import json
from pathlib import Path

volumes = Path('/Library/Developer/CoreSimulator/Volumes')
for build, version in [('iOS_23E244', 'iOS 26.4'),
                       ('iOS_23F77', 'iOS 26.5')]:
    runtime = (volumes / build /
        'Library/Developer/CoreSimulator/Profiles/Runtimes' /
        f'{version}.simruntime' / 'Contents/Resources/RuntimeRoot')
    metadata = runtime / (
        'System/Library/PrivateFrameworks/ChatKit.framework/'
        'Metadata.appintents/extract.actionsdata')
    data = json.loads(metadata.read_text())
    entities = data['entities']

    def prop(entity, identifier):
        return next(p for p in entities[entity]['properties']
                    if p['identifier'] == identifier)

    assert prop('MessageEntity', 'author')['valueType'] == {
        'entity': {'wrapper': {'typeName': 'MessagePerson'}}}
    assert prop('MessagePerson', 'person')['valueType'] == {
        'intents': {'wrapper': {'typeIdentifier': 3}}}
    assert len(entities['MessagePerson']['properties']) == 1
    transfer = entities['MessagePerson']['transferableContentTypes']
    for direction in ['exportableTypes', 'importableTypes']:
        assert transfer[direction] == [
            {'contentType': 'com.apple.appintents.IntentPerson'}]
    enums = {e['identifier']: e for e in data['enums']}
    assert [c['identifier'] for c in enums['MessageAttribute']['cases']] == ['pinned']
    assert [c['identifier'] for c in enums['ConversationAttribute']['cases']] == ['muted']
    print(version, 'author: MessagePerson; person: IntentPerson')
```

For any future probe build, inspect its compiled metadata and require local evidence that the incoming `MessagePerson` value can reach the chosen parameter without a Contact/phone/email coercion. Seeing an optional intents-family type-3 Person parameter is insufficient; the failed Build 11 had exactly that static type. The metadata check must be paired with a controlled user-run phone test before claiming success.

## Acceptance evidence still required

The user will run the phone test and export the result. Success requires the new typed receiver to be observed and a nonblank primary handle to be recorded with typed provenance. If a Person arrives without a handle, preserve that result rather than labelling the address recovered. The real message/date association, repeated-run behavior and existing security exclusions must also remain intact.

No runtime sender recovery, iPhone property-picker availability, new probe installation or production migration is claimed by this document. Main PandaPay and existing financial posting rules remain outside this change.

Public API references: [IntentPerson](https://developer.apple.com/documentation/appintents/intentperson), [Person parameter modes](https://developer.apple.com/documentation/appintents/intentperson/parametermode), [Resolvers](https://developer.apple.com/documentation/appintents/resolvers), and [adjust variables in Shortcuts](https://support.apple.com/guide/shortcuts/adjust-variables-apda36b9018b/ios). These describe the public mechanisms, not a guarantee of historical sender recovery.

## Correction after Probe 11 conversion failure

The phone's Probe 11 run rejected **Probe Message Sender Person** before its handler ran with `Person` → `Contact` conversion. Omitting an explicit `mode` did not create an unrestricted parameter: the public SDK's convenience initializers default `IntentPerson.ParameterMode` to `.contact`. Its only modes are `.contact`, `.email`, `.phone`, and `.emailOrPhone`; there is no unrestricted mode. The prior statement that this declaration had no contact/phone/email narrowing was wrong.

Changing the mode is not yet a demonstrated fix. A prior range action already declared `.emailOrPhone` and still failed when given the Message sender value, and that mode also does not promise to accept an application-defined handle such as an alphanumeric carrier sender. Do not ship another direct-Person parameter just by changing the mode.

A local iOS SDK compile experiment tried a custom `AppEntity` whose `defaultResolverSpecification` and parameter resolver accepted `IntentPerson`. Swift type-checking and app compilation succeeded, but the generated action metadata listed no `resolvableInputTypes` for that parameter. This does not prove the conversion path is discoverable to Shortcuts, so this approach is not a valid candidate for a phone build without stronger evidence.

The remaining evidenced route is a text parameter, because real probe events have arrived with sender strings such as `SBICRD-S` and `PHONPE-S`. However, the history loop's Text sender handoff has produced empty values, and the custom String resolver did not run in the user's exported history test. Thus, sender acquisition for historical Messages is still unresolved. Probe 11 is a failed diagnostic action, not a fix. Keep the main PandaPay app untouched until a public, locally verifiable conversion path accepts the actual historical `MessagePerson` wrapper and preserves application-defined handles.
