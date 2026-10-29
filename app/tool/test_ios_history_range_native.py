#!/usr/bin/env python3
"""Compile and run Foundation-only range tests; synthetic inputs only."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pandapay-native-range-') as directory:
    target = Path(directory)
    (target / 'main.swift').write_bytes((root / 'test/native/history_range_test.swift').read_bytes())
    subprocess.run(['xcrun', 'swiftc', str(root / 'ios/Runner/DeviceHistoryRange.swift'), str(target / 'main.swift'), '-o', str(target / 'test')], check=True)
    subprocess.run([str(target / 'test')], check=True)
