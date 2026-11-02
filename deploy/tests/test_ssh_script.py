"""Exercise SSH script delivery through a real shell with an stdin-reading child."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TRANSPORT = ROOT / "deploy" / "ssh_script.sh"

SSH_STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['SSH_ARGV_LOG']).write_text(json.dumps(sys.argv[1:]))
if os.environ.get('FAIL_SSH') == '1':
    sys.exit(255)
# The real SSH server gives this command to the user's login shell. Run the
# same wrapper locally; stdin is still the caller's streamed script.
os.execv('/bin/sh', ['sh', '-c', sys.argv[-1]])
'''


class SshScriptTest(unittest.TestCase):
    def run_transport(self, script, *arguments, **settings):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            bin_dir = base / "bin"
            bin_dir.mkdir()
            ssh = bin_dir / "ssh"
            ssh.write_text(SSH_STUB)
            ssh.chmod(0o755)
            scratch = base / "remote-temp"
            scratch.mkdir()
            argv_log = base / "ssh-argv.json"
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                       TMPDIR=str(scratch), SSH_ARGV_LOG=str(argv_log), **settings)
            result = subprocess.run(
                ["bash", str(TRANSPORT), "deploy@example.invalid", *arguments],
                input=script, text=True, capture_output=True, env=env, timeout=10,
            )
            argv = json.loads(argv_log.read_text()) if argv_log.exists() else None
            leftovers = list(scratch.iterdir())
            return result, argv, leftovers

    def test_streamed_shell_reproduces_the_source_consumption_failure(self):
        script = "cat >/dev/null\nprintf 'DEPLOYED\\n'\n"
        result = subprocess.run(["bash", "-s"], input=script, text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("DEPLOYED", result.stdout)

    def test_child_cannot_consume_source_and_payload_stays_out_of_argv(self):
        script = r'''set -euo pipefail
export SYNTHETIC_DEPLOY_SECRET='not-a-real-key: $(never-run)'
python3 -c 'import json,os,stat,sys; print(json.dumps({"stdin_bytes":len(sys.stdin.read()), "mode":stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "args":sys.argv[2:], "secret_available":bool(os.environ.get("SYNTHETIC_DEPLOY_SECRET"))}))' "$0" "$1" "$2"
printf 'DEPLOYED\n'
'''
        result, argv, leftovers = self.run_transport(script, "a" * 40, "codex/release")
        self.assertEqual(result.returncode, 0, result.stderr)
        facts = json.loads(result.stdout.splitlines()[0])
        self.assertEqual(facts, {"stdin_bytes": 0, "mode": 0o600,
                                 "args": ["a" * 40, "codex/release"],
                                 "secret_available": True})
        self.assertIn("DEPLOYED", result.stdout)
        self.assertNotIn("SYNTHETIC_DEPLOY_SECRET", json.dumps(argv))
        self.assertNotIn("not-a-real-key", json.dumps(argv))
        self.assertEqual(leftovers, [])
        self.assertIn("StrictHostKeyChecking=yes", argv)
        self.assertIn("BatchMode=yes", argv)

    def test_failure_status_is_preserved_and_remote_file_is_removed(self):
        result, _, leftovers = self.run_transport(
            "set -e\ncat >/dev/null\nexit 17\nprintf 'WRONG_SUCCESS\\n'\n", "a" * 40)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertNotIn("WRONG_SUCCESS", result.stdout)
        self.assertEqual(leftovers, [])

    def test_payload_can_supply_its_own_explicit_stdin(self):
        result, _, leftovers = self.run_transport(
            "set -e\ncat <<'DATA'\nexpected SQL input\nDATA\nprintf 'DEPLOYED\\n'\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "expected SQL input\nDEPLOYED\n")
        self.assertEqual(leftovers, [])

    def test_ssh_failure_is_not_reported_as_success(self):
        result, _, leftovers = self.run_transport("printf 'DEPLOYED\\n'\n", FAIL_SSH="1")
        self.assertEqual(result.returncode, 255)
        self.assertEqual(leftovers, [])

    def test_invalid_identifier_is_rejected_before_ssh(self):
        result, argv, leftovers = self.run_transport("printf 'DEPLOYED\\n'\n", "ref; touch injected")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(argv)
        self.assertEqual(leftovers, [])

    def test_both_deployments_and_baseline_check_use_spooled_transport(self):
        master = (ROOT / ".github/workflows/deploy-prod.yml").read_text()
        branch = (ROOT / ".github/workflows/deploy-pushed-branch.yml").read_text()
        self.assertIn('} | bash deploy/ssh_script.sh "$DEPLOY_USER@$HOST" "$SHA"', master)
        self.assertIn('} | bash deploy/ssh_script.sh "$DEPLOY_USER@$HOST" "$SHA" "$SOURCE_REF"', branch)
        self.assertNotIn('"bash -s --', master)
        self.assertNotIn('"bash -s --', branch)
        inspection = branch.split("  inspect-migration-baseline:", 1)[1].split("  verify:", 1)[0]
        self.assertIn('bash deploy/ssh_script.sh "$DEPLOY_USER@$HOST" "$TARGET_SHA" "$SOURCE_REF"', inspection)
        self.assertIn('baseline_file=existing_not_overwritten', inspection)
        self.assertIn('baseline_schema_sha256=', inspection)
        self.assertIn('baseline_ledger=', inspection)
        check = inspection.split('-e MIGRATION_ADOPT_LEGACY_CHECKSUMS=true', 1)[1]
        self.assertIn('/db/scripts/product_migrate.js --check', check)
        self.assertIn('baseline_current_database_match=true', check)
        self.assertIn('adoption=not_performed', check)


if __name__ == "__main__":
    unittest.main()
