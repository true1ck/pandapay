import 'dart:convert';

import 'package:crypto/crypto.dart';

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
const sharedCommandKinds = {
  'context.create',
  'member.invite',
  'membership.respond',
  'expense.propose',
  'expense.respond',
  'settlement.report',
  'settlement.respond',
};
bool sharedUuid(Object? value) =>
    value is String && _uuid.firstMatch(value)?.group(0) == value;
void _validString(String value) {
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        throw const FormatException('Invalid JSON string');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('Invalid JSON string');
    }
  }
}

/// Restricted JSON stream shared with the server. Rejects malformed Unicode,
/// cycles, unsafe numeric scalars and work above the wire/depth/node limits.
String sharedCanonicalJson(Object? value, {int maxBytes = 65536}) {
  final output = StringBuffer(), ancestors = Set<Object>.identity();
  var nodes = 0, bytes = 0;
  void append(String text) {
    bytes += utf8.encode(text).length;
    if (bytes > maxBytes) {
      throw const FormatException('JSON byte limit exceeded');
    }
    output.write(text);
  }

  void visit(Object? input, int depth) {
    if (depth > 16 || ++nodes > 8192) {
      throw const FormatException('JSON structure limit exceeded');
    }
    if (input == null || input is bool) {
      append(jsonEncode(input));
      return;
    }
    if (input is int && input.abs() <= 9007199254740991) {
      append(input.toString());
      return;
    }
    if (input is String) {
      if (input.length > maxBytes) {
        throw const FormatException('JSON byte limit exceeded');
      }
      _validString(input);
      append(jsonEncode(input));
      return;
    }
    if (input is! Map && input is! List) {
      throw const FormatException('Unsupported JSON value');
    }
    if (!ancestors.add(input)) throw const FormatException('Cyclic JSON value');
    if (input is List) {
      if (input.length > 1000) {
        throw const FormatException('JSON array limit exceeded');
      }
      append('[');
      for (var i = 0; i < input.length; i++) {
        if (i > 0) append(',');
        visit(input[i], depth + 1);
      }
      append(']');
    } else if (input is Map) {
      if (input.length > 128) {
        throw const FormatException('JSON object limit exceeded');
      }
      final keys = <String>[];
      for (final key in input.keys) {
        if (key is! String ||
            key.length > 128 ||
            RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').firstMatch(key)?.group(0) !=
                key) {
          throw const FormatException('Invalid JSON key');
        }
        keys.add(key);
      }
      keys.sort();
      append('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) append(',');
        append(jsonEncode(keys[i]));
        append(':');
        visit(input[keys[i]], depth + 1);
      }
      append('}');
    }
    ancestors.remove(input);
  }

  visit(value, 0);
  return output.toString();
}

void _moneyStrings(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key as String, item = entry.value;
      if (key.endsWith('Minor') ||
          key.endsWith('_minor') ||
          key.endsWith('Paise')) {
        if (item is! String ||
            item.length > 16 ||
            RegExp(r'^(0|[1-9][0-9]*)$').firstMatch(item)?.group(0) != item ||
            BigInt.parse(item) > BigInt.parse('9007199254740991')) {
          throw const FormatException(
            'Money requires exact minor-unit strings',
          );
        }
      }
      _moneyStrings(item);
    }
  } else if (value is List) {
    for (final item in value) {
      _moneyStrings(item);
    }
  }
}

final class SharedCommand {
  final String operationId;
  final String kind;
  final String contextId;
  final String canonicalJson;
  final String requestHash;
  SharedCommand._(
    this.operationId,
    this.kind,
    this.contextId,
    this.canonicalJson,
    this.requestHash,
  );
  factory SharedCommand({
    required String operationId,
    required String kind,
    required Map<String, Object?> payload,
  }) {
    if (!sharedUuid(operationId) ||
        !sharedCommandKinds.contains(kind) ||
        !sharedUuid(payload['contextId'])) {
      throw const FormatException('Invalid shared command identity');
    }
    final wire = sharedCanonicalJson({
      'schemaVersion': 1,
      'operationId': operationId,
      'kind': kind,
      'payload': payload,
    });
    _moneyStrings(jsonDecode(wire)['payload']);
    return SharedCommand._(
      operationId,
      kind,
      payload['contextId'] as String,
      wire,
      sha256.convert(utf8.encode(wire)).toString(),
    );
  }
  factory SharedCommand.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 4 ||
        value['schemaVersion'] != 1 ||
        !value.containsKey('operationId') ||
        !value.containsKey('kind') ||
        !value.containsKey('payload') ||
        value['payload'] is! Map) {
      throw const FormatException('Invalid shared command envelope');
    }
    return SharedCommand(
      operationId: value['operationId'] as String,
      kind: value['kind'] as String,
      payload: Map<String, Object?>.from(value['payload'] as Map),
    );
  }
  Map<String, Object?> toJson() =>
      Map<String, Object?>.from(jsonDecode(canonicalJson) as Map);
}

