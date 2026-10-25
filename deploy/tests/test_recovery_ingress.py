"""Contract checks for TLS-only recovery upload location bounds."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def blocks(source, keyword):
    result = []
    for match in re.finditer(r'\b' + keyword + r'\b[^{}]*\{', source):
        depth, offset = 1, match.end()
        while depth and offset < len(source):
            depth += (source[offset] == '{') - (source[offset] == '}')
            offset += 1
        if depth:
            raise AssertionError('Unbalanced config block')
        result.append(source[match.start():offset])
    return result


class RecoveryIngressTest(unittest.TestCase):
    def test_binary_uploads_are_tls_only_and_allow_full_envelope(self):
        source = (ROOT / 'deploy/nginx/api.conf.example').read_text()
        servers = blocks(source, 'server')
        http = next(block for block in servers if 'listen 80;' in block)
        tls = next(block for block in servers if 'listen 443 ssl;' in block)
        self.assertNotIn('proxy_pass', http, 'plain HTTP must redirect rather than forward authenticated recovery')
        self.assertIn('return 301 https://$host$request_uri;', http)
        locations = blocks(tls, 'location')
        for endpoint in ['/account/recovery/snapshots', '/account/recovery/automatic/snapshots']:
            upload = next(block for block in locations if block.startswith('location = ' + endpoint + ' {'))
            maximum = int(re.search(r'client_max_body_size (\d+)m;', upload).group(1)) * 1024 * 1024
            self.assertGreaterEqual(maximum, 5 * 1024 * 1024 + 2048 + 4)
            self.assertIn('proxy_set_header X-Forwarded-For $remote_addr;', upload)
            self.assertIn('proxy_set_header X-Forwarded-Proto $scheme;', upload)
            self.assertIn('proxy_pass http://127.0.0.1:4000;', upload)


if __name__ == '__main__':
    unittest.main()
