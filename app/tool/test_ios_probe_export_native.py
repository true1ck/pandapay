"""Synthetic export file tests; never reads a device or a customer message."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pandapay-probe-export-') as directory:
    target = Path(directory)
    (target / 'main.swift').write_bytes((root / 'test/native/probe_export_test.swift').read_bytes())
    subprocess.run(['xcrun', 'swiftc', str(root / 'ios/Runner/ProbeDiagnosticsExport.swift'),
                    str(target / 'main.swift'), '-o', str(target / 'test')], check=True)
    subprocess.run([str(target / 'test')], check=True)
