"""Checks that the AI User-Agent carries the app's own version."""
from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AiClientVersionTest(unittest.TestCase):
    def test_user_agent_version_matches_pubspec(self):
        pubspec = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
        version = re.search(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', pubspec, re.M)
        self.assertIsNotNone(version, 'pubspec.yaml has no version')
        source = (ROOT / 'lib/core/ai/ai_wire_client.dart').read_text(encoding='utf-8')
        constant = re.search(r"^const aiClientAppVersion = '([^']+)';", source, re.M)
        self.assertIsNotNone(constant, 'aiClientAppVersion is missing')
        self.assertEqual(constant.group(1), version.group(1))

    def test_no_other_hard_coded_ai_client_version(self):
        for path in (ROOT / 'lib').rglob('*.dart'):
            with self.subTest(path=path.name):
                self.assertNotRegex(path.read_text(encoding='utf-8'), r"appVersion:\s*'")


if __name__ == '__main__':
    unittest.main()
