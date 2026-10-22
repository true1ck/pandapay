import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Small deterministic fixture used by inspector and export UI tests. It
/// includes a category, card and transaction relationship plus a declared
/// device-only exclusion, matching the shape of the v1 manifest contract.
class PortableBackupFixture {
  final List<int> manifestBytes;
  final Map<String, List<int>> sectionBytes;

  const PortableBackupFixture({
    required this.manifestBytes,
    required this.sectionBytes,
  });
}

PortableBackupFixture makePortableBackupFixture({
  bool corruptDigest = false,
  bool breakRelationship = false,
}) {
  final categories = _ndjson([
    {'id': 'category-1', 'name': 'Food'},
  ]);
  final cards = _ndjson([
    {'id': 'card-1', 'name': 'Everyday card'},
  ]);
  final transactions = _ndjson([
    {
      'id': 'transaction-1',
      'category_id': breakRelationship ? 'missing-category' : 'category-1',
      'card_id': 'card-1',
      'amount': '250.00',
    },
  ]);
  final sections = <String, List<int>>{
    'categories.ndjson': categories,
    'cards.ndjson': cards,
    'transactions.ndjson': transactions,
  };
  final descriptors = <String, dynamic>{};
  for (final entry in sections.entries) {
    descriptors[entry.key] = {
      'count': _lineCount(entry.value),
      'byte_length': entry.value.length,
      'sha256': corruptDigest && entry.key == 'transactions.ndjson'
          ? '0' * 64
          : sha256.convert(entry.value).toString(),
    };
  }
  final manifest = <String, dynamic>{
    'format_version': 1,
    'backup_id': 'backup-fixture-1',
    'complete': true,
    'declared_exclusions': [
      'device_id',
      'push_token',
      'secure_storage',
    ],
    'sections': descriptors,
    'relationships': [
      {
        'from_section': 'transactions.ndjson',
        'field': 'category_id',
        'to_section': 'categories.ndjson',
      },
      {
        'from_section': 'transactions.ndjson',
        'field': 'card_id',
        'to_section': 'cards.ndjson',
      },
    ],
  };
  return PortableBackupFixture(
    manifestBytes: utf8.encode(jsonEncode(manifest)),
    sectionBytes: sections,
  );
}

List<int> _ndjson(List<Map<String, dynamic>> records) => utf8.encode(
      records.map(jsonEncode).join('\n') + '\n',
    );

int _lineCount(List<int> bytes) => utf8.decode(bytes).trim().split('\n').length;

