"""Reuse installed OWASP scanners, redact snippets, preserve previous scan files."""
import importlib.util
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
SKILL = Path('/Users/chandresh_kerkar/.claude/skills/owasp-mobile-security-checker/scripts')


def load(name):
    spec = importlib.util.spec_from_file_location(name, SKILL / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


result = {'date': '2026-10-20', 'note': 'Scanner heuristics require manual triage. Outdated versions or missing pinning alone are not proven vulnerabilities.', 'scans': {}}
for category, name in [('M1', 'scan_hardcoded_secrets'), ('M5', 'check_network_security'), ('M9', 'analyze_storage_security')]:
    scan = load(name).scan_project(str(ROOT / 'app'))
    sanitized = []
    for finding in scan.get('findings', []):
        sanitized.append({key: value for key, value in finding.items() if key not in ('code', 'pattern', 'match', 'value', 'content')})
    scan['findings'] = sanitized
    result['scans'][category] = scan

dependencies = load('check_dependencies')
pubspec = dependencies.load_pubspec(str(ROOT / 'app'))
outdated = dependencies.check_outdated_packages(str(ROOT / 'app'))
result['scans']['M2'] = {'constraint_findings': dependencies.check_version_constraints(pubspec),
    'static_threshold_findings': dependencies.check_dangerous_packages(pubspec),
    'outdated_packages': dependencies.analyze_outdated_results(outdated)}
(OUT / 'mobile-scanner-results.redacted.json').write_text(json.dumps(result, indent=2) + '\n')
for category, scan in result['scans'].items():
    if category == 'M2':
        print(json.dumps({'category': category, 'constraints': len(scan['constraint_findings']), 'static_threshold': len(scan['static_threshold_findings']), 'outdated': len(scan['outdated_packages'])}))
    else:
        print(json.dumps({'category': category, 'files': scan.get('total_files_scanned'), 'findings': scan.get('total_findings'), 'severity': dict(Counter(finding.get('severity') for finding in scan['findings']))}))
