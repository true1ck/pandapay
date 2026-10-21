import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Typed source/fact contract, device mirror of api/src/sms_facts.js.
///
/// One financial message yields several typed facts with explicit amount and
/// date roles, so a bill total can never be booked as a purchase and a
/// mandate ceiling can never become a charge. Validation must abstain (needs
/// review) rather than post a half-trusted fact.
///
/// Keep field names identical to the server module: these payloads travel
/// as-is in uploads, and tests assert Dart/Node parity on the shared corpus.

const int smsFactContractVersion = 1;

const List<String> smsFactTypes = [
  'posted_movement',
  'pending_or_failed_attempt',
  'balance_snapshot',
  'bill_obligation',
  'bill_payment',
  'mandate_lifecycle',
  'card_identity_hint',
  'security_or_service_alert',
  'promotion',
];

const List<String> smsFactStatuses = [
  'active',
  'superseded',
  'discarded',
];

const List<String> smsEntryKinds = ['spend', 'income', 'transfer', 'investment'];

const List<String> smsInstruments = [
  'upi_bank',
  'credit_card',
  'debit_card',
  'cash',
  'wallet',
  'other',
];

const List<String> smsAmountRoles = [
  'posted',
  'due_total',
  'due_minimum',
  'outstanding',
  'ceiling',
  'proposed',
];

const Map<String, String> smsAmountFieldByRole = {
  'posted': 'amountInr',
  'due_total': 'amountDueInr',
  'due_minimum': 'minimumDueInr',
  'outstanding': 'outstandingInr',
  'ceiling': 'limitInr',
  'proposed': 'proposedAmountInr',
};

const Map<String, String> smsProvisionByRole = {
  'posted': 'occurredAt',
  'due_total': 'dueDate',
  'due_minimum': 'dueDate',
  'outstanding': 'asOfAt',
  'ceiling': 'asOfAt',
  'proposed': 'proposedAt',
};

const Map<String, List<String>> smsRequiredFieldsByType = {
  'posted_movement': ['amountRole', 'entryKind', 'occurredAt'],
  'pending_or_failed_attempt': ['attemptStatus', 'occurredAt'],
  'balance_snapshot': ['availableBalanceInr', 'asOfAt'],
  'bill_obligation': ['amountRole', 'dueDate'],
  'bill_payment': ['amountRole', 'occurredAt'],
  'mandate_lifecycle': ['mandateStatus', 'asOfAt'],
  'card_identity_hint': ['asOfAt'],
  'security_or_service_alert': ['alertKind', 'occurredAt'],
  'promotion': [],
};

/// Fact families that must never carry posted-money semantics.
const Set<String> smsNonPostedFactTypes = {
  'pending_or_failed_attempt',
  'bill_obligation',
  'mandate_lifecycle',
  'security_or_service_alert',
  'promotion',
  'card_identity_hint',
};

bool _dateOk(String? value) {
  if (value == null) return false;
  try {
    DateTime.parse(value);
    return true;
  } on FormatException {
    return false;
  }
}

bool _shortTextOk(String? value) =>
    value != null &&
    value.trim().isNotEmpty &&
    value.trim().length <= 120;

/// Fact payload shapes, mirroring the server PAYLOAD_FIELD_SHAPES table.
const Map<String, Map<String, Object>> smsPayloadFieldShapes = {
  'entryKind': {'in': smsEntryKinds},
  'transferKind': {'type': 'string'},
  'amountRole': {'in': smsAmountRoles},
  'amountInr': {'number': true, 'positive': true},
  'amountDueInr': {'number': true, 'positive': true},
  'minimumDueInr': {'number': true, 'positive': true},
  'outstandingInr': {'number': true, 'positive': true},
  'limitInr': {'number': true, 'positive': true},
  'proposedAmountInr': {'number': true, 'positive': true},
  'availableBalanceInr': {'number': true, 'nonnegative': true},
  'occurredAt': {'date': true},
  'dueDate': {'date': true},
  'statementDate': {'date': true},
  'proposedAt': {'date': true},
  'asOfAt': {'date': true},
  'mandateStatus': {
    'in': ['registered', 'scheduled', 'paused', 'cancelled', 'failed'],
  },
  'attemptStatus': {
    'in': ['attempted', 'scheduled', 'failed'],
  },
  'statementStatus': {
    'in': ['outstanding', 'settled'],
  },
  'alertKind': {
    'in': ['otp', 'verification', 'service'],
  },
  'last4': {'digits': 4},
  'accountLast4': {'digits': 4},
  'issuerName': {'shortText': true},
  'merchant': {'shortText': true},
  'transferParty': {'shortText': true},
  'billerName': {'shortText': true},
  'instrument': {'in': smsInstruments},
  'reference': {'shortText': true},
  'cardType': {
    'in': ['credit', 'debit'],
  },
  'cardName': {'shortText': true},
};

