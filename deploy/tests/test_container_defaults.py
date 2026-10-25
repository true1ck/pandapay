"""Keep the standalone auth image consistent with its advertised port."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ContainerDefaultsTest(unittest.TestCase):
    def test_auth_default_port_matches_expose_and_healthcheck(self):
        source = (ROOT / 'auth/Dockerfile').read_text()
        port = re.search(r'^ENV PORT=(\d+)$', source, re.MULTILINE)
        self.assertIsNotNone(port, 'The image needs an explicit default PORT')
        self.assertRegex(source, rf'(?m)^EXPOSE {port.group(1)}$')
        self.assertIn(f'process.env.PORT||{port.group(1)}', source)


if __name__ == '__main__':
    unittest.main()
