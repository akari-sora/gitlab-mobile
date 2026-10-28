from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
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

    def test_public_api_smoke_runs_only_on_demand_or_on_its_schedule(self):
        match = re.search(r'^public_api_smoke:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'public_api_smoke job must be present in .gitlab-ci.yml')
        rules = re.search(r'^  rules:\n(.*?)(?=\n  \S)', match.group(1), re.MULTILINE | re.DOTALL).group(1)
        self.assertIn('\'$PUBLIC_SMOKE == "1" && $CI_PIPELINE_SOURCE =~ /^(api|schedule|web)$/\'', rules)
        self.assertNotIn('on_success', rules,
                         'anonymous gitlab.com reads share a per-IP budget and must not run on every push')

    def test_android_build_does_not_wait_for_the_public_smoke(self):
        match = re.search(r'^android_debug:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'android_debug job must be present in .gitlab-ci.yml')
        needs = re.search(r'^  needs:\n(.*?)(?=\n  \S)', match.group(1), re.MULTILINE | re.DOTALL).group(1)
        self.assertNotIn('public_api_smoke', needs)
        for job in ('python_checks', 'flutter_checks', 'flutter_ai_checks', 'native_templates'):
            self.assertIn(f'- job: {job}', needs)

    def test_live_crud_smoke_disables_retry_for_mutation_safety(self):
        # Extract live_crud_smoke job block
        match = re.search(r'^live_crud_smoke:\n(.*?)(?=\n\S|\Z)', self.content, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'live_crud_smoke job must be present in .gitlab-ci.yml')
        job_block = match.group(1)
        self.assertIn('retry: 0', job_block,
                      'live_crud_smoke mutates live data and must keep retry: 0')

    def test_ai_checks_have_the_same_regular_lane_and_separate_artifacts(self):
        jobs = {}
        for name in ('flutter_checks', 'flutter_ai_checks'):
            match = re.search(rf'^{name}:\n(.*?)(?=\n\S|\Z)', self.content,
                              re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(match, name)
            jobs[name] = match.group(1)
            self.assertIn('extends: [.flutter, .regular]', jobs[name])
            self.assertIn('timeout: 25m', jobs[name])
            self.assertNotRegex(jobs[name], re.compile(r'^  (rules|tags|retry):', re.MULTILINE))
        self.assertIn('- bash ci/check.sh\n', jobs['flutter_checks'])
        self.assertIn('junit: ci-output/junit.xml', jobs['flutter_checks'])
        self.assertIn('- bash ci/check.sh ai\n', jobs['flutter_ai_checks'])
        self.assertIn('paths: [ci-output-ai/, coverage-ai/]', jobs['flutter_ai_checks'])
        self.assertIn('junit: ci-output-ai/junit.xml', jobs['flutter_ai_checks'])

    def test_attestation_and_ai_delivery_are_guarded_manual_jobs(self):
        for name in ('mr7_release_attestation', 'publish_preview_ai'):
            with self.subTest(job=name):
                match = re.search(rf'^{name}:\n(.*?)(?=\n\S|\Z)', self.content,
                                  re.MULTILINE | re.DOTALL)
                self.assertIsNotNone(match, name)
                job = match.group(1)
                rules_match = re.search(r'^  rules:\n(.*?)(?=\n  \S|\Z)', job,
                                        re.MULTILINE | re.DOTALL)
                self.assertIsNotNone(rules_match, name)
                self.assertNotRegex(rules_match.group(1),
                                    re.compile(r'^    - when: (?!never\b)', re.MULTILINE))
                rules = re.findall(r'^    - if: ([^\n]+)\n((?:      [^\n]+\n)*)',
                                   rules_match.group(1) + '\n', re.MULTILINE)
                self.assertTrue(rules, name)
                for special in ('$LIVE_SMOKE', '$RESOLVE_LOCK', '$PUBLIC_SMOKE', '$GH2GL_SYNC'):
                    self.assertIn(special, rules[0][0])
                self.assertRegex(rules[0][1], r'(?m)^      when: never$')
                allows = [(condition, attributes) for condition, attributes in rules
                          if not re.search(r'^      when: never$', attributes, re.MULTILINE)]
                self.assertEqual(len(allows), 1, name)
                condition, attributes = allows[0]
                self.assertNotIn('||', condition)
                for required in (
                    r'\$CI_PROJECT_ID\s*==\s*"86648389"',
                    r'\$CI_COMMIT_REF_PROTECTED\s*==\s*"true"',
                    r'\$CI_COMMIT_BRANCH\s*==\s*"main"',
                    r'\$CI_PIPELINE_SOURCE\s*!=\s*"merge_request_event"',
                ):
                    self.assertRegex(condition, required)
                self.assertRegex(attributes, r'(?m)^      when: manual$')
                self.assertRegex(attributes, r'(?m)^      allow_failure: true$')
                self.assertIn('retry: 0', job)
                self.assertIn('name: mr7-release', job)

    def test_off_preview_is_restricted_to_this_projects_protected_main(self):
        self.assertRegex(self.content, re.compile(r"^  MR7_RELEASE_AI: ['\"]false['\"]$", re.MULTILINE))
        match = re.search(r'^publish_preview:\n(.*?)(?=\n\S|\Z)', self.content,
                          re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match)
        job = match.group(1)
        rules_match = re.search(r'^  rules:\n(.*?)(?=\n  \S|\Z)', job,
                                re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(rules_match)
        self.assertNotRegex(rules_match.group(1),
                            re.compile(r'^    - when: (?!never\b)', re.MULTILINE))
        rules = re.findall(r'^    - if: ([^\n]+)\n((?:      [^\n]+\n)*)',
                           rules_match.group(1) + '\n', re.MULTILINE)
        self.assertEqual(len(rules), 2)
        for special in ('$LIVE_SMOKE', '$RESOLVE_LOCK', '$PUBLIC_SMOKE', '$GH2GL_SYNC'):
            self.assertIn(special, rules[0][0])
        self.assertRegex(rules[0][1], r'(?m)^      when: never$')
        condition = rules[1][0]
        self.assertNotIn('||', condition)
        for required in (
            r'\$CI_PROJECT_ID\s*==\s*"86648389"',
            r'\$CI_COMMIT_REF_PROTECTED\s*==\s*"true"',
            r'\$CI_COMMIT_BRANCH\s*==\s*"main"',
            r'\$CI_PIPELINE_SOURCE\s*!=\s*"merge_request_event"',
            r'\$MR7_RELEASE_AI\s*!=\s*"true"',
        ):
            self.assertRegex(condition, required)
        self.assertIn('bash ci/deliver_preview.sh', job)


class CheckScriptTests(unittest.TestCase):
    """Run the real shell script with synthetic Flutter events and no SDK."""

    def run_check(self, *args, test_exit='0'):
        root = Path(__file__).resolve().parents[2]
        scratch = root / 'ci-output'
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='check-script-', dir=scratch) as directory:
            work = Path(directory)
            (work / 'ci').mkdir()
            (work / 'bin').mkdir()
            for name in ('check.sh', 'test_progress.py', 'test_report.py'):
                shutil.copyfile(root / 'ci' / name, work / 'ci' / name)
            (work / 'pubspec.lock').write_text('synthetic lock\n')
            flutter = work / 'bin' / 'flutter'
            flutter.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import json, os, pathlib, sys
                with open(os.environ['COMMANDS'], 'a') as output:
                    output.write(json.dumps(sys.argv[1:]) + '\\n')
                if sys.argv[1] == 'test':
                    for event in ({'type':'testStart','test':{'id':1,'name':'synthetic'}},
                                  {'type':'testDone','testID':1,'result':'success'},
                                  {'type':'done','success':True}):
                        print(json.dumps(event))
                    path = next((arg.split('=', 1)[1] for arg in sys.argv
                                 if arg.startswith('--coverage-path=')), 'coverage/lcov.info')
                    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
                    pathlib.Path(path).write_text('LF:2\\nLH:1\\n')
                    sys.exit(int(os.environ['TEST_EXIT']))
                '''))
            timeout = work / 'bin' / 'timeout'
            timeout.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import json, os, subprocess, sys
                with open(os.environ['TIMEOUT_ARGS'], 'w') as output:
                    json.dump(sys.argv[1:4], output)
                sys.exit(subprocess.call(sys.argv[4:]))
                '''))
            flutter.chmod(0o755)
            timeout.chmod(0o755)
            env = dict(os.environ, PATH=f"{work / 'bin'}:{os.environ['PATH']}",
                       COMMANDS=str(work / 'commands.jsonl'),
                       TIMEOUT_ARGS=str(work / 'timeout.json'), TEST_EXIT=test_exit)
            env.pop('CI', None)
            result = subprocess.run(['bash', 'ci/check.sh', *args], cwd=work, env=env,
                                    capture_output=True, text=True, timeout=20)
            commands = [json.loads(line) for line in (work / 'commands.jsonl').read_text().splitlines()] \
                if (work / 'commands.jsonl').exists() else []
            timeout_args = json.loads((work / 'timeout.json').read_text()) \
                if (work / 'timeout.json').exists() else []
            files = {str(path.relative_to(work)) for path in work.rglob('*') if path.is_file()}
            return result, commands, timeout_args, files

    def test_default_and_ai_modes_run_the_full_suite_with_correct_defines(self):
        for mode in ('default', 'ai'):
            with self.subTest(mode=mode):
                result, commands, timeout_args, files = self.run_check(*(() if mode == 'default' else (mode,)))
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertEqual(timeout_args, ['--signal=TERM', '--kill-after=15s', '22m'])
                self.assertEqual(commands[:2], [['pub', 'get', '--enforce-lockfile'], ['analyze', '--no-pub']])
                test_args = commands[2]
                self.assertEqual(test_args[:5], ['test', '--no-pub', '--coverage', '--timeout=60s', '--machine'])
                defines = [arg for arg in test_args if arg.startswith('--dart-define=')]
                output = 'ci-output' if mode == 'default' else 'ci-output-ai'
                coverage = 'coverage' if mode == 'default' else 'coverage-ai'
                self.assertIn(f'{output}/junit.xml', files)
                self.assertIn(f'{coverage}/lcov.info', files)
                if mode == 'default':
                    self.assertEqual(defines, [])
                else:
                    self.assertEqual(defines, ['--dart-define=MERGELINE_AI_ASSISTANT=true',
                                               '--dart-define=MERGELINE_AI_BACKGROUND=false'])

    def test_failed_flutter_test_remains_a_failure(self):
        result, _, _, files = self.run_check('ai', test_exit='7')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('test_exit=7', result.stdout)
        self.assertIn('ci-output-ai/junit.xml', files)

    def test_unknown_mode_is_rejected_before_invoking_flutter(self):
        result, commands, _, _ = self.run_check('unknown')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(commands, [])


if __name__ == '__main__':
    unittest.main()
