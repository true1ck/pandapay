"""Rollout tests use command stubs; they never contact Docker or production."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "restart-services.sh"
BACKUP_ENV = (
    "BACKUP_AGE_RECIPIENTS_FILE=/synthetic/public-recipients.txt\n"
    "BACKUP_DESTINATION_A=/synthetic/offhost-a\n"
    "BACKUP_DESTINATION_B=/synthetic/offhost-b\n"
)
AI_ENV = (
    "GEMINI_API_KEY=synthetic-gemini-key\n"
    "SMS_AI_WORKER_DB_PASSWORD=synthetic-sms-ai-worker-password-0123456789\n"
    "SMS_AI_WORKER_DATABASE_URL=postgresql://sms_ai_worker@db.invalid/postgres\n"
    "SMS_V2_AI_MODEL=synthetic-model\n"
    "SMS_V2_AI_TPM=100000\n"
    "SMS_V2_AI_INPUT_USD_PER_MILLION=0.10\n"
    "SMS_V2_AI_OUTPUT_USD_PER_MILLION=0.40\n"
)
WORKER = "sms-v2-template-worker"

STUB = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['COMMAND_LOG'],'a') as log:
 log.write(json.dumps([name,args,os.environ.get('COMPOSE_PARALLEL_LIMIT')])+'\n')
if name=='docker':
 if 'build' in args and args[-1]==os.environ.get('FAIL_BUILD'):sys.exit(1)
 if 'ps' in args:print(args[-1]+'-container')
 if args and args[0]=='inspect':
  service=args[-1].removesuffix('-container')
  print('unhealthy' if service==os.environ.get('FAIL_HEALTH') else 'running' if service=='backup' else 'healthy')
if name=='curl' and os.environ.get('FAIL_AUTH') and any('3210' in arg for arg in args):sys.exit(1)
'''


class SequentialRolloutTest(unittest.TestCase):
    def rollout(self, **settings):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            env_content = settings.pop("ENV_CONTENT", "")
            backup_env = settings.pop("BACKUP_ENV_CONTENT", BACKUP_ENV)
            (directory / ".env").write_text(backup_env + env_content)
            for name in ("docker", "curl", "sleep"):
                command = directory / name
                command.write_text(STUB)
                command.chmod(0o755)
            log = directory / "commands.jsonl"
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                       COMMAND_LOG=str(log), DEPLOY_HEALTH_ATTEMPTS="2",
                       DEPLOY_HEALTH_INTERVAL_SECONDS="1", **settings)
            result = subprocess.run(["bash", str(SCRIPT)], cwd=directory, env=env,
                                    text=True, capture_output=True, timeout=10)
            commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, commands

    def test_builds_then_restarts_each_service_with_readiness_gates(self):
        result, commands = self.rollout()
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [args[-1] for name, args, _ in commands if name == "docker" and "build" in args]
        starts = [args[-1] for name, args, _ in commands if name == "docker" and "up" in args]
        self.assertEqual(builds, ["auth", "api", "rewards-worker", "backup"])
        self.assertEqual(starts, builds)
        self.assertTrue(all(limit == "1" for _, _, limit in commands))
        self.assertTrue(all("--no-build" in args and "--no-deps" in args
                            for name, args, _ in commands if name == "docker" and "up" in args))
        first_start = next(i for i, (_, args, _) in enumerate(commands) if "up" in args)
        self.assertEqual(sum(name == "docker" and "build" in args
                             for name, args, _ in commands[:first_start]), 4)
        # HTTP/container readiness must precede replacement of the next service.
        for service, marker in [("api", "3210"), ("rewards-worker", "4000")]:
            start = next(i for i, (name, args, _) in enumerate(commands)
                         if name == "docker" and "up" in args and args[-1] == service)
            self.assertTrue(any(name == "curl" and any(marker in arg for arg in args)
                                for name, args, _ in commands[:start]))

    def test_ai_worker_is_skipped_unless_every_setting_is_present(self):
        partial = "".join(line for line in AI_ENV.splitlines(True)
                          if not line.startswith("SMS_V2_AI_TPM="))
        quoted_empty = AI_ENV.replace("GEMINI_API_KEY=synthetic-gemini-key", 'GEMINI_API_KEY=""')
        for env_content in ("", partial, quoted_empty):
            result, commands = self.rollout(ENV_CONTENT=env_content)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(any(WORKER in args for name, args, _ in commands if name == "docker"),
                             env_content)

    def test_ai_worker_is_built_and_started_last_when_configured(self):
        result, commands = self.rollout(ENV_CONTENT=AI_ENV)
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [args[-1] for name, args, _ in commands if name == "docker" and "build" in args]
        starts = [args[-1] for name, args, _ in commands if name == "docker" and "up" in args]
        self.assertEqual(builds, ["auth", "api", "rewards-worker", "backup", WORKER])
        self.assertEqual(starts, builds)
        # It is opt-in AND last: every core service is up before it starts.
        worker_start = next(i for i, (name, args, _) in enumerate(commands)
                            if name == "docker" and "up" in args and args[-1] == WORKER)
        core_starts = [i for i, (name, args, _) in enumerate(commands)
                       if name == "docker" and "up" in args and args[-1] != WORKER]
        self.assertTrue(all(i < worker_start for i in core_starts))

    def test_prebuilt_mode_does_not_rebuild_the_ai_worker(self):
        result, commands = self.rollout(ENV_CONTENT=AI_ENV, DEPLOY_IMAGES_PREBUILT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("build" in args for name, args, _ in commands if name == "docker"))
        starts = [args[-1] for name, args, _ in commands if name == "docker" and "up" in args]
        self.assertEqual(starts[-1], WORKER)

    def test_ai_worker_failing_to_become_ready_is_stopped_and_never_fails_the_release(self):
        result, commands = self.rollout(ENV_CONTENT=AI_ENV, FAIL_HEALTH=WORKER)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING", result.stderr)
        self.assertTrue(any(name == "docker" and "stop" in args and args[-1] == WORKER
                            for name, args, _ in commands))

    def test_ai_worker_build_failure_does_not_fail_the_release(self):
        result, commands = self.rollout(ENV_CONTENT=AI_ENV, FAIL_BUILD=WORKER)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING", result.stderr)

    def test_missing_backup_recipient_blocks_before_docker(self):
        result, commands = self.rollout(BACKUP_ENV_CONTENT="BACKUP_MODE=local\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BACKUP_AGE_RECIPIENTS_FILE", result.stderr)
        self.assertFalse(commands)

    def test_default_offhost_missing_either_destination_blocks_before_docker(self):
        for key in ("BACKUP_DESTINATION_A", "BACKUP_DESTINATION_B"):
            with self.subTest(key=key):
                backup_env = "".join(line for line in BACKUP_ENV.splitlines(True)
                                     if not line.startswith(key + "="))
                result, commands = self.rollout(BACKUP_ENV_CONTENT=backup_env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)
                self.assertFalse(commands)

    def test_local_without_destinations_selects_override_for_all_compose_calls(self):
        result, commands = self.rollout(BACKUP_ENV_CONTENT=
            "BACKUP_MODE=local\nBACKUP_AGE_RECIPIENTS_FILE=/synthetic/public.txt\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        compose_calls = [args for name, args, _ in commands
                         if name == "docker" and args[0] == "compose"]
        self.assertTrue(compose_calls)
        self.assertTrue(all("docker-compose.backup-local.yml" in args for args in compose_calls))

    def test_invalid_duplicate_or_empty_backup_settings_block_before_docker(self):
        for extra in ("BACKUP_MODE=invalid\n", "BACKUP_MODE=\n",
                      "BACKUP_MODE=local\nBACKUP_MODE=offhost\n",
                      "BACKUP_AGE_RECIPIENTS_FILE=duplicate\n",
                      "BACKUP_DESTINATION_A=duplicate\n"):
            with self.subTest(extra=extra):
                result, commands = self.rollout(ENV_CONTENT=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(commands)

    def test_failed_build_leaves_running_services_untouched(self):
        result, commands = self.rollout(FAIL_BUILD="api")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("up" in args for _, args, _ in commands))

    def test_failed_auth_readiness_stops_before_api_restart(self):
        result, commands = self.rollout(FAIL_AUTH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([args[-1] for name, args, _ in commands
                          if name == "docker" and "up" in args], ["auth"])
        self.assertIn("auth did not become ready", result.stdout)

    def test_failed_worker_readiness_stops_before_backup_restart(self):
        result, commands = self.rollout(FAIL_HEALTH="rewards-worker")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(name == "docker" and "up" in args and args[-1] == "backup"
                             for name, args, _ in commands))

    def test_prebuilt_mode_skips_all_image_builds(self):
        result, commands = self.rollout(DEPLOY_IMAGES_PREBUILT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(name == "docker" and "build" in args
                             for name, args, _ in commands))
        self.assertTrue(any(name == "docker" and "up" in args and args[-1] == "auth"
                            for name, args, _ in commands))


if __name__ == "__main__":
    unittest.main()