/// Numeric keep-lists mirrored from the server so the check matrix matches.
const List<String> smsPositiveAmountFields = [
  'amountInr',
  'amountDueInr',
  'minimumDueInr',
  'outstandingInr',
  'limitInr',
  'proposedAmountInr',
];
const List<String> smsNonNegativeAmountFields = ['availableBalanceInr'];
const List<String> smsDateFields = [
  'occurredAt',
  'dueDate',
  'statementDate',
  'proposedAt',
  'asOfAt',
];
const List<String> smsShortTextFields = [
  'issuerName',
  'merchant',
  'transferParty',
  'billerName',
  'reference',
  'cardName',
];
const List<String> smsFourDigitFields = ['last4', 'accountLast4'];
const List<String> smsEnumFields = ['amountRole', 'instrument'];
const List<String> smsPlainStringFields = ['transferKind'];

class SmsFactValidationResult {
  final bool valid;
  final List<String> errors;
  const SmsFactValidationResult(this.valid, this.errors);
}

SmsFactValidationResult validateSmsFactPayload(
  String factType,
  Map<String, Object?> payload,
) {
  final errors = <String>[];

  final amountRole = payload['amountRole'] as String?;
  for (final field in smsPayloadFieldShapes.keys) {
    final value = payload[field];
    if (value == null) continue;
    if (smsPlainStringFields.contains(field)) {
      if (value is! String) errors.add('$field must be a string');
      continue;
    }
    if (smsEnumFields.contains(field)) {
      final allowed = field == 'instrument' ? smsInstruments : smsAmountRoles;
      if (value is! String || !allowed.contains(value)) {
        errors.add('$field must be one of ${allowed.join(', ')}');
      }
      continue;
    }
    if (smsPositiveAmountFields.contains(field) ||
        smsNonNegativeAmountFields.contains(field)) {
      if (value is! num) {
        errors.add('$field must be a number');
        continue;
      }
      if (smsPositiveAmountFields.contains(field) && value <= 0) {
        errors.add('$field must be positive');
      }
      if (field == 'availableBalanceInr' && value < 0) {
        errors.add('$field must be non-negative');
      }
      continue;
    }
    if (smsDateFields.contains(field)) {
      if (value is! String || !_dateOk(value)) {
        errors.add('$field must be an ISO date-time');
      }
      continue;
    }
    if (smsFourDigitFields.contains(field)) {
      if (value is! String || !RegExp(r'^\d{4}$').hasMatch(value)) {
        errors.add('$field must be exactly 4 digits');
      }
      continue;
    }
    if (smsShortTextFields.contains(field)) {
      if (value is! String || !_shortTextOk(value)) {
        errors.add('$field must be a short non-empty string');
      }
      continue;
    }
    // Remaining enum-only shapes (mandateStatus, attemptStatus,
    // statementStatus, alertKind, cardType, entryKind).
    final shape = smsPayloadFieldShapes[field]!;
    if (shape.containsKey('in')) {
      final allowed = shape['in'] as List<String>;
      if (value is! String || !allowed.contains(value)) {
        errors.add('$field must be one of ${allowed.join(', ')}');
      }
      continue;
    }
    if (shape.containsKey('type')) {
      if (value is! String) errors.add('$field must be a string');
    }
  }

  for (final required in smsRequiredFieldsByType[factType] ?? const <String>[]) {
    if (payload[required] == null) {
      errors.add('$required is required for $factType');
    }
  }

  if (amountRole != null) {
    final amountField = smsAmountFieldByRole[amountRole];
    if (amountField != null) {
      final amount = payload[amountField];
      if (amount is! num || amount <= 0) {
        errors.add("amountRole '$amountRole' requires a positive $amountField");
      }
      final dateField = smsProvisionByRole[amountRole];
      if (dateField != null && payload[dateField] == null) {
        errors.add("amountRole '$amountRole' requires $dateField");
      }
    }
  }

  if (smsNonPostedFactTypes.contains(factType) &&
      amountRole != null &&
      amountRole != 'proposed') {
    if (factType == 'bill_obligation' || factType == 'bill_payment') {
      if (amountRole == 'posted') {
        errors.add("$factType must not use amountRole 'posted'");
      }
    } else {
      errors.add('$factType must not carry a due/posted amount role');
    }
  }

  final limitInr = payload['limitInr'];
  if (factType == 'mandate_lifecycle' &&
      limitInr != null &&
      payload['mandateStatus'] != 'registered') {
    errors.add('limitInr is only meaningful for a registered mandate');
  }
  // A registered mandate must carry its ceiling: without the limit the fact
  // says nothing a projection can safely use, so it must abstain instead.
  if (factType == 'mandate_lifecycle' &&
      payload['mandateStatus'] == 'registered' &&
      limitInr == null) {
    errors.add('a registered mandate requires limitInr');
  }

  if (factType == 'posted_movement') {
    if (payload['entryKind'] == 'spend' && payload['merchant'] == null) {
      errors.add('posted spend requires merchant');
    }
    final role = payload['amountRole'] as String?;
    if (payload['entryKind'] == 'transfer' &&
        role != null &&
        role != 'posted') {
      errors.add('posted transfer must use amountRole posted');
    }
  }

  if (factType == 'security_or_service_alert' &&
      payload['alertKind'] == 'otp' &&
      amountRole != null) {
    errors.add('an OTP alert never carries an amount');
  }

  return SmsFactValidationResult(errors.isEmpty, errors);
}

