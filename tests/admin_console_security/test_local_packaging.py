import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('launcher', ROOT/'scripts/admin_console/launcher.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)

class LocalPackaging(unittest.TestCase):
    def test_forwarding_is_pinned_and_loopback(self):
        cfg = dict(known_hosts='/protected/known', ssh_identity='/protected/key', ssh_user='forward', ssh_host='backend')
        args = launcher.ssh_command(cfg)
        for value in ['127.0.0.1:7431:127.0.0.1:4321','StrictHostKeyChecking=yes','ForwardAgent=no','ExitOnForwardFailure=yes','IdentityAgent=none']:
            self.assertIn(value,args)
        self.assertNotIn('-R',args)
        self.assertIn('-N',args)
    def test_protected_file_rejects_world_readable_or_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'config';p.write_text('{}');p.chmod(0o644)
            with self.assertRaises(ValueError): launcher.protected(str(p))
            p.chmod(0o600);self.assertEqual(launcher.protected(str(p)),str(p))
            link=Path(directory)/'link';link.symlink_to(p)
            with self.assertRaises(ValueError): launcher.protected(str(link))
    def test_proxy_has_no_public_bind_or_arbitrary_upstream(self):
        config=(ROOT/'deploy/nginx/console.localhost.conf.example').read_text()
        self.assertIn('listen 127.0.0.1:8443 ssl',config)
        self.assertIn('proxy_pass http://127.0.0.1:7431',config)
        self.assertNotIn('proxy_pass $',config)
        self.assertIn('localhost:8443',config)

if __name__=='__main__': unittest.main()