final class SharedOperationReceipt {
  final String operationId, kind, requestHash, contextId;
  final String _resultJson;
  SharedOperationReceipt({
    required this.operationId,
    required this.kind,
    required this.requestHash,
    required this.contextId,
    required Object? result,
  }) : _resultJson = sharedCanonicalJson(result, maxBytes: 262144) {
    if (!sharedUuid(operationId) ||
        !sharedUuid(contextId) ||
        !sharedCommandKinds.contains(kind) ||
        RegExp(r'^[0-9a-f]{64}$').firstMatch(requestHash)?.group(0) !=
            requestHash) {
      throw const FormatException('Invalid operation receipt');
    }
  }
  Object? get result => jsonDecode(_resultJson);
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'kind': kind,
    'requestHash': requestHash,
    'contextId': contextId,
    'result': result,
    'state': 'committed',
  };
  factory SharedOperationReceipt.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 6 ||
        value['state'] != 'committed' ||
        !value.containsKey('result')) {
      throw const FormatException('Invalid operation receipt');
    }
    return SharedOperationReceipt(
      operationId: value['operationId'] as String,
      kind: value['kind'] as String,
      requestHash: value['requestHash'] as String,
      contextId: value['contextId'] as String,
      result: value['result'],
    );
  }
}

const sharedProjectionEntities = {
  'contexts',
  'expenses',
  'members',
  'balances',
  'activity',
  'totals',
  'source_aliases',
  'personal_cost',
};

final class SharedProjection {
  final String entity, id, contextId;
  final int revision;
  final bool deleted;
  final String canonicalJson;
  SharedProjection({
    required this.entity,
    required this.id,
    required this.contextId,
    required this.revision,
    required Object? payload,
    this.deleted = false,
  }) : canonicalJson = sharedCanonicalJson(payload, maxBytes: 262144) {
    if (!sharedProjectionEntities.contains(entity) ||
        !sharedUuid(contextId) ||
        id.isEmpty ||
        id.length > 128 ||
        revision < 0 ||
        revision > 9007199254740991 ||
        payload is! Map) {
      throw const FormatException('Invalid shared projection');
    }
  }
  Map<String, Object?> get payload =>
      Map<String, Object?>.from(jsonDecode(canonicalJson) as Map);
}

final class SharedChangePage {
  final List<SharedProjection> records;
  final String? nextCursor;
  final bool hasMore;
  final List<String> revokedContextIds, grantedContextIds;
  SharedChangePage({
    required List<SharedProjection> records,
    required this.nextCursor,
    this.hasMore = false,
    List<String> revokedContextIds = const [],
    List<String> grantedContextIds = const [],
  }) : records = List.unmodifiable(records),
       revokedContextIds = List.unmodifiable(revokedContextIds),
       grantedContextIds = List.unmodifiable(grantedContextIds) {
    if (records.length > 100 ||
        nextCursor != null &&
            (nextCursor!.isEmpty || nextCursor!.length > 2048) ||
        hasMore && nextCursor == null) {
      throw const FormatException('Invalid shared change page');
    }
    for (final ids in [revokedContextIds, grantedContextIds]) {
      if (ids.length > 100 ||
          ids.toSet().length != ids.length ||
          ids.any((id) => !sharedUuid(id))) {
        throw const FormatException('Invalid context access change');
      }
    }
    if (revokedContextIds
        .toSet()
        .intersection(grantedContextIds.toSet())
        .isNotEmpty) {
      throw const FormatException('Conflicting context access change');
    }
  }
}
