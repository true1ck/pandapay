/// SMS pipeline v2 contracts: fact, instrument, event and ledger types, the
/// rule-bundle format, validators and the interfaces later packages implement.
///
/// Source of truth: `contracts/sms/v2` (JSON Schemas and fixtures). The server
/// validates with Ajv against the same files; see `api/src/sms_v2/contracts.js`.
library;

export 'src/sms_v2/contract/enums.dart';
export 'src/sms_v2/contract/errors.dart';
export 'src/sms_v2/contract/event.dart';
export 'src/sms_v2/contract/fact.dart';
export 'src/sms_v2/contract/instrument.dart';
export 'src/sms_v2/contract/interfaces.dart';
export 'src/sms_v2/contract/json_util.dart'
    show Json, JsonValue, canonicalJson, jsonDeepEquals;
export 'src/sms_v2/contract/ledger_entry.dart';
export 'src/sms_v2/contract/rule_bundle.dart';
export 'src/sms_v2/contract/schema_data.g.dart' show smsV2SchemaSources;
export 'src/sms_v2/contract/types.dart';
export 'src/sms_v2/contract/validate.dart';
