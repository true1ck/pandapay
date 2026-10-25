"""Synthetic command-flow coverage for paired encrypted backup/restore scripts."""
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import importlib.util
import io
import ssl
import hashlib
from types import SimpleNamespace
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BACKUP = ROOT / "db/scripts/backup.sh"
RESTORE = ROOT / "db/scripts/restore_drill.sh"


spec = importlib.util.spec_from_file_location('backup_storage', ROOT / 'db/scripts/backup_storage.py')
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


class BackupStorageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.environment = patch.dict(os.environ, {'BACKUP_MAX_USAGE_PERCENT': '99',
            'BACKUP_MIN_FREE_BYTES': '1', 'BACKUP_MAX_BYTES': '1048576',
            'BACKUP_MAX_SETS': '7', 'RETENTION_DAYS': '7'})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.tmp.cleanup()

    def complete(self, number, verified=False):
        path = self.root / f'{number:032x}'
        path.mkdir()
        checksums = []
        for name, payload in (('product.dump.age', b'product' + bytes([number])),
                              ('auth.dump.age', b'auth' + bytes([number])),
                              ('manifest.json.age', b'manifest' + bytes([number]))):
            (path / name).write_bytes(payload)
            checksums.append(f'{hashlib.sha256(payload).hexdigest()}  {name}')
        (path / 'checksums.sha256').write_text('\n'.join(checksums) + '\n')
        (path / 'OFFSITE_COMPLETE').write_text(
            f'set_id={path.name}\nstatus=offsite_uploaded\ncompleted_epoch={number}\n')
        if verified:
            (path / 'RESTORE_VERIFIED').write_text('verified')
        return path

    def test_retention_keeps_two_recent_and_two_newest_proven_restores(self):
        for number in range(1, 11):
            self.complete(number, verified=number in (1, 3, 5))
        storage.prepare(self.root, incoming=False)
        self.assertEqual({p.name for _, p in storage.inventory(self.root)},
                         {f'{i:032x}' for i in (3, 5, 9, 10)})

    def test_corrupt_recent_marked_sets_cannot_displace_intact_paired_recovery(self):
        for number in range(1, 11):
            self.complete(number, verified=number in (1, 3))
        # A completion marker alone must not make a partial/corrupt recent set
        # count as recoverable or cause an older intact pair to be pruned.
        (self.root / f'{9:032x}' / 'auth.dump.age').write_bytes(b'corrupt')
        (self.root / f'{10:032x}' / 'manifest.json.age').unlink()
        storage.prepare(self.root, incoming=False)
        self.assertEqual({p.name for _, p in storage.inventory(self.root)},
                         {f'{i:032x}' for i in (1, 3, 7, 8)})

    def test_no_restore_markers_still_preserves_two_intact_generations(self):
        for number in range(1, 11):
            self.complete(number)
        (self.root / f'{9:032x}' / 'auth.dump.age').write_bytes(b'corrupt')
        (self.root / f'{10:032x}' / 'manifest.json.age').unlink()
        storage.prepare(self.root, incoming=False)
        self.assertEqual({p.name for _, p in storage.inventory(self.root)},
                         {f'{i:032x}' for i in (7, 8)})
        self.assertTrue((self.root / f'{9:032x}').exists())
        self.assertTrue((self.root / f'{10:032x}').exists())

    def test_count_limit_applies_to_recent_predeploy_generations_too(self):
        import time
        for number in range(1, 11):
            path = self.complete(number)
            (path / 'OFFSITE_COMPLETE').write_text(f'set_id={path.name}\nstatus=offsite_uploaded\ncompleted_epoch={int(time.time()) + number}\n')
        storage.prepare(self.root)
        self.assertEqual(len(storage.inventory(self.root)), 6)  # room for incoming seventh

    def test_integrity_scan_is_once_per_set_and_invalid_metadata_is_preserved(self):
        for number in range(1, 11):
            self.complete(number)
        with patch.object(storage, 'valid_ciphertext_set', wraps=storage.valid_ciphertext_set) as checked:
            storage.prepare(self.root, incoming=False)
        self.assertEqual(checked.call_count, 10)
        invalid = self.complete(11)
        (invalid / 'checksums.sha256').write_text('x' * 4097)
        self.assertFalse(storage.valid_ciphertext_set(invalid))
        storage.prepare(self.root, incoming=False)
        self.assertTrue(invalid.exists(), 'damaged marked sets require operator review')

    def test_prepare_removes_only_exact_unmarked_generated_residues(self):
        pending = self.root / ('.pending-' + 'a' * 32)
        interrupted = self.root / ('b' * 32)
        completed = self.root / ('c' * 32)
        unrelated = self.root / '.pending-operator-data'
        for path in (pending, interrupted, completed, unrelated):
            path.mkdir()
        (completed / 'LOCAL_COMPLETE').write_text('complete')
        storage.prepare(self.root, incoming=False)
        self.assertFalse(pending.exists())
        self.assertFalse(interrupted.exists())
        self.assertTrue(completed.exists())
        self.assertTrue(unrelated.exists())

    def test_lock_many_locks_all_roots_and_releases_after_child(self):
        other = self.root / 'other'
        other.mkdir()
        result = subprocess.run(['python3', str(ROOT / 'db/scripts/backup_storage.py'),
            'lock-many', str(self.root), str(other), 'cmd:', 'true'], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        for root in (self.root, other):
            with (root / '.backup.lock').open('a') as lock:
                import fcntl
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_sha256sum_helper_falls_back_to_macos_shasum(self):
        fallback = self.root / 'shasum'
        fallback.write_text('#!/bin/sh\nprintf "fallback:%s\\n" "$*"\n')
        fallback.chmod(0o755)
        result = subprocess.run(['/bin/bash', '-c',
            'source "$1"; sha256sum file.bin', 'bash',
            str(ROOT / 'db/scripts/backup_common.sh')],
            env={"PATH": str(self.root)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'fallback:-a 256 file.bin')

    def test_full_cap_does_not_delete_protected_recovery_sets(self):
        first, second = self.complete(1, True), self.complete(2)
        with patch.dict(os.environ, {'BACKUP_MAX_BYTES': '100'}):
            with self.assertRaisesRegex(ValueError, 'cap reached'):
                storage.prepare(self.root)
        self.assertTrue(first.exists() and second.exists())

    def test_ciphertext_stream_stops_before_exceeding_quota(self):
        pending = self.root / '.pending-test'
        pending.mkdir()
        output = pending / 'product.dump.age'
        with patch.dict(os.environ, {'BACKUP_MAX_BYTES': '8192'}), \
             patch.object(storage.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'x' * 20000))):
            with self.assertRaisesRegex(ValueError, 'cap reached'):
                storage.limited_write(self.root, output)
        self.assertLessEqual(storage.size(self.root), 8192)

    def test_disk_reserve_stops_before_any_new_data_is_written(self):
        with patch.object(storage.shutil, 'disk_usage', return_value=SimpleNamespace(total=10000, used=9500, free=500)):
            with self.assertRaisesRegex(ValueError, 'disk reserve'):
                storage.check_capacity(self.root, 1000)

    def test_concurrent_job_cannot_acquire_existing_lock(self):
        import fcntl
        with (self.root / '.backup.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run(['python3', str(ROOT / 'db/scripts/backup_storage.py'),
                'lock', str(self.root), 'touch', str(self.root / 'should-not-exist')], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'should-not-exist').exists())


