"""Rollout tests use command stubs; they never contact Docker or production."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "restart-services.sh"
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
            for name in ("docker", "curl", "sleep"):
                command = directory / name
                command.write_text(STUB)
                command.chmod(0o755)
            log = directory / "commands.jsonl"
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                       COMMAND_LOG=str(log), DEPLOY_HEALTH_ATTEMPTS="2",
                       DEPLOY_HEALTH_INTERVAL_SECONDS="1", **settings)
            result = subprocess.run(["bash", str(SCRIPT)], env=env,
                                    text=True, capture_output=True, timeout=10)
            commands = [json.loads(line) for line in log.read_text().splitlines()]
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


if __name__ == "__main__":
    unittest.main()