class SmsFactValidationEntry {
  final String factType;
  final Map<String, Object?> payload;
  final Map<String, Object?> provenance;
  final int? factIndex;
  const SmsFactValidationEntry({
    required this.factType,
    required this.payload,
    this.provenance = const {},
    this.factIndex,
  });
}

SmsFactValidationResult validateSmsFact(SmsFactValidationEntry fact) {
  final errors = <String>[];
  if (!smsFactTypes.contains(fact.factType)) {
    errors.add('factType must be one of ${smsFactTypes.join(', ')}');
    return SmsFactValidationResult(false, errors);
  }
  if (fact.factIndex != null && (fact.factIndex! < 0)) {
    errors.add('factIndex must be a non-negative integer');
  }
  final payloadCheck = validateSmsFactPayload(fact.factType, fact.payload);
  errors.addAll(payloadCheck.errors);
  return SmsFactValidationResult(errors.isEmpty, errors);
}

/// Canonical JSON sting used for deterministic fact ordering. Must match the
/// server exactly: JSON string of [factType, payload, provenance].
String canonicalSmsFactString(
  String factType,
  Map<String, Object?> payload,
  Map<String, Object?> provenance,
) {
  return jsonEncode([
    factType,
    payload,
    provenance,
  ]);
}

/// Assigns deterministic indices identical to the server's sort, so a device
/// replay and a server replay map the same fact to the same slot.
List<SmsFactValidationEntry> assignDeterministicSmsFactIndices(
  List<SmsFactValidationEntry> facts,
) {
  String canonical(int i) => canonicalSmsFactString(
        facts[i].factType,
        facts[i].payload,
        facts[i].provenance,
      );
  final order = List<int>.generate(facts.length, (i) => i);
  order.sort((a, b) {
    final byCanonical = canonical(a).compareTo(canonical(b));
    return byCanonical != 0 ? byCanonical : a.compareTo(b);
  });
  return [
    for (final (slot, index) in order.indexed)
      SmsFactValidationEntry(
        factType: facts[index].factType,
        payload: facts[index].payload,
        provenance: facts[index].provenance,
        factIndex: slot,
      ),
  ];
}

/// SHA-256 identity hash of the normalized message content — mirrors the
/// server's bodyHashOf. Raw text still never leaves the device except through
/// the legacy upload path, which keeps today's disclosure truthful.
String smsBodyHash(String sender, String body) {
  return sha256
      .convert(utf8.encode(jsonEncode([
        sender.toUpperCase(),
        body,
      ])))
      .toString();
}

/// Deep-merges a user correction over the parser payload; the user wins.
Map<String, Object?> applySmsFactOverride(
  Map<String, Object?> basePayload,
  Map<String, Object?> patch,
) {
  return {...basePayload, ...patch};
}