class ManifestNormalizationTest(unittest.TestCase):
    def test_manifest_loader_accepts_v5_and_requires_fresh_v5_for_v4(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'manifest.json'
            path.write_text(json.dumps({'format': 'pandapay-paired-postgresql-backup-v5',
                'dump_client_major': 17, 'archives': {
                    'product.dump': {'database': {'parameter_grants': []}},
                    'auth.dump': {'database': {'parameter_grants': []}},
                }}))
            self.assertEqual(module.load_manifest(path)['format'], 'pandapay-paired-postgresql-backup-v5')
            path.write_text(json.dumps({'format': 'pandapay-paired-postgresql-backup-v4',
                                        'dump_client_major': 17}))
            with self.assertRaisesRegex(ValueError, 'fresh.*v5'):
                module.load_manifest(path)

    def test_parameter_grants_are_canonical_and_paired_global_policy_must_match(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        rows = [
            ['work_mem', 'security_test', 'app_user', 'SET', False],
            ['log_min_messages', 'security_test', 'app_user', 'SET', False],
            ['work_mem', 'security_test', 'app_user', 'SET', False],
        ]
        self.assertEqual(module.canonical_parameter_grants(rows), [
            ['log_min_messages', [['security_test', 'app_user', 'SET', False]]],
            ['work_mem', [['security_test', 'app_user', 'SET', False]]],
        ])
        with self.assertRaisesRegex(ValueError, 'unsupported parameter ACL privilege'):
            module.canonical_parameter_grants([['log_min_messages', 'security_test', 'app_user', 'SET; SELECT 1', False]])
        with self.assertRaisesRegex(ValueError, 'unsupported parameter ACL identifier'):
            module.canonical_parameter_grants([['log_min_messages; SELECT 1', 'security_test', 'app_user', 'SET', False]])

        manifest = {'archives': {
            'product.dump': {'database': {'parameter_grants': [['log_min_messages', [['security_test', 'app_user', 'SET', False]]]]}},
            'auth.dump': {'database': {'parameter_grants': []}},
        }}
        with self.assertRaisesRegex(ValueError, 'different cluster-wide parameter ACL policies'):
            module.validate_parameter_policy_coherence(manifest)

    def test_parameter_acl_replay_requires_attestation_and_exact_fresh_database_set(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = {'archives': {
            'product.dump': {'database': {'parameter_grants': []}},
            'auth.dump': {'database': {'parameter_grants': []}},
        }}
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': ''}), \
             patch.object(module, 'psql_rows') as rows:
            with self.assertRaisesRegex(ValueError, 'fresh isolated cluster attestation'):
                module.validate_parameter_acl_target(manifest, 'synthetic-admin')
            rows.assert_not_called()
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': module.PARAMETER_ACL_ATTESTATION}), \
             patch.object(module, 'psql_rows', side_effect=[
                 [('postgres',)], [('0',)], [('0',)], [('postgres',), ('template0',), ('template1',)]]):
            module.validate_parameter_acl_target(manifest, 'postgresql://restore/recoverydb')
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': module.PARAMETER_ACL_ATTESTATION}), \
             patch.object(module, 'psql_rows', side_effect=[
                 [('postgres',)], [('0',)], [('0',)], [('postgres',), ('template0',), ('template1',), ('unexpected',)]]):
            with self.assertRaisesRegex(ValueError, 'outside the fresh isolated restore set'):
                module.validate_parameter_acl_target(manifest, 'postgresql://restore/recoverydb')
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': module.PARAMETER_ACL_ATTESTATION}), \
             patch.object(module, 'psql_rows', side_effect=[[('postgres',)], [('1',)]]) as query:
            with self.assertRaisesRegex(ValueError, 'contains user relations'):
                module.validate_parameter_acl_target(manifest, 'postgresql://restore/recoverydb')
            self.assertEqual(query.call_count, 2)
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': module.PARAMETER_ACL_ATTESTATION}), \
             patch.object(module, 'psql_rows', return_value=[('not-postgres',)]) as query:
            with self.assertRaisesRegex(ValueError, 'must use the postgres database'):
                module.validate_parameter_acl_target(manifest, 'postgresql://restore/recoverydb')
            self.assertEqual(query.call_count, 1)
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': module.PARAMETER_ACL_ATTESTATION}), \
             patch.object(module, 'psql_rows', side_effect=[[('postgres',)], [('0',)], [('1',)]]) as query:
            with self.assertRaisesRegex(ValueError, 'template1 contains user relations'):
                module.validate_parameter_acl_target(manifest, 'postgresql://restore/recoverydb')
            self.assertEqual(query.call_count, 3)
        expected_databases = [('postgres',), ('template0',), ('template1',), ('restore_product',), ('restore_auth',)]
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': module.PARAMETER_ACL_ATTESTATION}), \
             patch.object(module, 'psql_rows', side_effect=[ [('postgres',)], [('0',)], [('0',)], expected_databases]):
            module.validate_parameter_acl_target(
                manifest, 'postgresql://restore/postgres', {'restore_product', 'restore_auth'})
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': module.PARAMETER_ACL_ATTESTATION}), \
             patch.object(module, 'psql_rows', side_effect=[ [('postgres',)], [('0',)], [('0',)], expected_databases + [('unrelated',)]]):
            with self.assertRaisesRegex(ValueError, 'outside the fresh isolated restore set'):
                module.validate_parameter_acl_target(
                    manifest, 'postgresql://restore/postgres', {'restore_product', 'restore_auth'})

    def test_parameter_acl_replay_revokes_target_extra_then_restores_source_grantor_option(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source_grants = [['log_min_messages', [['security_test', 'app_user', 'SET', True]]]]
        manifest = {'archives': {
            'product.dump': {'database': {
                'parameter_grants': source_grants,
                'role_attributes': [['security_test', True], ['app_user', False]],
            }},
            'auth.dump': {'database': {
                'parameter_grants': source_grants,
                'role_attributes': [['security_test', True], ['app_user', False]],
            }},
        }}
        databases = [('postgres',), ('template0',), ('template1',), ('restore_product',), ('restore_auth',)]
        with patch.dict(os.environ, {'RESTORE_PARAMETER_ACL_ATTESTATION': module.PARAMETER_ACL_ATTESTATION}), \
             patch.object(module, 'psql_rows', side_effect=[[('postgres',)], [('0',)], [('0',)], databases,
                                                          [('security_test',)]]), \
             patch.object(module, 'parameter_grant_catalog', return_value=[
                 ['log_min_messages', [['security_test', 'recovery_extra', 'SET', False]]]]), \
             patch.object(module, 'run_psql') as execute:
            module.restore_parameter_acls(manifest, 'postgresql://admin/postgres',
                                          'postgresql://admin/restore_product',
                                          'postgresql://admin/restore_auth')
        statements = execute.call_args.args[1]
        self.assertEqual(statements[0], 'BEGIN')
        self.assertIn('SET SESSION AUTHORIZATION "security_test"', statements)
        self.assertIn('REVOKE SET ON PARAMETER "log_min_messages" FROM "recovery_extra" CASCADE', statements)
        self.assertIn('GRANT SET ON PARAMETER "log_min_messages" TO "app_user" WITH GRANT OPTION', statements)
        self.assertEqual(statements[-1], 'COMMIT')
        self.assertLess(statements.index('REVOKE SET ON PARAMETER "log_min_messages" FROM "recovery_extra" CASCADE'),
                        statements.index('GRANT SET ON PARAMETER "log_min_messages" TO "app_user" WITH GRANT OPTION'))

    def test_schema_acl_replay_preserves_grantor_and_grant_option(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = {'archives': {'product.dump': {'database': {
            'schema_owners': [['graphql', 'provider_owner']],
            'schema_grants': [['graphql', [['provider_owner', 'postgres', 'USAGE', True],
                                           ['provider_owner', 'anon', 'USAGE', False]]]],
        }}}}
        with patch.object(module, 'psql_rows', return_value=[('graphql', 'unexpected_role')]), \
             patch.object(module, 'run_psql') as run:
            module.restore_schema_acls(manifest, 'product.dump', 'target')
        statements = run.call_args.args[1]
        self.assertEqual(statements[0], 'BEGIN')
        self.assertEqual(statements[-1], 'COMMIT')
        self.assertIn('REVOKE ALL PRIVILEGES ON SCHEMA "graphql" FROM "unexpected_role" CASCADE', statements)
        self.assertIn('SET SESSION AUTHORIZATION "provider_owner"', statements)
        self.assertIn('GRANT USAGE ON SCHEMA "graphql" TO "postgres" WITH GRANT OPTION', statements)
        self.assertIn('GRANT USAGE ON SCHEMA "graphql" TO "anon"', statements)

    def test_schema_acl_replay_rejects_unknown_privilege_before_mutation(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = {'archives': {'product.dump': {'database': {
            'schema_owners': [['public', 'owner']],
            'schema_grants': [['public', [['owner', 'PUBLIC', 'USAGE; SELECT 1', False]]]],
        }}}}
        with patch.object(module, 'psql_rows', return_value=[]), patch.object(module, 'run_psql') as run:
            with self.assertRaisesRegex(ValueError, 'unsupported schema privilege'):
                module.restore_schema_acls(manifest, 'product.dump', 'target')
            run.assert_not_called()

    def test_backup_runtime_limit_rejects_unbounded_or_invalid_values(self):
        spec = importlib.util.spec_from_file_location('backup_snapshot', ROOT / 'db/scripts/backup_snapshot.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for value in ('0', '59', '7201', 'unlimited', '-1'):
            with patch.object(module.subprocess, 'Popen') as start:
                with self.assertRaisesRegex(ValueError, 'runtime limit'):
                    module.run_payload(['true'], {'BACKUP_MAX_RUNTIME_SECONDS': value})
                start.assert_not_called()

    def test_backup_timeout_stops_its_streaming_process_group(self):
        spec = importlib.util.spec_from_file_location('backup_snapshot', ROOT / 'db/scripts/backup_snapshot.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        from unittest.mock import Mock
        process = Mock(pid=12345)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired('synthetic', 60), 0]
        with patch.object(module.subprocess, 'Popen', return_value=process) as start, \
             patch.object(module.os, 'killpg') as terminate:
            with self.assertRaises(subprocess.TimeoutExpired):
                module.run_payload(['synthetic'], {'BACKUP_MAX_RUNTIME_SECONDS': '60'})
            self.assertTrue(start.call_args.kwargs['start_new_session'])
            terminate.assert_called_once_with(12345, module.signal.SIGTERM)

    def test_snapshot_catalog_deparse_uses_the_same_fixed_search_path(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.dict(os.environ, {'PRODUCT_DATABASE_URL': 'source', 'BACKUP_PRODUCT_SNAPSHOT': '0001-0002-1'}):
            self.assertIn('SET LOCAL search_path TO pg_catalog;', module.snapshot_sql('source', 'SELECT 1'))
        self.assertTrue(module.snapshot_sql('target', 'SELECT 1').startswith('SET search_path TO pg_catalog;'))

    def test_extension_owner_elevation_requires_disposable_cluster_attestation(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = {'archives': {'product.dump': {'database': {
            'extension_owners': [['hstore', 'limited_owner']],
            'role_attributes': [['limited_owner', False]],
            'extensions': [['hstore', '1.8', 'public']],
            'schema_owners': [['public', 'limited_owner']],
        }}}}
        with patch.dict(os.environ, {'RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION': ''}), \
             patch.object(module, 'psql_rows', return_value=[]), patch.object(module, 'run_psql') as run:
            with self.assertRaisesRegex(ValueError, 'isolated disposable'):
                module.prepare_target_extensions(manifest, 'product.dump', 'target')
            run.assert_not_called()

    def test_extension_bootstrap_restores_limited_owner_after_failure(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = {'archives': {'product.dump': {'database': {
            'extension_owners': [['hstore', 'limited_owner']],
            'role_attributes': [['limited_owner', False]],
            'extensions': [['hstore', '1.8', 'public']],
        }}}}
        with patch.dict(os.environ, {'RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION': 'THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER'}), \
             patch.object(module, 'psql_rows', return_value=[]), \
             patch.object(module, 'run_psql', side_effect=[RuntimeError('synthetic failure'), None]) as run:
            with self.assertRaisesRegex(RuntimeError, 'synthetic failure'):
                module.prepare_target_extensions(manifest, 'product.dump', 'target')
            self.assertEqual(run.call_args_list[-1].args[1], ['ALTER ROLE "limited_owner" NOSUPERUSER'])

    def test_equivalent_literal_casts_preserve_constraint_semantics(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = "CHECK (type::text = ANY (ARRAY['phone'::character varying, 'email'::character varying]::text[]))"
        restored = "CHECK (type::text = ANY (ARRAY['phone'::character varying::text, 'email'::character varying::text]))"
        self.assertEqual(module.normalize_constraint(original), module.normalize_constraint(restored))
        self.assertNotEqual(module.normalize_constraint(original), module.normalize_constraint(restored.replace('email', 'other')))

    def test_target_database_ddl_quotes_identifiers_and_restores_acl_and_settings(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = {"archives": {"product.dump": {"database": {
            "owner": 'app"owner', "connection_limit": 22,
            "encoding": "UTF8", "collation": "en_US.UTF-8", "ctype": "en_US.UTF-8",
            "database_settings": [[None, "application_name=restore's"]],
            "database_grants": [["PUBLIC", "CONNECT", False], ['app"owner', "CREATE", False], ["api_role", "TEMPORARY", True]],
        }}}}
        with patch.object(module, 'psql_rows', return_value=[]), patch.object(module, 'run_psql') as run:
            module.create_target_database(manifest, "product.dump", 'safe"; name', 'admin-url')
        create_statement = run.call_args_list[0].args[1][0]
        statements = run.call_args_list[1].args[1]
        self.assertEqual(create_statement, 'CREATE DATABASE "safe""; name" OWNER "app""owner" TEMPLATE template0 '
                         "ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8'")
        self.assertIn("ALTER DATABASE \"safe\"\"; name\" SET \"application_name\" TO 'restore''s'", statements)
        self.assertIn('GRANT TEMPORARY ON DATABASE "safe""; name" TO "api_role" WITH GRANT OPTION', statements)
        self.assertFalse(any('CREATE' in statement and ' TO "app' in statement for statement in statements))

    def test_target_role_gate_rejects_missing_source_owner_or_policy_role(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = {"archives": {
            "product.dump": {"database": {"required_roles": ["table_owner", "authenticated"], "required_role_attributes": [], "required_role_memberships": []}},
            "auth.dump": {"database": {"required_roles": [], "required_role_attributes": [], "required_role_memberships": []}},
        }}
        with patch.dict(os.environ, {"PRODUCT_TARGET": "target-product", "AUTH_TARGET": "target-auth"}), \
             patch.object(module, 'psql_rows', side_effect=[[], [], [], []]):
            with self.assertRaisesRegex(ValueError, "authenticated.*table_owner"):
                module.validate_target_roles(manifest, ("PRODUCT_TARGET", "AUTH_TARGET"))

    def test_target_role_gate_checks_inherit_and_set_membership_options(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source_membership = ["parent_role", "api_role", False, True, True]
        manifest = {"archives": {
            "product.dump": {"database": {
                "required_roles": ["api_role"],
                "required_role_attributes": [["api_role", False, True, False, False, True, False, False, -1]],
                "required_role_memberships": [source_membership],
            }},
            "auth.dump": {"database": {"required_roles": [], "required_role_attributes": [], "required_role_memberships": []}},
        }}
        product_attrs = [["api_role", "f", "t", "f", "f", "t", "f", "f", "-1"]]
        with patch.dict(os.environ, {"PRODUCT_TARGET": "target-product", "AUTH_TARGET": "target-auth"}), \
             patch.object(module, 'psql_rows', side_effect=[product_attrs,
                 [["parent_role", "api_role", "f", "t", "f"]], [], []]):
            with self.assertRaisesRegex(ValueError, "attributes or memberships differ"):
                module.validate_target_roles(manifest, ("PRODUCT_TARGET", "AUTH_TARGET"))

    def test_restore_target_must_support_the_dump_client_major(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.validate_restore_major(170006, 170006, 17)
        module.validate_restore_major(180001, 170006, 18)
        with self.assertRaisesRegex(ValueError, 'pg_dump client'):
            module.validate_restore_major(170006, 170006, 18)

    def test_failed_target_query_preserves_safe_diagnostic_before_closing_error_file(self):
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        def fail(_args, input, text, stdout, stderr):
            stderr.write(b'ERROR: 42501: private provider detail not for console')
            return SimpleNamespace(returncode=1)
        with patch.object(module.subprocess, 'run', side_effect=fail):
            with self.assertRaisesRegex(module.SafeDiagnosticError, 'sqlstate=42501') as error:
                module.run_psql('synthetic-url', ['SELECT 1'])
        self.assertNotIn('private provider detail', str(error.exception))

    def test_catalog_inventory_does_not_exclude_custom_pg_prefixed_schemas(self):
        source = (ROOT / 'db/scripts/backup_manifest.py').read_text()
        self.assertNotIn("NOT LIKE 'pg_%'", source)
        self.assertIn("n.nspname !~ '^pg_'", source)

    def test_hidden_cluster_identity_only_swallows_permission_denial(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.object(module, 'psql_rows', side_effect=module.SafeDiagnosticError('catalog_rows_query_failed sqlstate=42501 client_error=other_psql_error')):
            self.assertIsNone(module.cluster_system_identifier('synthetic-url'))
        with patch.object(module, 'psql_rows', side_effect=module.SafeDiagnosticError('catalog_rows_query_failed sqlstate=08006 client_error=connection_lost')):
            with self.assertRaisesRegex(module.SafeDiagnosticError, '08006'):
                module.cluster_system_identifier('synthetic-url')

    def test_client_error_categories_are_bounded(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.client_error_category('psql: error: connection to server was lost'), 'connection_lost')
        self.assertEqual(module.client_error_category('server says COPY command failed'), 'copy_protocol')
        self.assertEqual(module.client_error_category('synthetic secret text'), 'other_psql_error')

    def test_table_digest_retry_discards_partial_hash_before_same_query_retry(self):
        import hashlib
        import importlib.util
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        class Process:
            def __init__(self, payload, status, stderr):
                self.stdout = io.BytesIO(payload)
                self.status = status
                self.stderr = stderr
            def wait(self): return self.status

        canonical_rows = b'{"name":"one\\nname"}\n{"name":"two"}\n'
        responses = iter([(b'{"partial":true}\n', 1), (canonical_rows, 0)])
        def popen(_args, stdout, stderr, env):
            payload, status = next(responses)
            return Process(payload, status, stderr)
        with patch.object(module.subprocess, 'Popen', side_effect=popen) as called, \
             patch.object(module.time, 'sleep') as sleep:
            result = module.stream_table_digest('synthetic-url', 'COPY t TO STDOUT', 'public.t')
        self.assertEqual(result, (hashlib.sha256(canonical_rows).hexdigest(), 2))
        self.assertEqual(called.call_count, 2)
        sleep.assert_called_once_with(0.25)

    def test_table_digest_does_not_retry_sqlstate_failure(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('backup_manifest', ROOT / 'db/scripts/backup_manifest.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        class Process:
            stdout = io.BytesIO(b'')
            def __init__(self, stderr):
                self.stderr = stderr
                self.stderr.write(b'ERROR:  42501: permission denied')
            def wait(self): return 1

        with patch.object(module.subprocess, 'Popen', side_effect=lambda _args, stdout, stderr, env: Process(stderr)) as called, \
             patch.object(module.time, 'sleep') as sleep:
            with self.assertRaisesRegex(module.SafeDiagnosticError, 'attempts=1 sqlstate=42501'):
                module.stream_table_digest('synthetic-url', 'COPY t TO STDOUT', 'public.t')
        called.assert_called_once()
        sleep.assert_not_called()


class PairedBackupFlowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pandapay-backup-test-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.work = self.root / "local"
        self.dest_a = self.root / "offsite-a"
        self.dest_b = self.root / "offsite-b"
        self.backup_dir = self.root / "backup"
        self.status = self.root / "restore-status"
        self.created_databases = self.root / "created-databases.txt"
        self.created_databases.write_text("")
        for path in (self.work, self.dest_a, self.dest_b, self.backup_dir):
            path.mkdir()
        self.recipient = self.root / "recipients.txt"
        self.recipient.write_text("age1" + "q" * 58 + "\n")
        self.identity = self.root / "identity.txt"
        self.identity.write_text("AGE-SECRET-KEY-TEST\n")
        self.roles = self.root / "roles.sql"
        self.roles.write_text("-- reviewed synthetic app-role bootstrap\n")
        self._write_tool("pg_dump", r'''#!/usr/bin/env python3
import os, pathlib, sys
if '--version' in sys.argv:
    print('pg_dump (PostgreSQL) 17.11')
    raise SystemExit(0)
if os.environ.get('MOCK_FAIL_AUTH') == '1' and any('/auth' in arg for arg in sys.argv):
    raise SystemExit(3)
sys.stdout.buffer.write(b'synthetic-dump' * int(os.environ.get('MOCK_DUMP_REPEAT', '1')))
''')
        self._write_tool("pg_restore", r'''#!/usr/bin/env python3
import os, pathlib, sys
if '--list' in sys.argv:
    data = sys.stdin.buffer.read(16) if os.environ.get('MOCK_LIST_EARLY') == '1' else sys.stdin.buffer.read()
    if not data: raise SystemExit(2)
else:
    data = sys.stdin.buffer.read()
    if not data: raise SystemExit(2)
''')
        fixture = {
            "database": "fixture",
            "server_version": "17.6",
            "server_version_num": 170006,
            "encoding": "UTF8",
            "collation": "C.UTF-8",
            "ctype": "C.UTF-8",
            "owner": "postgres", "connection_limit": -1,
            "database_settings": [], "database_grants": [],
            "parameter_grants": [],
            "extensions": [], "schema_owners": [], "schemas": [], "relations": [], "sequences": [],
            "policies": [], "functions": [], "table_grants": [],
            "column_grants": [], "routine_grants": [], "schema_grants": [],
            "default_acl": [], "role_attributes": [], "role_memberships": [],
            "migration_ledgers": {}, "required_roles": [], "required_role_attributes": [],
            "required_role_memberships": [], "cluster_system_identifier": None,
        }
        self.fixture_file = self.root / "fixture.json"
        self.fixture_file.write_text(json.dumps(fixture))
        self._write_tool("psql", r'''#!/usr/bin/env python3
import json, os, pathlib, re, sys
args = sys.argv[1:]
state = pathlib.Path(os.environ['MOCK_PSQL_CREATED_DATABASES'])
if '-c' not in args and '-f' not in args:
    lines = []
    for line in sys.stdin:
        lines.append(line)
        if 'pg_export_snapshot()' in line: print('00000001-00000002-1', flush=True)
        if '\\q' in line: break
    script = ''.join(lines)
    names = set(state.read_text().splitlines())
    names.update(re.findall(r'CREATE DATABASE \"([^\"]+)\"', script))
    state.write_text(chr(10).join(sorted(names)) + (chr(10) if names else ''))
if '-c' in args:
    sql = args[args.index('-c') + 1]
    if "'database', current_database()" in sql:
        print(pathlib.Path(os.environ['MOCK_PSQL_FIXTURE']).read_text())
    elif 'json_agg(json_build_array(p.parname' in sql:
        print('[]')
    elif 'SELECT current_database()' in sql:
        print('postgres')
    elif 'SELECT count(*)::text' in sql:
        print('0')
    elif 'SELECT datname FROM pg_database ORDER BY datname' in sql:
        names = ['postgres', 'template0', 'template1'] + state.read_text().splitlines()
        print(chr(10).join(sorted(set(names))))
    elif sql.startswith('DROP DATABASE'):
        match = re.search(r'DROP DATABASE(?: IF EXISTS)? \"([^\"]+)\"', sql)
        if match:
            names = [name for name in state.read_text().splitlines() if name != match.group(1)]
            state.write_text(chr(10).join(names) + (chr(10) if names else ''))
    elif 'to_regclass(' in sql:
        print('f')
    elif 'SELECT n.nspname,c.relname,c.relkind' in sql or 'SELECT sequence_schema,sequence_name' in sql:
        pass
''')
        self._write_tool("age", r'''#!/usr/bin/env python3
import os, shutil, sys
args = sys.argv[1:]
if '-o' not in args:
    if '-R' in args and len(args) > args.index('-R') + 2:
        sys.stdout.buffer.write(open(args[-1], 'rb').read())
    elif '-d' in args:
        sys.stdout.buffer.write(open(args[-1], 'rb').read())
    else:
        sys.stdout.buffer.write(sys.stdin.buffer.read())
    raise SystemExit(0)
out = args[args.index('-o') + 1]
src = args[-1]
if os.environ.get('MOCK_AGE_DECRYPT_LOG'):
    with open(os.environ['MOCK_AGE_DECRYPT_LOG'], 'a') as log: log.write(src + '\n')

if src.startswith('-') or src == out:
    import pathlib
    pathlib.Path(out).write_bytes(sys.stdin.buffer.read())
else: shutil.copyfile(src, out)
''')

    def tearDown(self):
        self.tmp.cleanup()

    def _write_tool(self, name, source):
        tool = self.bin / name
        tool.write_text(source)
        tool.chmod(0o755)

    def env(self):
        values = os.environ.copy()
        values.update({
            "PATH": f"{self.bin}:{values['PATH']}",
            "PRODUCT_DATABASE_URL": "postgresql://backup:synthetic@source.invalid:5432/product",
            "AUTH_DATABASE_URL": "postgresql://backup:synthetic@source.invalid:5432/auth",
            "BACKUP_DIR": str(self.backup_dir),
            "BACKUP_AGE_RECIPIENTS_FILE": str(self.recipient),
            "BACKUP_DESTINATION_A": str(self.dest_a),
            "BACKUP_DESTINATION_B": str(self.dest_b),
            "RESTORE_ADMIN_DATABASE_URL": "postgresql://restore:synthetic@recovery.invalid:5432/postgres",
            "RESTORE_PRODUCT_DATABASE_URL": "postgresql://restore:synthetic@recovery.invalid:5432/template_product",
            "RESTORE_AUTH_DATABASE_URL": "postgresql://restore:synthetic@recovery.invalid:5432/template_auth",
            "RESTORE_AGE_IDENTITY_FILE": str(self.identity),
            "RESTORE_ROLE_BOOTSTRAP_FILE": str(self.roles),
            "RESTORE_STATUS_DIR": str(self.status),
            "RESTORE_INDEPENDENCE_ATTESTATION": "I_HAVE_VERIFIED_A_DIFFERENT_POSTGRES_CLUSTER",
            "RESTORE_PARAMETER_ACL_ATTESTATION": "I_HAVE_VERIFIED_FRESH_ISOLATED_RECOVERY_CLUSTER",
            "MOCK_PSQL_FIXTURE": str(self.fixture_file),
            "MOCK_PSQL_CREATED_DATABASES": str(self.created_databases),
            "BACKUP_MAX_USAGE_PERCENT": "99",
        })
        return values

    def run_script(self, script, env, success=True):
        result = subprocess.run(["bash", str(script)], cwd=ROOT, env=env,
                                capture_output=True, text=True)
        if success and result.returncode != 0:
            self.fail(f"{script.name} failed ({result.returncode}): {result.stderr}\n{result.stdout}")
        if not success and result.returncode == 0:
            self.fail(f"{script.name} unexpectedly succeeded")
        return result

    def make_backup(self):
        self.run_script(BACKUP, self.env())
        complete = list(self.backup_dir.glob("*/OFFSITE_COMPLETE"))
        self.assertEqual(len(complete), 1)
        return complete[0].parent

    def test_publishes_one_encrypted_complete_pair_to_both_destinations(self):
        self.make_backup()
        local = next(path for path in self.backup_dir.iterdir() if path.is_dir())
        off_a = next(path for path in self.dest_a.iterdir() if path.is_dir())
        off_b = next(path for path in self.dest_b.iterdir() if path.is_dir())
        self.assertEqual(local.name, off_a.name)
        self.assertEqual(local.name, off_b.name)
        for directory in (local, off_a, off_b):
            self.assertTrue((directory / "OFFSITE_COMPLETE").is_file())
            self.assertTrue((directory / "product.dump.age").is_file())
            self.assertFalse((directory / "product.dump").exists())
            self.assertFalse((directory / "manifest.json").exists())

    def test_local_pc_mode_needs_no_remote_paths_and_is_recoverable(self):
        env = self.env()
        env['BACKUP_MODE'] = 'local'
        env.pop('BACKUP_DESTINATION_A')
        env.pop('BACKUP_DESTINATION_B')
        result = self.run_script(BACKUP, env)
        self.assertIn('status=local_saved copies=1', result.stdout)
        self.assertNotIn('offsite_uploaded', result.stdout)
        sets = list(self.backup_dir.glob('*/LOCAL_COMPLETE'))
        self.assertEqual(len(sets), 1)
        self.assertFalse(list(self.backup_dir.glob('*/OFFSITE_COMPLETE')))
        env['BACKUP_SET_DIR'] = str(sets[0].parent)
        self.run_script(RESTORE, env)
        self.assertTrue((sets[0].parent / 'RESTORE_VERIFIED').is_file())

    def test_auth_dump_failure_never_marks_any_destination_complete(self):
        env = self.env()
        env["MOCK_FAIL_AUTH"] = "1"
        self.run_script(BACKUP, env, success=False)
        self.assertEqual(list(self.backup_dir.glob("*/OFFSITE_COMPLETE")), [])
        self.assertEqual(list(self.dest_a.glob("*/OFFSITE_COMPLETE")), [])
        self.assertEqual(list(self.dest_b.glob("*/OFFSITE_COMPLETE")), [])

    def test_restore_uses_separate_recovery_host_and_marks_restore_status(self):
        set_dir = self.make_backup()
        env = self.env()
        env["BACKUP_SET_DIR"] = str(set_dir)
        decrypt_log = self.root / 'age-decrypt.log'
        env['MOCK_AGE_DECRYPT_LOG'] = str(decrypt_log)
        result = self.run_script(RESTORE, env)
        self.assertIn("status=database_restore_verified", result.stdout)
        self.assertTrue((self.status / f"RESTORE_VERIFIED-{set_dir.name}").is_file())
        self.assertEqual(list(self.status.glob("RESTORE_VERIFIED-*"))[0].read_text().splitlines()[1],
                         "status=database_restore_verified")
        self.assertEqual(decrypt_log.read_text().splitlines(), [str(set_dir / 'manifest.json.age')])

    def test_large_stream_is_drained_after_archive_listing_exits_early(self):
        env = self.env()
        env['MOCK_DUMP_REPEAT'] = '100000'
        self.run_script(BACKUP, env)
        marker = next(self.backup_dir.glob('*/OFFSITE_COMPLETE'))
        env['BACKUP_SET_DIR'] = str(marker.parent)
        env['MOCK_LIST_EARLY'] = '1'
        self.run_script(RESTORE, env)
        self.assertTrue((marker.parent / 'RESTORE_VERIFIED').is_file())

    def test_restore_automatically_selects_newest_complete_pair(self):
        self.make_backup()
        env = self.env()
        env['BACKUP_DIR'] = str(self.dest_a)
        self.run_script(RESTORE, env)
        self.assertEqual(len(list(self.status.glob('RESTORE_VERIFIED-*'))), 1)

    def test_storage_cap_failure_preserves_previous_complete_pair_and_cleans_pending(self):
        previous = self.make_backup()
        env = self.env()
        env['BACKUP_MAX_BYTES'] = '1'
        self.run_script(BACKUP, env, success=False)
        self.assertTrue((previous / 'OFFSITE_COMPLETE').is_file())
        self.assertFalse(list(self.backup_dir.glob('.pending-*')))

    def test_streaming_quota_failure_keeps_old_pair_and_removes_partial_ciphertext(self):
        previous = self.make_backup()
        env = self.env()
        env.update(BACKUP_MAX_BYTES='65536', MOCK_DUMP_REPEAT='100000')
        self.run_script(BACKUP, env, success=False)
        self.assertTrue((previous / 'OFFSITE_COMPLETE').is_file())
        self.assertFalse(list(self.backup_dir.glob('.pending-*')))
        self.assertEqual(len(list(self.backup_dir.glob('*/OFFSITE_COMPLETE'))), 1)

    def test_backup_tls_rejects_url_downgrade_and_client_cert_options(self):
        for query in ('sslmode=disable', 'sslcert=some-file', 'sslmode=require&sslmode=prefer'):
            env = self.env()
            env['SOURCE_URL'] = 'postgresql://backup:synthetic@source.invalid/product?' + query
            result = subprocess.run(['python3', str(ROOT / 'db/scripts/pg_connection.py'),
                '--output', str(self.root / 'urls.json'), '--pgpass', str(self.root / 'pgpass'),
                '--url-env', 'SOURCE_URL'], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('synthetic', result.stderr)

    def test_private_identity_is_rejected_on_backup_host(self):
        self.recipient.write_text("AGE-SECRET-KEY-DO-NOT-USE\n")
        self.run_script(BACKUP, self.env(), success=False)
        self.assertEqual(list(self.dest_a.iterdir()), [])

    def test_libpq_urls_force_verified_tls_and_keep_password_out_of_process_url(self):
        output = self.root / "urls.json"
        pgpass = self.root / "pgpass"
        env = self.env()
        env["NODE_ENV"] = "production"
        env["DB_SSL"] = "true"
        env["DB_SSL_CA"] = ssl.DER_cert_to_PEM_cert(ssl.create_default_context().get_ca_certs(binary_form=True)[0]).replace("\n", r"\n")
        env["SOURCE_URL"] = "postgresql://backup:secret-value@source.invalid:5432/product?sslmode=prefer"
        helper = ROOT / "db/scripts/pg_connection.py"
        result = subprocess.run(["python3", str(helper), "--output", str(output), "--pgpass", str(pgpass),
                                 "--url-env", "SOURCE_URL"], cwd=ROOT, env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        url = json.loads(output.read_text())["SOURCE_URL"]
        self.assertNotIn("secret-value", url)
        self.assertIn("sslmode=verify-full", url)
        self.assertIn("sslrootcert=", url)
        self.assertIn("secret-value", pgpass.read_text())
        self.assertEqual(pgpass.stat().st_mode & 0o777, 0o600)

    def test_production_rejects_unencrypted_database_transport(self):
        output = self.root / "urls.json"
        pgpass = self.root / "pgpass"
        env = self.env()
        env["NODE_ENV"] = "production"
        env["DB_SSL"] = "false"
        helper = ROOT / "db/scripts/pg_connection.py"
        result = subprocess.run(["python3", str(helper), "--output", str(output), "--pgpass", str(pgpass),
                                 "--url-env", "PRODUCT_DATABASE_URL"], cwd=ROOT, env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("synthetic", result.stderr)


if __name__ == "__main__":
    unittest.main()
