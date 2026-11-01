import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).parents[1] / 'prepare_local_backup.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PrepareLocalBackupTest(unittest.TestCase):
    def test_preserves_existing_secrets_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            recipient = 'age1' + 'a' * 58
            public = root / 'keys' / 'public.txt'
            (root / '.env').write_text('JWT_ACCESS_SECRET=retain-this\nOTHER=keep\n')
            prepare.configure(root, public, recipient)
            first = (root / '.env').read_text()
            prepare.configure(root, public, recipient)
            self.assertEqual(first, (root / '.env').read_text())
            self.assertIn('JWT_ACCESS_SECRET=retain-this\nOTHER=keep\n', first)
            self.assertIn('BACKUP_MODE=local', first)
            self.assertEqual(public.read_text().strip(), recipient)

    def test_rejects_conflicting_mode_duplicate_key_and_recipient_without_modifying_env(self):
        for contents in ('BACKUP_MODE=offhost\n', 'BACKUP_MODE=\nBACKUP_MODE=\n', ''):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                env = root / '.env'
                env.write_text(contents)
                public = root / 'public.txt'
                if not contents:
                    public.write_text('age1' + 'b' * 58)
                with self.assertRaises(ValueError):
                    prepare.configure(root, public, 'age1' + 'a' * 58)
                self.assertEqual(env.read_text(), contents)

    def test_rejects_private_or_malformed_key(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / '.env').write_text('OTHER=keep\n')
            for recipient in ('AGE-SECRET-KEY-PRIVATE', 'age1bad', "age1'; dangerous"):
                with self.assertRaises(ValueError):
                    prepare.configure(root, root / 'public.txt', recipient)
            self.assertFalse((root / 'public.txt').exists())


if __name__ == '__main__':
    unittest.main()
