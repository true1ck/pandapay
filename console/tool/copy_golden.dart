import 'dart:convert';
import 'dart:io';

/// Sort key independent of the OS path separator (a Windows backslash sorts
/// differently from a slash), so every platform writes the same bundle.
String _key(File f) => f.path.replaceAll(r'\', '/');

/// Run from console/ before tests or web builds.
void main() {
  final source = Directory('../tools/sms_golden');
  final target = Directory('assets/sms_golden');
  target.createSync(recursive: true);
  final items = <Map<String, dynamic>>[];
  for (final kind in ['cases', 'scenarios']) {
    final files =
        Directory('${source.path}/$kind')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => _key(a).compareTo(_key(b)));
    for (final file in files) {
      final body = jsonDecode(file.readAsStringSync());
      for (final row in body is List ? body : [body]) {
        items.add({'kind': kind, 'body': row});
      }
    }
  }
  File('${target.path}/bundle.json').writeAsStringSync(
    jsonEncode({
      'items': items,
      'contextBundle': {
        'senders': [
          for (final file
              in (Directory(
                  '../rules/sms/v2/senders',
                ).listSync().whereType<File>().toList()
                ..sort((a, b) => _key(a).compareTo(_key(b)))))
            ...jsonDecode(file.readAsStringSync()) as List,
        ],
      },
      'gates': jsonDecode(File('${source.path}/gates.json').readAsStringSync()),
      'baseline': jsonDecode(
        File('${source.path}/reports/latest.json').readAsStringSync(),
      ),
    }),
  );
  stdout.writeln('Copied ${items.length} SMS golden cases and scenarios.');
}
