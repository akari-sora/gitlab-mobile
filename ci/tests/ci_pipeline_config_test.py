from pathlib import Path
import re
import unittest


class CiPipelineConfigTests(unittest.TestCase):
    def setUp(self):
        self.ci_file = Path(__file__).resolve().parents[2] / '.gitlab-ci.yml'
        self.content = self.ci_file.read_text(encoding='utf-8')

    def test_default_retry_covers_infrastructure_failures(self):
        self.assertIn('retry:', self.content)
        self.assertIn('when: [runner_system_failure, stuck_or_timeout_failure]', self.content)

    def test_public_api_smoke_does_not_override_retry_with_zero(self):
        # Extract public_api_smoke job block
        match = re.search(r'^public_api_smoke:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'public_api_smoke job must be present in .gitlab-ci.yml')
        job_block = match.group(1)
        self.assertNotIn('retry: 0', job_block,
                         'public_api_smoke is read-only and must inherit default retry for queue resilience')

    def test_live_crud_smoke_disables_retry_for_mutation_safety(self):
        # Extract live_crud_smoke job block
        match = re.search(r'^live_crud_smoke:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'live_crud_smoke job must be present in .gitlab-ci.yml')
        job_block = match.group(1)
        self.assertIn('retry: 0', job_block,
                      'live_crud_smoke mutates live data and must keep retry: 0')


if __name__ == '__main__':
    unittest.main()
