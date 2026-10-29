"""Synthetic attestation and delivery gate tests: no GitLab network or real tokens."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mr7_attestation', ROOT / 'ci/mr7_attestation.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
SHA = 'a' * 40
NOW = datetime.now(timezone.utc)
SOURCE = {'tree': 'b' * 40, 'lock_sha256': 'c' * 64,
          'capability_sha256': 'd' * 64, 'policy_sha256': 'e' * 64}
PID = 100
JOB_ENTITY = json.loads((ROOT / 'ci/tests/fixtures/mr7_current_job.json').read_text())


def job(job_id, name, status='success'):
    # Preserve the saved GitLab response shape; only substitute test identities
    # and model downloadable artifacts for successful evidence jobs.
    result = deepcopy(JOB_ENTITY)
    result.update(id=job_id, name=name, status=status, failure_reason=None,
                  web_url=f'{m.WEB}/-/jobs/{job_id}')
    result['commit'].update(id=SHA, short_id=SHA[:8], web_url=f'{m.WEB}/-/commit/{SHA}')
    result['pipeline'].update(id=PID, iid=1, sha=SHA, status='running',
                              web_url=f'{m.WEB}/-/pipelines/{PID}')
    result['user']['id'] = 23
    if status == 'running':
        result.update(finished_at=None, duration=None)
    if status == 'success':
        result['artifacts_file'] = {'filename': 'artifacts.zip', 'size': 50}
        result['artifacts'] = [{'file_type': 'archive', 'size': 50,
                                'filename': 'artifacts.zip', 'file_format': 'zip'}]
    return result


class FakeGitLab:
    def __init__(self):
        self.jobs = {i + 11: job(i + 11, name) for i, name in enumerate(m.CHECKS)}
        self.jobs[30] = job(30, 'mr7_release_receipts')
        self.jobs[40] = job(40, 'mr7_release_attestation')
        self.jobs[50] = job(50, 'publish_preview_ai', 'running')
        self.blobs = {}
        self.log = b''
        self.protected = True
        self.pipeline = {'id': PID, 'project_id': m.PROJECT, 'sha': SHA, 'ref': 'main',
                         'source': 'push', 'web_url': f'{m.WEB}/-/pipelines/{PID}'}

    def get(self, path):
        if path.startswith('jobs/'):
            return deepcopy(self.jobs[int(path.split('/')[1])])
        if path == f'pipelines/{PID}':
            return deepcopy(self.pipeline)
        if path == 'repository/branches/main':
            return {'protected': self.protected}
        raise AssertionError(path)

    def current_job(self):
        return self.get('jobs/50')

    def current_release_protected(self):
        return self.protected

    def artifact(self, job_id, path):
        try:
            return self.blobs[(int(job_id), path)]
        except KeyError:
            raise m.GateError('missing artifact') from None

    def trace(self, job_id):
        return self.log


class PipelineSourcePolicyTests(unittest.TestCase):
    # https://docs.gitlab.com/ci/jobs/job_rules/#ci_pipeline_source-predefined-variable
    SOURCES = ('api', 'chat', 'external', 'external_pull_request_event',
               'merge_request_event', 'ondemand_dast_scan', 'ondemand_dast_validation',
               'parent_pipeline', 'pipeline', 'push', 'schedule',
               'security_orchestration_policy', 'trigger', 'web', 'webide')

    def rule_matches(self, condition, variables):
        """Evaluate the comparisons and &&/|| used by these delivery rules."""
        def matches(term):
            match = re.fullmatch(r'\$(\w+)\s*(==|!=|=~)\s*(?:"([^"]*)"|/([^/]*)/)',
                                 term.strip())
            self.assertIsNotNone(match, f'Unsupported rule term: {term}')
            variable, operator, literal, pattern = match.groups()
            value = variables.get(variable, '')
            if operator == '=~':
                return re.search(pattern, value) is not None
            return (value == literal) if operator == '==' else (value != literal)

        return any(all(matches(term) for term in group.split('&&'))
                   for group in condition.split('||'))

    def test_pipeline_source_rules_and_validators_agree_for_every_documented_source(self):
        content = (ROOT / '.gitlab-ci.yml').read_text()
        for name in ('publish_preview', 'publish_preview_ai', 'mr7_release_attestation'):
            block = re.search(rf'^{name}:\n(.*?)(?=\n\S|\Z)', content, re.M | re.S)
            self.assertIsNotNone(block, name)
            rules_block = re.search(r'^  rules:\n(.*?)(?=\n  \S|\Z)', block[1], re.M | re.S)
            self.assertIsNotNone(rules_block, name)
            rules = re.findall(r"^    - if: '([^\n]+)'\n((?:      [^\n]+\n)*)",
                               rules_block[1] + '\n', re.M)
            self.assertEqual(len(rules), 2, name)
            for source in self.SOURCES:
                with self.subTest(job=name, source=source):
                    expected = m.pipeline_source_allowed(name, source)
                    variables = {'CI_PIPELINE_SOURCE': source, 'CI_PROJECT_ID': str(m.PROJECT),
                                 'CI_COMMIT_REF_PROTECTED': 'true', 'CI_COMMIT_BRANCH': 'main',
                                 'MR7_RELEASE_AI': 'false'}
                    decision = None
                    for condition, attributes in rules:
                        if self.rule_matches(condition, variables):
                            when = re.search(r'^      when: (\w+)$', attributes, re.M)
                            decision = when[1] if when else 'on_success'
                            break
                    self.assertEqual(decision, ('on_success' if name == 'publish_preview'
                                                else 'manual') if expected else None)
                    api = FakeGitLab()
                    api.pipeline['source'] = source
                    current = job(50, name, 'running')
                    current['pipeline']['source'] = source
                    for validator in (
                        lambda: m.verify_current_job(current, name, SHA),
                        lambda: m.verify_job(api, current, name, SHA, status='running'),
                    ):
                        if expected:
                            validator()
                        else:
                            with self.assertRaises(m.GateError):
                                validator()

    def test_saved_publish_preview_push_is_accepted_while_running(self):
        current = deepcopy(JOB_ENTITY)
        current['status'] = 'running'
        self.assertNotIn('source', current)
        self.assertEqual(current['pipeline']['source'], 'push')
        self.assertIs(m.verify_current_job(current, 'publish_preview', current['commit']['id']), current)

    def test_saved_publish_preview_merge_request_is_rejected(self):
        current = deepcopy(JOB_ENTITY)
        current['status'] = 'running'
        current['pipeline']['source'] = 'merge_request_event'
        with self.assertRaises(m.GateError):
            m.verify_current_job(current, 'publish_preview', current['commit']['id'])

    def test_pipeline_source_overrides_conflicting_top_level_source(self):
        for name in ('publish_preview', 'publish_preview_ai', 'mr7_release_attestation'):
            for source, top_level, allowed in (('push', 'merge_request_event', True),
                                               ('merge_request_event', 'push', False)):
                with self.subTest(job=name, pipeline_source=source, top_level_source=top_level):
                    current = job(50, name, 'running')
                    current['pipeline']['source'] = source
                    current['source'] = top_level
                    if allowed:
                        m.verify_current_job(current, name, SHA)
                    else:
                        with self.assertRaises(m.GateError):
                            m.verify_current_job(current, name, SHA)

    def test_ai_current_job_accepts_only_push_web_api_schedule(self):
        for name in ('publish_preview_ai', 'mr7_release_attestation'):
            for source in (*self.SOURCES, 'unknown'):
                with self.subTest(job=name, source=source):
                    api = FakeGitLab()
                    api.jobs[50]['name'] = name
                    api.jobs[50]['pipeline']['source'] = source
                    api.pipeline['source'] = source
                    if source in ('push', 'web', 'api', 'schedule'):
                        self.assertEqual(m.current_identity(api, name, SHA)['id'], 50)
                    else:
                        with self.assertRaises(m.GateError):
                            m.current_identity(api, name, SHA)

    def test_missing_pipeline_source_is_rejected(self):
        for name in ('publish_preview', 'publish_preview_ai', 'mr7_release_attestation'):
            for top_level in (None, 'push'):
                with self.subTest(job=name, top_level_source=top_level):
                    current = job(50, name, 'running')
                    del current['pipeline']['source']
                    if top_level is not None:
                        current['source'] = top_level
                    with self.assertRaises(m.GateError):
                        m.verify_current_job(current, name, SHA)

    def test_invalid_pipeline_source_is_rejected(self):
        for name in ('publish_preview', 'publish_preview_ai', 'mr7_release_attestation'):
            for source in (None, '', False, 0, [], {}):
                with self.subTest(job=name, source=source):
                    current = job(50, name, 'running')
                    current['pipeline']['source'] = source
                    with self.assertRaises(m.GateError):
                        m.verify_current_job(current, name, SHA)

    def test_off_trigger_and_pipeline_keep_identity_checks(self):
        for source in ('trigger', 'pipeline'):
            for path, value in ((('name',), 'other'), (('status',), 'success'),
                                (('ref',), 'other'), (('tag',), True),
                                (('commit', 'id'), 'f' * 40), (('pipeline', 'project_id'), 1),
                                (('pipeline', 'sha'), 'f' * 40), (('pipeline', 'ref'), 'other'),
                                (('web_url',), 'https://example.invalid/jobs/50')):
                with self.subTest(source=source, path=path):
                    current = job(50, 'publish_preview', 'running')
                    current['pipeline']['source'] = source
                    target = current
                    for key in path[:-1]:
                        target = target[key]
                    target[path[-1]] = value
                    with self.assertRaises(m.GateError):
                        m.verify_current_job(current, 'publish_preview', SHA)
            api = FakeGitLab()
            api.pipeline['source'] = source
            api.protected = False
            with self.subTest(source=source, protected=False), self.assertRaises(m.GateError):
                m.verify_job(api, job(50, 'publish_preview'), 'publish_preview', SHA)


class IdentityDiagnosticTests(unittest.TestCase):
    JOB_TOKEN = 'synthetic-secret-job-value'
    READ_TOKEN = 'synthetic-secret-read-value'

    @staticmethod
    def change(target, path, value):
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value

    def off_delivery(self, api, overrides=None):
        env = {'CI_COMMIT_SHA': SHA, 'CI_PROJECT_ID': str(m.PROJECT),
               'CI_COMMIT_REF_PROTECTED': 'true', 'CI_COMMIT_BRANCH': 'main',
               'CI_PIPELINE_SOURCE': 'push', 'CI_JOB_TOKEN': self.JOB_TOKEN,
               'MR7_GITLAB_READ_TOKEN_FILE': self.READ_TOKEN}
        env.update(overrides or {})
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(m.subprocess, 'check_output', return_value=SHA + '\n'), \
                mock.patch.object(m, 'GitLab', return_value=api), \
                mock.patch.object(m, 'metadata_for_delivery') as metadata:
            try:
                m.main(['delivery', '--mode', 'off'])
            finally:
                metadata.assert_not_called()

    def branch_protection(self, body):
        api = m.GitLab(self.READ_TOKEN, self.JOB_TOKEN)
        with mock.patch.object(api, 'read', return_value=m.canonical(body)):
            return api.current_release_protected()

    def refusal_cases(self, bad='wrong'):
        identity_fields = (('name',), ('status',), ('ref',), ('tag',),
                           ('commit', 'id'), ('pipeline', 'sha'),
                           ('pipeline', 'ref'), ('pipeline', 'project_id'), ('web_url',))
        for path in (*identity_fields, ('pipeline', 'source'), ('id',), ('pipeline',), ('commit',)):
            current = job(50, 'publish_preview_ai', 'running')
            current.update(headers={'JOB-TOKEN': self.JOB_TOKEN},
                           user={'id': 23, 'name': bad}, body=bad)
            self.change(current, path, bad)
            yield 'current', '.'.join(path), lambda current=current: m.verify_current_job(
                current, 'publish_preview_ai', SHA)

        for path in (*identity_fields, ('id',), ('pipeline', 'id'), ('pipeline',), ('commit',)):
            target = job(40, 'mr7_release_attestation')
            target.update(headers={'PRIVATE-TOKEN': self.READ_TOKEN}, body=bad)
            self.change(target, path, bad)
            yield 'job', '.'.join(path), lambda target=target: m.verify_job(
                FakeGitLab(), target, 'mr7_release_attestation', SHA, pipeline_id=PID)

        target = job(40, 'mr7_release_attestation')
        target['pipeline']['id'] = PID + 1
        yield 'job pipeline binding', 'pipeline.id', lambda: m.verify_job(
            FakeGitLab(), target, 'mr7_release_attestation', SHA, pipeline_id=PID)

        for field in ('id', 'project_id', 'sha', 'ref', 'source', 'web_url'):
            api = FakeGitLab()
            api.pipeline[field] = bad
            api.pipeline.update(headers={'JOB-TOKEN': self.JOB_TOKEN}, body=bad)
            yield 'pipeline', 'pipeline.' + field, lambda api=api: m.verify_job(
                api, job(40, 'mr7_release_attestation'), 'mr7_release_attestation', SHA)

        api = FakeGitLab()
        api.protected = bad
        yield 'job protection', 'protected', lambda: m.verify_job(
            api, job(40, 'mr7_release_attestation'), 'mr7_release_attestation', SHA)

        for body, field in (({'body': bad}, 'branches'), ([], 'name=main'),
                            ([{'name': bad, 'protected': True}], 'name=main'),
                            ([{'name': 'main', 'protected': True}] * 2, 'name=main'),
                            ([{'name': 'main', 'protected': bad, 'body': bad}], 'protected')):
            yield 'branch list', field, lambda body=body: self.branch_protection(body)

        for field in ('CI_COMMIT_SHA', 'CI_PROJECT_ID', 'CI_COMMIT_REF_PROTECTED',
                      'CI_COMMIT_BRANCH', 'CI_PIPELINE_SOURCE'):
            api = FakeGitLab()
            api.jobs[50]['name'] = 'publish_preview'
            value = 'merge_request_event' if field == 'CI_PIPELINE_SOURCE' else bad
            yield 'release lane', field, lambda api=api, field=field, value=value: self.off_delivery(
                api, {field: value})

        api = FakeGitLab()
        api.jobs[50]['name'] = 'publish_preview'
        api.protected = False
        yield 'off protection', 'protected', lambda: self.off_delivery(api)

    def test_each_identity_release_condition_names_its_refusal(self):
        for check, field, refuse in self.refusal_cases():
            with self.subTest(check=check, field=field):
                with self.assertRaises(m.GateError) as caught:
                    refuse()
                self.assertEqual(str(caught.exception).rsplit(': ', 1)[-1], field)

    def test_multiple_failed_conditions_are_all_named(self):
        current = job(50, 'publish_preview', 'running')
        current['pipeline']['source'] = 'merge_request_event'
        current['web_url'] = 'https://invalid.example/job'
        with self.assertRaises(m.GateError) as caught:
            m.verify_current_job(current, 'publish_preview', SHA)
        self.assertEqual(str(caught.exception),
                         'Untrusted current job identity: pipeline.source, web_url')
        api = FakeGitLab()
        api.pipeline.update(sha='f' * 40, ref='other')
        with self.assertRaises(m.GateError) as caught:
            m.verify_job(api, job(40, 'mr7_release_attestation'), 'mr7_release_attestation', SHA)
        self.assertEqual(str(caught.exception),
                         'Untrusted release pipeline: pipeline.sha, pipeline.ref')

    def test_refusals_never_expose_tokens_headers_bodies_or_user_data(self):
        poison = (f'CI_JOB_TOKEN={self.JOB_TOKEN}\nJOB-TOKEN: {self.JOB_TOKEN}\n'
                  f'PRIVATE-TOKEN: {self.READ_TOKEN}\nprivate-response-body private-user-data')
        for check, field, refuse in self.refusal_cases(poison):
            with self.subTest(check=check, field=field):
                with self.assertRaises(m.GateError) as caught:
                    refuse()
                message = str(caught.exception)
                for forbidden in (self.JOB_TOKEN, self.READ_TOKEN, 'CI_JOB_TOKEN', 'JOB-TOKEN',
                                  'PRIVATE-TOKEN', 'private-response-body', 'private-user-data'):
                    self.assertNotIn(forbidden, message)

    def test_branch_protection_requires_one_main_and_literal_true(self):
        self.assertIs(self.branch_protection([{'name': 'other', 'protected': False},
                                             {'name': 'main', 'protected': True}]), True)
        for protected in (False, None, 'true', 1, [], {}):
            with self.subTest(protected=protected), self.assertRaises(m.GateError):
                self.branch_protection([{'name': 'main', 'protected': protected}])

    def test_malformed_nested_identity_objects_are_named(self):
        for field in ('pipeline', 'commit'):
            for value in (None, [], 'wrong', False):
                for current in (True, False):
                    with self.subTest(field=field, value=value, current=current):
                        target = job(50, 'publish_preview_ai', 'running' if current else 'success')
                        target[field] = value
                        with self.assertRaises(m.GateError) as caught:
                            if current:
                                m.verify_current_job(target, 'publish_preview_ai', SHA)
                            else:
                                m.verify_job(FakeGitLab(), target, 'publish_preview_ai', SHA)
                        self.assertEqual(str(caught.exception).rsplit(': ', 1)[-1], field)

    def test_cli_refusal_keeps_exit_code_and_never_echoes_credentials(self):
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        env = dict(os.environ, CI_COMMIT_SHA=sha, CI_PROJECT_ID=f'JOB-TOKEN: {self.JOB_TOKEN}',
                   CI_COMMIT_REF_PROTECTED='true', CI_COMMIT_BRANCH='main',
                   CI_PIPELINE_SOURCE='push', CI_JOB_TOKEN=self.JOB_TOKEN)
        result = subprocess.run([sys.executable, str(ROOT / 'ci/mr7_attestation.py'),
                                 'delivery', '--mode', 'off'], cwd=ROOT, env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr,
                         'MR7 gate rejected: Not a protected project release lane: CI_PROJECT_ID\n')


class DeliveryGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / 'artifacts'
        self.directory.mkdir()
        (self.directory / 'release.apk').write_bytes(b'synthetic APK')
        self.api = FakeGitLab()
        self.metadata = {'commit': SHA, 'channel': 'gitlab', 'build_type': 'release',
                         'package': 'io.gitlabmobile.gitlab_mobile', 'debuggable': False,
                         'certificate_sha256': m.STABLE_CERT, 'entrypoint': 'lib/main.dart',
                         'ai_assistant': True, 'ai_background': False,
                         'apk_sha256': m.digest(b'synthetic APK'), **SOURCE,
                         'flutter_version': '3.47.2', 'flutter_revision': 'f', 'dart_version': '3',
                         'pipeline_url': f'{m.WEB}/-/pipelines/{PID}', 'job_url': f'{m.WEB}/-/jobs/15'}
        self.write_metadata()
        self.patcher = mock.patch.object(m, 'source_digests', return_value=SOURCE)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        requirements = {'capability_sha256': SOURCE['capability_sha256'],
                        'operations': {'read:synthetic': ['project/basic']},
                        'emulator': ['foreground/basic']}
        self.requirements_patcher = mock.patch.object(m, 'RELEASE_REQUIREMENTS', requirements)
        self.requirements_patcher.start()
        self.addCleanup(self.requirements_patcher.stop)
        self.inspector_patcher = mock.patch.object(m, 'inspect_apk', return_value={
            'package': 'io.gitlabmobile.gitlab_mobile', 'debuggable': False,
            'certificate_sha256': m.STABLE_CERT})
        self.inspector_patcher.start()
        self.addCleanup(self.inspector_patcher.stop)
        self.rows = []
        for kind, names in m.RECEIPTS.items():
            for name in names:
                path = f'mr7-receipts/{kind}/{name}.json'
                receipt = {'schema': 1, 'status': 'PASS', 'kind': kind, 'name': name,
                           'release_sha': SHA, 'source': SOURCE, 'flags': m.FLAGS,
                           'policy': 'production', 'flavor': 'gitlab', 'build_type': 'release',
                           'created_at': NOW.isoformat()}
                common = {'status': 'PASS', 'release_sha': SHA, 'source': SOURCE,
                          'flags': m.FLAGS, 'policy': 'production', 'created_at': NOW.isoformat()}
                if name == 'events_isolation':
                    receipt.update(isolation='PASS', outside_events=0, expected_user_id=23)
                if name == 'production_operations':
                    identity = ('read:synthetic', 'project/basic')
                    detail_path = f'mr7-receipts/operations/{m.digest(m.canonical(identity))}.json'
                    detail = {**common, 'operation_id': identity[0], 'variant': identity[1],
                              'independent_readback': 'PASS', 'events_isolation': 'PASS'}
                    detail_data = m.canonical(detail)
                    self.api.blobs[(30, detail_path)] = detail_data
                    receipt['operations'] = [{'operation_id': identity[0], 'variant': identity[1],
                                              'path': detail_path, 'sha256': m.digest(detail_data)}]
                if name == 'production_smoke':
                    identity = ('foreground/basic',)
                    detail_path = f'mr7-receipts/emulator-rows/{m.digest(m.canonical(identity))}.json'
                    detail_data = m.canonical({**common, 'name': identity[0], 'device_result': 'PASS'})
                    self.api.blobs[(30, detail_path)] = detail_data
                    receipt['rows'] = [{'name': identity[0], 'path': detail_path,
                                        'sha256': m.digest(detail_data)}]
                data = m.canonical(receipt)
                self.api.blobs[(30, path)] = data
                self.rows.append({'kind': kind, 'name': name, 'job_id': 30,
                                  'job_url': f'{m.WEB}/-/jobs/30', 'path': path,
                                  'sha256': m.digest(data)})
        index = {'checks': {name: i + 11 for i, name in enumerate(m.CHECKS)}, 'receipts': self.rows}
        self.api.blobs[(30, 'mr7-receipts/index.json')] = m.canonical(index)
        current = self.api.get('jobs/40')
        current['status'] = 'running'
        self.attestation = m.make_attestation(self.api, current, SHA, self.root, 30, now=NOW)
        self.meta, self.hashes = m.metadata_for_delivery(self.root, SHA, 'ai')

    def write_metadata(self):
        (self.directory / 'build-metadata.json').write_bytes(m.canonical(self.metadata))

    def validate(self, attestation=None, **kwargs):
        return m.validate_attestation(self.api, attestation or self.attestation, SHA, SOURCE,
                                      self.meta, self.hashes, pipeline_id=PID, now=NOW, **kwargs)

    def anchor(self, attestation=None):
        data = m.canonical(attestation or self.attestation)
        h = m.digest(data)
        self.api.blobs[(40, m.ATTESTATION_PATH)] = data
        self.api.blobs[(40, 'mr7-attestation/SHA256SUMS')] = f'{h}  attestation.json\n'.encode()
        self.api.log = f'MR7_ATTESTATION_SHA256={h}\n'.encode()

    def test_real_source_digest_helper_matches_checked_out_inputs(self):
        self.patcher.stop()
        try:
            result = m.source_digests(ROOT)
            self.assertEqual(result['tree'], subprocess.check_output(
                ['git', 'rev-parse', 'HEAD^{tree}'], cwd=ROOT, text=True).strip())
            self.assertEqual(result['lock_sha256'], hashlib.sha256((ROOT / 'pubspec.lock').read_bytes()).hexdigest())
            for name in ('capability_sha256', 'policy_sha256'):
                self.assertRegex(result[name], r'^[0-9a-f]{64}$')
            self.assertIn('from mr7_attestation import source_digests',
                          (ROOT / 'ci/build_android.sh').read_text())
        finally:
            self.patcher.start()

    def test_build_metadata_uses_real_source_digest_helper(self):
        release_spec = importlib.util.spec_from_file_location(
            'release_flag_tests', ROOT / 'tool/tests/test_mr7_release_flags.py')
        release_tests = importlib.util.module_from_spec(release_spec)
        release_spec.loader.exec_module(release_tests)
        fixture = release_tests.AndroidReleaseFlagTests('test_explicit_flags_are_passed_and_recorded')
        fixture.setUp()
        try:
            shutil.copy(ROOT / 'ci/mr7_attestation.py', fixture.root / 'ci/mr7_attestation.py')
            (fixture.root / 'lib').symlink_to(ROOT / 'lib', target_is_directory=True)
            self.patcher.stop()
            expected = m.source_digests(ROOT)
            self.patcher.start()
            expected['lock_sha256'] = m.digest((fixture.root / 'pubspec.lock').read_bytes())
            fixture.stub('git', '#!/bin/bash\nprintf "%s\\n" ' + expected['tree'] + '\n')
            result = fixture.build('--ai-assistant', 'true')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            _, metadata = fixture.read_build()
            for key, value in expected.items():
                self.assertEqual(metadata[key], value, key)
        finally:
            fixture.doCleanups()

    def test_make_and_validate_complete_attestation(self):
        self.validate()
        self.anchor()
        self.assertEqual(m.fetch_attestation(self.api, 40, SHA, PID), self.attestation)
        self.assertEqual(m.current_identity(self.api, 'publish_preview_ai', SHA)['id'], 50)

    def test_requirements_are_fail_closed_by_default(self):
        with mock.patch.object(m, 'RELEASE_REQUIREMENTS', None), self.assertRaises(m.GateError):
            self.validate()

    def test_dirty_source_is_rejected(self):
        self.patcher.stop()
        try:
            with mock.patch.object(m.subprocess, 'run') as run:
                run.return_value.returncode = 1
                with self.assertRaises(m.GateError): m.source_digests(ROOT, require_clean=True)
        finally:
            self.patcher.start()

    def test_inspect_apk_reads_pinned_tools_and_rejects_invalid_signer(self):
        sdk = self.root / 'sdk/build-tools/36.0.0'
        sdk.mkdir(parents=True)
        aapt = sdk / 'aapt2'
        signer = sdk / 'apksigner'
        aapt.write_text("#!/bin/bash\nprintf \"package: name='io.gitlabmobile.gitlab_mobile'\\n\"\n")
        signer.write_text('#!/bin/bash\nprintf "Signer #1 certificate SHA-256 digest: %s\\n" ' + m.STABLE_CERT + '\n')
        aapt.chmod(0o755)
        signer.chmod(0o755)
        self.inspector_patcher.stop()
        try:
            with mock.patch.dict(os.environ, {'ANDROID_HOME': str(self.root / 'sdk')}):
                self.assertEqual(m.inspect_apk(self.directory / 'release.apk'),
                                 {'package': 'io.gitlabmobile.gitlab_mobile', 'debuggable': False,
                                  'certificate_sha256': m.STABLE_CERT})
                signer.write_text('#!/bin/bash\nprintf "bad signer\\n"\n')
                with self.assertRaises(m.GateError): m.inspect_apk(self.directory / 'release.apk')
                signer.unlink()
                with self.assertRaises(m.GateError): m.inspect_apk(self.directory / 'release.apk')
        finally:
            self.inspector_patcher.start()

    def test_detail_rows_and_independent_proofs_are_required(self):
        for name, row_key, field, value in (
            ('production_operations', 'operations', None, None),
            ('production_smoke', 'rows', None, None),
            ('production_operations', 'operations', 'independent_readback', 'NOT_RUN'),
            ('production_operations', 'operations', 'events_isolation', 'NOT_RUN'),
            ('production_smoke', 'rows', 'device_result', 'NOT_RUN')):
            with self.subTest(name=name, field=field):
                att = deepcopy(self.attestation)
                row = next(r for r in att['receipts'] if r['name'] == name)
                aggregate_key = (30, row['path'])
                original_aggregate = self.api.blobs[aggregate_key]
                aggregate = json.loads(original_aggregate)
                detail_original = None
                if field is None:
                    aggregate[row_key] = []
                else:
                    locator = aggregate[row_key][0]
                    detail_key = (30, locator['path'])
                    detail_original = self.api.blobs[detail_key]
                    detail = json.loads(detail_original)
                    detail[field] = value
                    detail_data = m.canonical(detail)
                    self.api.blobs[detail_key] = detail_data
                    locator['sha256'] = m.digest(detail_data)
                aggregate_data = m.canonical(aggregate)
                self.api.blobs[aggregate_key] = aggregate_data
                row['sha256'] = m.digest(aggregate_data)
                with self.assertRaises(m.GateError): self.validate(att)
                self.api.blobs[aggregate_key] = original_aggregate
                if detail_original is not None: self.api.blobs[detail_key] = detail_original

    def test_fetched_provider_must_equal_selected_job(self):
        att = deepcopy(self.attestation)
        att['provider']['job_id'] = 41
        self.anchor(att)
        with self.assertRaises(m.GateError): m.fetch_attestation(self.api, 40, SHA, PID)

    def test_attestation_rejects_wrong_sha_source_digests_and_artifact_tuple(self):
        for path, value in ((('release_sha',), 'f' * 40),
                            (('source', 'tree'), 'f' * 40),
                            (('source', 'lock_sha256'), 'f' * 64),
                            (('source', 'capability_sha256'), 'f' * 64),
                            (('source', 'policy_sha256'), 'f' * 64),
                            (('artifact', 'apk_sha256'), 'f' * 64),
                            (('artifact', 'metadata_sha256'), 'f' * 64),
                            (('artifact', 'certificate_sha256'), 'f' * 64),
                            (('artifact', 'build_type'), 'debug'),
                            (('artifact', 'flavor'), 'play')):
            with self.subTest(path=path):
                att = deepcopy(self.attestation)
                dst = att
                for key in path[:-1]: dst = dst[key]
                dst[path[-1]] = value
                with self.assertRaises(m.GateError): self.validate(att)

    def test_metadata_rejects_wrong_flags_variant_cert_source_and_bytes(self):
        for key, value in (('commit', 'f' * 40), ('channel', 'play'), ('build_type', 'debug'),
                           ('package', 'wrong'), ('debuggable', True), ('certificate_sha256', 'f' * 64),
                           ('entrypoint', 'other'), ('ai_assistant', False), ('ai_background', True),
                           ('tree', 'f' * 40), ('lock_sha256', 'f' * 64),
                           ('capability_sha256', 'f' * 64), ('policy_sha256', 'f' * 64),
                           ('apk_sha256', 'f' * 64)):
            with self.subTest(key=key):
                old = self.metadata[key]
                self.metadata[key] = value
                self.write_metadata()
                with self.assertRaises(m.GateError): m.metadata_for_delivery(self.root, SHA, 'ai')
                self.metadata[key] = old
        self.write_metadata()
        (self.directory / 'release.apk').write_bytes(b'changed')
        with self.assertRaises(m.GateError): m.metadata_for_delivery(self.root, SHA, 'ai')

    def test_missing_checks_receipts_or_wrong_receipt_content_fail(self):
        for name in m.CHECKS:
            att = deepcopy(self.attestation)
            del att['checks'][name]
            with self.subTest(check=name), self.assertRaises(m.GateError): self.validate(att)
        for i, row in enumerate(self.rows):
            att = deepcopy(self.attestation)
            del att['receipts'][i]
            with self.subTest(receipt=row['name']), self.assertRaises(m.GateError): self.validate(att)
        key = (30, self.rows[0]['path'])
        self.api.blobs[key] += b'changed'
        with self.assertRaises(m.GateError): self.validate()

    def test_receipt_semantics_and_freshness_cannot_be_replaced_by_matching_hash(self):
        row = self.rows[0]
        key = (30, row['path'])
        original = self.api.blobs[key]
        for field, value in (('status', 'NOT_RUN'), ('release_sha', 'f' * 40),
                             ('policy', 'candidate'), ('created_at', (NOW - timedelta(hours=25)).isoformat()),
                             ('created_at', (NOW + timedelta(seconds=1)).isoformat())):
            with self.subTest(field=field, value=value):
                receipt = json.loads(original)
                receipt[field] = value
                data = m.canonical(receipt)
                self.api.blobs[key] = data
                att = deepcopy(self.attestation)
                att['receipts'][0]['sha256'] = m.digest(data)
                with self.assertRaises(m.GateError): self.validate(att)
        self.api.blobs[key] = original

    def test_stale_future_and_provider_identity_fail(self):
        for value in ((NOW - timedelta(hours=25)).isoformat(), (NOW + timedelta(seconds=1)).isoformat()):
            att = deepcopy(self.attestation)
            att['created_at'] = value
            with self.subTest(time=value), self.assertRaises(m.GateError): self.validate(att)
        for key, value in (('job_id', 50), ('project_id', 1), ('user_id', 24), ('job_url', 'https://evil.invalid')):
            att = deepcopy(self.attestation)
            att['provider'][key] = value
            with self.subTest(key=key), self.assertRaises((m.GateError, KeyError)): self.validate(att)

    def test_job_identity_project_status_ref_pipeline_and_sha_are_checked(self):
        for path, value in ((('name',), 'other'), (('status',), 'failed'), (('ref',), 'other'),
                            (('tag',), True), (('commit', 'id'), 'f' * 40),
                            (('pipeline', 'project_id'), 1), (('pipeline', 'sha'), 'f' * 40),
                            (('pipeline', 'ref'), 'other'), (('pipeline', 'id'), 101)):
            with self.subTest(path=path):
                self.api.jobs[40] = job(40, 'mr7_release_attestation')
                target = self.api.jobs[40]
                for key in path[:-1]: target = target[key]
                target[path[-1]] = value
                with self.assertRaises((m.GateError, AssertionError)): m.fetch_attestation(self.api, 40, SHA, PID)
        self.api.jobs[40] = job(40, 'mr7_release_attestation')
        self.api.protected = False
        with self.assertRaises(m.GateError): m.fetch_attestation(self.api, 40, SHA, PID)

    def test_expired_missing_or_mismatched_artifact_and_trace_are_rejected(self):
        self.anchor()
        self.api.jobs[40]['artifacts_expire_at'] = (NOW - timedelta(seconds=1)).isoformat()
        with self.assertRaises(m.GateError): m.fetch_attestation(self.api, 40, SHA, PID)
        self.api.jobs[40]['artifacts_expire_at'] = None
        self.api.jobs[40]['artifacts_file']['size'] = 0
        with self.assertRaises(m.GateError): m.fetch_attestation(self.api, 40, SHA, PID)
        self.api.jobs[40]['artifacts_file']['size'] = 10
        for log in (b'', b'MR7_ATTESTATION_SHA256=' + b'f' * 64 + b'\n', self.api.log * 2):
            old = self.api.log
            self.api.log = log
            with self.assertRaises(m.GateError): m.fetch_attestation(self.api, 40, SHA, PID)
            self.api.log = old
        self.api.blobs[(40, 'mr7-attestation/SHA256SUMS')] = b'wrong'
        with self.assertRaises(m.GateError): m.fetch_attestation(self.api, 40, SHA, PID)
        del self.api.blobs[(40, m.ATTESTATION_PATH)]
        with self.assertRaises(m.GateError): m.fetch_attestation(self.api, 40, SHA, PID)

    def test_legacy_undefined_flags_are_off(self):
        del self.metadata['ai_assistant']
        del self.metadata['ai_background']
        self.write_metadata()
        m.metadata_for_delivery(self.root, SHA, 'off')
        with self.assertRaises(m.GateError): m.metadata_for_delivery(self.root, SHA, 'ai')

    def shell_delivery(self, mode, *, legacy=False, fake_kind='valid', job_id='', extra_env=None):
        # The actual shell and validator execute; GitLab is an in-process fake and
        # curl/git are synthetic executables, so no network or credentials are used.
        case = self.root / 'shell'
        case.mkdir(exist_ok=True)
        (case / 'bin').mkdir(exist_ok=True)
        (case / 'ci').mkdir(exist_ok=True)
        shutil.copy(ROOT / 'ci/deliver_preview.sh', case / 'ci/deliver_preview.sh')
        artifacts = case / 'artifacts'
        artifacts.mkdir(exist_ok=True)
        (artifacts / 'release.apk').write_bytes(b'synthetic APK')
        metadata = deepcopy(self.metadata)
        if legacy:
            for key in ('ai_assistant', 'ai_background', 'apk_sha256', 'package',
                        'debuggable', 'certificate_sha256', 'entrypoint', *SOURCE):
                metadata.pop(key, None)
        metadata_bytes = m.canonical(metadata)
        (artifacts / 'build-metadata.json').write_bytes(metadata_bytes)
        (artifacts / 'SHA256SUMS').write_text(
            f"{m.digest(b'synthetic APK')}  release.apk\n"
            f"{m.digest(metadata_bytes)}  build-metadata.json\n")
        driver = case / 'driver.py'
        driver.write_text(f'''import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('gate_tests', {str(Path(__file__).resolve())!r})
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)
fixture = t.DeliveryGateTests('test_make_and_validate_complete_attestation')
fixture.setUp()
if os.environ.get('FAKE_KIND') == 'mismatch':
    fixture.attestation['release_sha'] = 'f' * 40
if os.environ.get('FAKE_KIND') == 'mr':
    fixture.api.jobs[50]['pipeline']['source'] = 'merge_request_event'
if os.environ.get('FAKE_KIND') == 'unprotected':
    fixture.api.protected = False
if '--mode' in sys.argv and sys.argv[sys.argv.index('--mode') + 1] == 'off':
    fixture.api.jobs[50]['name'] = 'publish_preview'
fixture.anchor()
t.m.api_from_environment = lambda: fixture.api
t.m.GitLab = lambda *args: fixture.api
try:
    t.m.main(sys.argv[1:])
except (t.m.GateError, OSError, ValueError, KeyError, TypeError) as error:
    print('synthetic gate rejected: ' + str(error), file=sys.stderr)
    sys.exit(1)
''')
        python = case / 'bin/python3'
        python.write_text('#!/bin/bash\nshift\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(driver)) + ' "$@"\n')
        python.chmod(0o755)
        git = case / 'bin/git'
        git.write_text('#!/bin/bash\nprintf "%s\\n" ' + SHA + '\n')
        git.chmod(0o755)
        curl = case / 'bin/curl'
        curl.write_text('#!/bin/bash\nprintf "upload\\n" >> "$SYNTHETIC_UPLOAD_LOG"\n')
        curl.chmod(0o755)
        upload_log = case / 'uploads'
        if upload_log.exists(): upload_log.unlink()
        env = dict(os.environ, PATH=str(case / 'bin') + os.pathsep + os.environ['PATH'],
                   CI_JOB_TOKEN='synthetic', CI_COMMIT_SHA=SHA, CI_PROJECT_ID=str(m.PROJECT),
                   CI_COMMIT_REF_PROTECTED='true', CI_COMMIT_BRANCH='main', CI_PIPELINE_SOURCE='push',
                   MR7_ATTESTATION_JOB_ID=job_id, FAKE_KIND=fake_kind,
                   SYNTHETIC_UPLOAD_LOG=str(upload_log))
        env.update(extra_env or {})
        result = subprocess.run(['bash', 'ci/deliver_preview.sh', mode], cwd=case,
                                env=env, capture_output=True, text=True)
        uploads = upload_log.read_text().splitlines() if upload_log.exists() else []
        return result, uploads

    def test_shell_ai_missing_or_mismatched_attestation_never_uploads(self):
        for job_id, fake in (('', 'valid'), ('40', 'mismatch')):
            result, uploads = self.shell_delivery('ai', job_id=job_id, fake_kind=fake,
                extra_env={'MR7_SKIP_ATTESTATION': 'true', 'MR7_ATTESTATION_PATH': '/tmp/forged.json',
                           'MR7_ATTESTATION_URL': 'https://example.invalid/forged.json',
                           'MR7_ALLOW_UNATTESTED': 'true'})
            with self.subTest(job_id=job_id, fake=fake):
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(uploads, [])

    def test_shell_legacy_off_succeeds_and_ai_requires_valid_attestation(self):
        result, uploads = self.shell_delivery('off', legacy=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(uploads), 3)
        result, uploads = self.shell_delivery('ai', job_id='40')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(uploads), 3)

    def test_shell_rejects_unprotected_wrong_project_and_mr_without_upload(self):
        for override in ({'CI_COMMIT_REF_PROTECTED': 'false'}, {'CI_PROJECT_ID': '1'},
                         {'CI_PIPELINE_SOURCE': 'merge_request_event'}):
            result, uploads = self.shell_delivery('off', legacy=True, extra_env=override)
            with self.subTest(override=override):
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(uploads, [])
        for fake in ('mr', 'unprotected'):
            result, uploads = self.shell_delivery('off', legacy=True, fake_kind=fake)
            with self.subTest(authenticated_state=fake):
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(uploads, [])


if __name__ == '__main__':
    unittest.main()
