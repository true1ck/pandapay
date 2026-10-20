"""Inventory literal Dart HTTP call sites for manual review (not a Dart parser)."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
pattern = re.compile(r"\b(?P<receiver>http|_?client|_?http|_inner)\s*\.\s*(?P<method>get|post|put|patch|delete|send)\s*\(")
calls = []
for directory in (ROOT / 'app/lib', ROOT / 'console/lib'):
    for path in sorted(directory.rglob('*.dart')):
        source = path.read_text()
        for match in pattern.finditer(source):
            depth, quote, escape, end = 1, None, False, match.end()
            while end < len(source) and depth:
                char = source[end]
                if quote:
                    if escape:
                        escape = False
                    elif char == '\\':
                        escape = True
                    elif char == quote:
                        quote = None
                elif char in "\"'":
                    quote = char
                elif char == '(':
                    depth += 1
                elif char == ')':
                    depth -= 1
                end += 1
            body = source[match.end():end - 1]
            calls.append({'source': str(path.relative_to(ROOT)),
                          'line': source.count('\n', 0, match.start()) + 1,
                          'receiver': match['receiver'], 'method': match['method'].upper(),
                          'has_headers_argument': bool(re.search(r'\bheaders\s*:', body))})
result = {'date': '2026-10-20',
          'limits': 'Literal receiver/method call-site heuristic, not exhaustive Dart call-graph analysis. Auth/recovery helpers and inherited send/request headers require manual inspection.',
          'calls': calls}
(OUT / 'client-call-inventory.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'literal_http_calls': len(calls),
                  'without_explicit_headers': [call for call in calls if not call['has_headers_argument']]}, indent=2))
