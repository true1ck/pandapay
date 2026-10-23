"""Focused idempotency tests for the local recovery folder preparer."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "setup_local_recovery", ROOT / "db/scripts/setup_local_recovery.py"
)
setup_local_recovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup_local_recovery)


class SetupLocalRecoveryTest(unittest.TestCase):
    def test_copy_tool_accepts_same_file_and_keeps_private_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            tool = Path(directory) / "tools" / "age"
            tool.parent.mkdir()
            tool.write_bytes(b"existing age executable")
            tool.chmod(0o600)

            setup_local_recovery.copy_tool(tool, tool)

            self.assertEqual(tool.read_bytes(), b"existing age executable")
            self.assertEqual(os.stat(tool).st_mode & 0o777, 0o700)

    def test_repeated_setup_preserves_existing_identity_and_installed_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Recovery"
            root = root.resolve()
            tools = root / "tools"
            keys = root / "keys"
            tools.mkdir(parents=True)
            keys.mkdir()
            age = tools / "age"
            age_keygen = tools / "age-keygen"
            identity = keys / "recovery-identity.txt"
            recipients = root / "public-recipients.txt"
            env_file = root / "backup.env"
            age.write_bytes(b"preserve age binary")
            age_keygen.write_bytes(b"preserve age-keygen binary")
            identity.write_bytes(b"preserve existing private identity\n")
            recipients.write_text("age1syntheticrecipient\n")
            env_file.write_text("preserve existing protected settings\n")
            for file in (age, age_keygen, identity, recipients, env_file):
                file.chmod(0o600)

            before = {file: file.read_bytes() for file in (age, age_keygen, identity, recipients, env_file)}
            argv = [
                "setup_local_recovery.py",
                str(root),
                "--age", str(age),
                "--age-keygen", str(age_keygen),
            ]
            fake_process = type("ProcessResult", (), {"stdout": "age1syntheticrecipient\n"})()
            for _ in range(2):
                with patch("sys.argv", argv), patch.object(
                    setup_local_recovery.subprocess, "run", return_value=fake_process
                ) as run, contextlib.redirect_stdout(io.StringIO()):
                    setup_local_recovery.main()
                run.assert_called_once_with(
                    [str(age_keygen), "-y", str(identity)],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual({file: file.read_bytes() for file in before}, before)

            self.assertEqual(os.stat(age).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(age_keygen).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(identity).st_mode & 0o777, 0o600)
            self.assertTrue((root / "app.pandapay.local-recovery.plist").is_file())


if __name__ == "__main__":
    unittest.main()
