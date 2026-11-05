"""Deployment-order tests use temporary source and Docker/Git stubs only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "deploy" / "deploy.sh"
WRITERS = {"auth", "api", "rewards-worker"}

GIT_STUB = r'''#!/usr/bin/env python3
import io, json, os, sys, tarfile
args=sys.argv[1:]
with open(os.environ['COMMAND_LOG'],'a') as log: log.write(json.dumps(['git',args])+'\n')
if args and args[0]=='archive':
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
        info=tarfile.TarInfo('docker-compose.prod.yml')
        info.size=0
        archive.addfile(info, io.BytesIO())
        info=tarfile.TarInfo('docker-compose.backup-local.yml')
        info.size=1
        archive.addfile(info, io.BytesIO(b'\n'))
elif args and args[0]=='log':
    print('synthetic-target')
elif args and args[0]=='rev-parse':
    revision=args[-1]
    if revision=='--is-shallow-repository': print(os.environ.get('SHALLOW_REPOSITORY','false'))
    elif revision=='HEAD':
        if os.environ.get('NO_SERVER_HEAD')=='1': sys.exit(1)
        print(os.environ.get('SERVER_HEAD_SHA','1111111111111111'))
    elif revision=='refs/remotes/origin/master': print(os.environ.get('ORIGIN_MASTER_SHA','0123456789abcdef'))
    elif revision.endswith('^{commit}'): print('0123456789abcdef')
    else: sys.exit(1)
elif args and args[0]=='merge-base':
    if os.environ.get('SERVER_HEAD_IS_ANCESTOR','1')!='1': sys.exit(1)
elif args and args[0]=='fetch':
    pass
'''

DOCKER_STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
log=Path(os.environ['COMMAND_LOG'])
state=Path(os.environ['CONTAINER_STATE'])
running=set(state.read_text().splitlines())
with log.open('a') as out: out.write(json.dumps(['docker',args])+'\n')
if args[:1]==['start']:
    running.update(item.removesuffix('-old-id') for item in args[1:])
elif args[:1]==['ps']:
    for service in sorted(running): print('synthetic-id pandapay-prod '+service)
    if os.environ.get('REVIEWED_MAPS_SCRAPER')=='1':
        print('synthetic-maps-id pandapay-prod maps-scraper')
    if os.environ.get('UNREVIEWED_SERVICE')=='1':
        print('synthetic-other-id pandapay-prod unknown-writer')
    if os.environ.get('UNLABELED_SERVICE')=='1':
        print('synthetic-unlabeled-id pandapay-prod ')
    if os.environ.get('MISMATCHED_PROJECT')=='1':
        print('synthetic-mismatch-id other-project maps-scraper')
elif args[:1]==['stop']:
    for item in args[1:]: running.discard(item.removesuffix('-container'))
elif args[:1]==['compose']:
    if 'ps' in args and '-q' in args:
        if os.environ.get('FAIL_INVENTORY')=='1': sys.exit(24)
        pos=args.index('-q')+1
        for service in args[pos:]:
            if service in running: print(service+'-old-id')
    elif 'stop' in args:
        pos=args.index('stop')+1
        while pos < len(args) and args[pos].startswith('-'):
            pos += 2 if args[pos] == '--timeout' else 1
        running.difference_update(args[pos:])
    elif 'up' in args:
        services=[item for item in args if item in {'db-migrate','auth','api','rewards-worker','backup'}]
        if 'db-migrate' in services and os.environ.get('FAIL_MIGRATION')=='1': sys.exit(22)
        running.update(services)
    elif 'run' in args and 'backup' in args and os.environ.get('FAIL_BACKUP')=='1':
        sys.exit(23)
    elif 'run' in args and 'db-migrate' in args and os.environ.get('FAIL_PREFLIGHT')=='1':
        sys.exit(25)
elif args[:1]==['inspect']:
    print('running' if 'backup-container' in args[-1:] else 'healthy')
state.write_text('\n'.join(sorted(running)))
'''

CURL_STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
count_file=Path(os.environ['CURL_COUNT'])
count=int(count_file.read_text() or '0')+1 if count_file.exists() else 1
count_file.write_text(str(count))
with open(os.environ['COMMAND_LOG'],'a') as log: log.write(json.dumps(['curl',args])+'\n')
if os.environ.get('FAIL_AUTH_READY')=='1' and any('3210' in arg for arg in args): sys.exit(1)
if os.environ.get('FAIL_FINAL_HEALTH')=='1' and count > 2: sys.exit(1)
'''

TIMEOUT_STUB = r'''#!/usr/bin/env bash
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --foreground|--kill-after=*) shift ;;
    *s) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
'''

SLEEP_STUB = "#!/usr/bin/env bash\nexit 0\n"


class DeploySecurityOrderTest(unittest.TestCase):
    def test_shallow_history_is_completed_before_ancestry_check(self):
        result, commands, _ = self.run_deploy(SHALLOW_REPOSITORY="true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fetch = self.command_index(commands, lambda c: c[0] == "git" and "--unshallow" in c[1])
        ancestry = self.command_index(commands, lambda c: c[0] == "git" and "merge-base" in c[1])
        self.assertLess(fetch, ancestry)
        self.assertFalse(any(c[0] == "git" and any(arg.startswith("--depth") for arg in c[1]) for c in commands))

    def test_complete_history_does_not_request_unshallow(self):
        result, commands, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(c[0] == "git" and "--unshallow" in c[1] for c in commands))

    def run_deploy(self, **settings):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            app = base / "app"
            app.mkdir()
            (app / ".git").mkdir()
            (app / "deploy").mkdir()
            (app / "deploy" / "restart-services.sh").write_text(
                (ROOT / "deploy" / "restart-services.sh").read_text()
            )
            keys = [
                "ADMIN_DATABASE_URL", "APP_USER_PASSWORD", "API_DATABASE_URL",
                "AUTH_DATABASE_URL", "JWT_ACCESS_SECRET", "JWT_REFRESH_SECRET",
                "PHONE_LOOKUP_HMAC_KEY", "INBOUND_EMAIL_WEBHOOK_SECRET",
                "PARTNER_WEBHOOK_SECRET", "IMAP_ENCRYPTION_KEY", "CORS_ALLOWED_ORIGINS",
                "ENCRYPTION_KEY", "BACKUP_AGE_RECIPIENTS_FILE", "BACKUP_DESTINATION_A",
            "BACKUP_DESTINATION_B", "SMS_LEARNING_DATABASE_URL",
            "SMS_LEARNING_HMAC_KEY", "SMS_LEARNING_WORKER_DB_PASSWORD",
            ]
            env_file = app / ".env"
            env_file.write_text("".join(
                f"{key}={'synthetic-phone-lookup-key-over-32-bytes' if key == 'PHONE_LOOKUP_HMAC_KEY' else '' if key.startswith('SMS_LEARNING_') else 'synthetic-value-for-test'}\n"
                for key in keys
            ))
            with env_file.open("a") as output:
                output.write(settings.pop("HOST_BACKUP_CONFIG", ""))
            if settings.pop("OMIT_DESTINATIONS", "0") == "1":
                env_file.write_text("".join(line for line in env_file.read_text().splitlines(True)
                                           if not line.startswith("BACKUP_DESTINATION_")))
            bin_dir = base / "bin"
            bin_dir.mkdir()
            for name, body in (("git", GIT_STUB), ("docker", DOCKER_STUB),
                               ("curl", CURL_STUB), ("timeout", TIMEOUT_STUB),
                               ("sleep", SLEEP_STUB)):
                path = bin_dir / name
                path.write_text(body)
                path.chmod(0o755)
            log = base / "commands.jsonl"
            state = base / "containers.txt"
            initial_services = set(WRITERS)
            if settings.get("REVIEWED_MAPS_SCRAPER") == "1":
                initial_services.add("maps-scraper")
            state.write_text("\n".join(initial_services))
            curl_count = base / "curl-count"
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                       COMMAND_LOG=str(log), CONTAINER_STATE=str(state), CURL_COUNT=str(curl_count),
                       DEPLOY_MAINTENANCE_WINDOW_SECONDS="300", **settings)
            script = SCRIPT.read_text().replace(
                'APP_DIR="/home/ubuntu/apps/pandapay"', f'APP_DIR="{app}"'
            )
            test_script = base / "deploy.sh"
            test_script.write_text(script)
            result = subprocess.run(["bash", str(test_script), "0123456789abcdef"], cwd=app,
                                    env=env, text=True, capture_output=True, timeout=20)
            commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, commands, set(state.read_text().splitlines())

    @staticmethod
    def command_index(commands, predicate):
        return next(i for i, command in enumerate(commands) if predicate(command))

    def test_default_offhost_requires_destinations_before_downtime(self):
        result, commands, _ = self.run_deploy(OMIT_DESTINATIONS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BACKUP_DESTINATION_A", result.stdout)
        self.assertFalse(any(c[0] == "docker" for c in commands))

    def test_local_without_destinations_selects_override_only_for_target(self):
        result, commands, _ = self.run_deploy(
            HOST_BACKUP_CONFIG="BACKUP_MODE=local\n", OMIT_DESTINATIONS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        reset = self.command_index(commands, lambda c: c[0] == "git" and c[1][0] == "reset")
        for i, (tool, args) in enumerate(commands):
            if tool != "docker" or "compose" not in args:
                continue
            has_override = any(a.endswith("docker-compose.backup-local.yml") for a in args)
            target = any("/tmp/" in a and a.endswith("docker-compose.prod.yml") for a in args)
            self.assertEqual(has_override, target or i > reset, args)

    def test_invalid_or_duplicate_mode_blocks_before_downtime(self):
        for config in ("BACKUP_MODE=invalid\n", "BACKUP_MODE=\n",
                       "BACKUP_MODE=local\nBACKUP_MODE=offhost\n"):
            with self.subTest(config=config):
                result, commands, _ = self.run_deploy(HOST_BACKUP_CONFIG=config)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[0] == "docker" for c in commands))

    def test_local_backup_failure_preserves_original_writer_recovery(self):
        result, commands, running = self.run_deploy(
            HOST_BACKUP_CONFIG="BACKUP_MODE=local\n", OMIT_DESTINATIONS="1", FAIL_BACKUP="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(running.issuperset(WRITERS))
        self.assertFalse(any(c[0] == "git" and c[1][0] == "reset" for c in commands))

    def test_duplicate_backup_keys_block_before_downtime(self):
        for key in ("BACKUP_AGE_RECIPIENTS_FILE", "BACKUP_DESTINATION_A", "BACKUP_DESTINATION_B"):
            result, commands, _ = self.run_deploy(
                HOST_BACKUP_CONFIG=f"BACKUP_MODE=local\n{key}=duplicate\n")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(key, result.stdout)
            self.assertFalse(any(c[0] == "docker" for c in commands))

    def test_local_migration_failure_keeps_fence_and_uses_override(self):
        result, commands, running = self.run_deploy(
            HOST_BACKUP_CONFIG="BACKUP_MODE=local\n", OMIT_DESTINATIONS="1", FAIL_MIGRATION="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(running.isdisjoint(WRITERS))
        stops = [c[1] for c in commands if c[0] == "docker" and "compose" in c[1] and "stop" in c[1]]
        self.assertIn("docker-compose.backup-local.yml", stops[-1])

    def test_fences_all_writers_before_backup_and_migration_then_starts_target(self):
        result, commands, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build = self.command_index(commands, lambda c: c[0] == "docker" and "build" in c[1])
        stop = self.command_index(commands, lambda c: c[0] == "docker" and "stop" in c[1]
                                  and "compose" in c[1])
        backup = self.command_index(commands, lambda c: c[0] == "docker" and "run" in c[1]
                                    and "backup" in c[1])
        reset = self.command_index(commands, lambda c: c[0] == "git" and c[1][0] == "reset")
        migration = self.command_index(commands, lambda c: c[0] == "docker" and "up" in c[1]
                                       and "db-migrate" in c[1])
        auth_start = self.command_index(commands, lambda c: c[0] == "docker" and "up" in c[1]
                                        and c[1][-1] == "auth")
        self.assertLess(build, stop)
        preflights = [i for i,c in enumerate(commands) if c[0] == "docker" and "run" in c[1]
                      and "db-migrate" in c[1] and "--entrypoint" in c[1]]
        self.assertEqual(len(preflights), 2)
        self.assertTrue(all(build < i < stop for i in preflights))
        self.assertLess(stop, backup)
        self.assertLess(backup, reset)
        self.assertLess(reset, migration)
        self.assertLess(migration, auth_start)
        for service in WRITERS:
            self.assertIn(service, commands[stop][1])

    def test_migration_failure_keeps_writers_stopped_and_never_starts_target(self):
        result, commands, running = self.run_deploy(FAIL_MIGRATION="1")
        self.assertNotEqual(result.returncode, 0)
        stops = [i for i, c in enumerate(commands) if c[0] == "docker" and "stop" in c[1]
                 and "compose" in c[1]]
        migration = self.command_index(commands, lambda c: c[0] == "docker" and "up" in c[1]
                                       and "db-migrate" in c[1])
        self.assertGreater(len(stops), 1)
        self.assertGreater(stops[-1], migration)
        self.assertTrue(running.isdisjoint(WRITERS))
        self.assertIn("Recover forward", result.stderr)

    def test_backup_failure_resumes_all_captured_original_container_ids(self):
        result, commands, running = self.run_deploy(FAIL_BACKUP="1")
        self.assertNotEqual(result.returncode, 0)
        started = next(c[1][1:] for c in commands if c[0] == "docker" and c[1][0] == "start")
        self.assertEqual(set(started), {f"{service}-old-id" for service in WRITERS})
        self.assertTrue(running.issuperset(WRITERS))
        self.assertFalse(any(c[0] == "git" and c[1][0] == "reset" for c in commands))
        self.assertFalse(any(c[0] == "docker" and "up" in c[1]
                             and "db-migrate" in c[1] for c in commands))

    def test_failed_container_inventory_aborts_before_fencing(self):
        result, commands, running = self.run_deploy(FAIL_INVENTORY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "docker" and "stop" in c[1] for c in commands))
        self.assertFalse(any(c[0] == "docker" and c[1][0] == "start" for c in commands))
        self.assertTrue(running.issuperset(WRITERS))

    def test_failed_read_only_preflight_preserves_running_services_and_source(self):
        result, commands, running = self.run_deploy(FAIL_PREFLIGHT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "docker" and "stop" in c[1] for c in commands))
        self.assertFalse(any(c[0] == "git" and c[1][0] == "reset" for c in commands))
        self.assertTrue(running.issuperset(WRITERS))

    def test_unreviewed_running_service_blocks_downtime_instead_of_missing_a_writer(self):
        result, commands, running = self.run_deploy(UNREVIEWED_SERVICE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unreviewed production service", result.stderr)
        self.assertFalse(any(c[0] == "docker" and "stop" in c[1] for c in commands))
        self.assertFalse(any(c[0] == "git" and c[1][0] == "reset" for c in commands))
        self.assertTrue(running.issuperset(WRITERS))

    def test_exact_reviewed_stateless_maps_scraper_is_left_running(self):
        result, commands, running = self.run_deploy(REVIEWED_MAPS_SCRAPER="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any("synthetic-maps-id" in c[1] or "maps-scraper" in c[1]
                             for c in commands if c[0] == "docker" and "stop" in c[1]))
        self.assertIn("maps-scraper", running)

    def test_missing_or_mismatched_compose_labels_block_before_downtime(self):
        for setting in ({"UNLABELED_SERVICE": "1"}, {"MISMATCHED_PROJECT": "1"}):
            with self.subTest(setting=setting):
                result, commands, running = self.run_deploy(**setting)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Compose labels", result.stderr)
                self.assertFalse(any(c[0] == "docker" and "stop" in c[1] for c in commands))
                self.assertTrue(running.issuperset(WRITERS))

    def test_stale_target_that_is_not_current_source_ref_fails_before_build_or_downtime(self):
        result, commands, running = self.run_deploy(ORIGIN_MASTER_SHA="fedcba9876543210")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must equal the current source ref tip", result.stderr)
        self.assertFalse(any(c[0] == "docker" and "build" in c[1] for c in commands))
        self.assertFalse(any(c[0] == "docker" and "stop" in c[1] for c in commands))
        self.assertTrue(running.issuperset(WRITERS))

    def test_server_head_not_ancestor_fails_before_build_or_downtime(self):
        result, commands, running = self.run_deploy(SERVER_HEAD_IS_ANCESTOR="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a descendant of the server HEAD", result.stderr)
        self.assertFalse(any(c[0] == "docker" and "build" in c[1] for c in commands))
        self.assertFalse(any(c[0] == "docker" and "stop" in c[1] for c in commands))
        self.assertTrue(running.issuperset(WRITERS))

    def test_unanchored_legacy_checkout_fails_before_build_or_downtime(self):
        result, commands, running = self.run_deploy(NO_SERVER_HEAD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no verifiable HEAD", result.stderr)
        self.assertFalse(any(c[0] == "docker" and "build" in c[1] for c in commands))
        self.assertFalse(any(c[0] == "docker" and "stop" in c[1] for c in commands))
        self.assertTrue(running.issuperset(WRITERS))

    def test_deploy_workflow_checks_master_tip_before_ssh_deploy(self):
        workflow = (ROOT / ".github" / "workflows" / "deploy-prod.yml").read_text()
        gate = workflow.index("Confirm the tested target is still current master")
        deploy = workflow.index("- name: Deploy\n", gate)
        self.assertIn("git/ref/heads/master", workflow[gate:deploy])
        self.assertIn('current_master_sha" != "$SHA"', workflow[gate:deploy])

    def test_partial_service_start_is_stopped_when_readiness_fails(self):
        result, commands, running = self.run_deploy(FAIL_AUTH_READY="1")
        self.assertNotEqual(result.returncode, 0)
        auth_start = self.command_index(commands, lambda c: c[0] == "docker" and "up" in c[1]
                                       and c[1][-1] == "auth")
        stop = next(i for i, c in enumerate(commands) if i > auth_start and c[0] == "docker"
                    and "stop" in c[1] and "compose" in c[1])
        self.assertGreater(stop, auth_start)
        self.assertTrue(running.isdisjoint(WRITERS))

    def test_final_health_failure_keeps_fence_active_and_stops_started_services(self):
        result, commands, running = self.run_deploy(FAIL_FINAL_HEALTH="1")
        self.assertNotEqual(result.returncode, 0)
        api_start = self.command_index(commands, lambda c: c[0] == "docker" and "up" in c[1]
                                      and c[1][-1] == "api")
        stops = [i for i, c in enumerate(commands) if c[0] == "docker" and "stop" in c[1]
                 and "compose" in c[1]]
        self.assertGreater(stops[-1], api_start)
        self.assertTrue(running.isdisjoint(WRITERS))


if __name__ == "__main__":
    unittest.main()
