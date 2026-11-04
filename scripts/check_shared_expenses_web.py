"""Compile the shared fixture calculations with Dart2JS and check them in Node.

This checks exact arithmetic on the JavaScript target, not browser/UI behavior.
Requires existing domain package metadata, Dart SDK and Node; installs nothing.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default=shutil.which('dart'))
    parser.add_argument('--node', default=shutil.which('node'))
    args = parser.parse_args()
    if not args.dart or not args.node:
        parser.error('Dart and Node executables are required')
    repo = Path(__file__).resolve().parents[1]
    package = repo / 'packages/pandapay_domain'
    config = package / '.dart_tool/package_config.json'
    if not config.exists():
        parser.error('Run pub get for pandapay_domain before this check')
    fixtures = repo / 'contracts/shared_expenses/v1'
    data = json.dumps({
        'domain': json.loads((fixtures / 'domain_vectors.json').read_text(encoding='utf-8')),
        'sources': json.loads((fixtures / 'source_reference_vectors.json').read_text(encoding='utf-8')),
    }).encode('utf-8')
    # Byte literals keep fixture text out of executable Dart syntax.
    source = '''import 'dart:convert';
import 'package:pandapay_domain/shared_expenses.dart';
void main() {
  final fixtures = jsonDecode(utf8.decode([__BYTES__]));
  var count = 0;
  for (final entry in <String, dynamic Function(Object?)>{
    'allocation':allocateSharedExpense, 'projection':projectSharedExpense,
    'personalCost':sharedPersonalCost, 'sourceInt':sourceIntToSharedMinor,
  }.entries) {
    for (final vector in fixtures['domain'][entry.key]) {
      if (jsonEncode(entry.value(vector['input'])) != jsonEncode(vector['expected'])) {
        throw StateError('JavaScript target mismatch: ${vector['id']}');
      }
      count++;
    }
  }
  for (final vector in fixtures['sources']['valid']) {
    final reference = SharedExpenseSourceReference.parse(vector['input']);
    if (reference.canonicalLegacySplitTarget != vector['target'] ||
        jsonEncode(reference.toJson()) != jsonEncode(vector['input'])) {
      throw StateError('JavaScript source mismatch: ${vector['id']}');
    }
    count++;
  }
  if (sharedMoneyFromMinor('9007199254740991').paise != 9007199254740991) {
    throw StateError('JavaScript Money conversion lost paise');
  }
  try {
    sharedMoneyFromMinor('9007199254740992');
    throw StateError('Unsafe Money conversion accepted');
  } on SharedExpenseException catch (e) {
    if (e.code != 'AGGREGATE_LIMIT_EXCEEDED') rethrow;
  }
  print(jsonEncode({'target':'Dart2JS on Node','vectorsPassed':count,'moneyBoundary':'passed'}));
}
'''.replace('__BYTES__', ','.join(str(value) for value in data))
    # TemporaryDirectory cleanup is limited to this checked workspace subtree.
    task_root = config.parent.resolve()
    if not task_root.is_relative_to(repo.resolve()):
        raise ValueError('Temporary compilation target escaped the repository')
    with tempfile.TemporaryDirectory(prefix='shared-expenses-web-', dir=task_root) as temp:
        entry = Path(temp) / 'check.dart'
        output = Path(temp) / 'check.js'
        entry.write_text(source, encoding='utf-8')
        subprocess.run([args.dart, 'compile', 'js', '--packages=' + str(config),
                        str(entry), '-o', str(output)], check=True, cwd=package)
        subprocess.run([args.node, '-e', 'global.self=globalThis;require(' +
                        json.dumps(str(output)) + ');'], check=True, cwd=package)


if __name__ == '__main__':
    main()
