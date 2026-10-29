import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import signal
import sys
import time
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mr7_sandbox_runner', ROOT / 'tool/run_mr7_sandbox.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
actual_source_provenance = runner._source_provenance
SHA = 'a' * 40
SECRET = 'not-a-real-secret-12345'


def receipt(policy='production', **changes):
    result = {
        'schema': 1, 'status': 'PASS', 'transport': 'synthetic', 'policy': policy,
        'evidenceClass': 'CANDIDATE_ONLY' if policy == 'candidate' else 'SYNTHETIC',
        'finalEligible': False, 'releaseSha': SHA, 'live': 'NOT_RUN',
        'scenarios': [],
    }
    result.update(changes)
    return result


class SandboxWrapperTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / 'receipt.json'
        self.args = ['--output', str(self.output), '--expect-release-sha', SHA]
        head = mock.patch.object(runner, '_head_sha', return_value=SHA)
        head.start()
        self.addCleanup(head.stop)
        self.source_provenance = {'dirty': True, 'files': {name: {'sha256': 'b' * 64, 'gitStatus': '??'}
                                                           for name in runner.SOURCE_FILES}}
        self.provenance = {'head': SHA, **self.source_provenance}
        provenance_patch = mock.patch.object(runner, '_source_provenance', return_value=self.source_provenance)
        provenance_patch.start()
        self.addCleanup(provenance_patch.stop)

    def invoke(self, args=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = runner.main(self.args if args is None else args)
            except SystemExit as exc:
                code = exc.code
        return code, out.getvalue(), err.getvalue()

    def child(self, *, returned=None, returncode=0, interrupted=False, inspect=None):
        def run(command, **kwargs):
            self.assertEqual(command, ['fvm', 'flutter', 'test', '--no-pub', '--reporter',
                                       'expanded', 'tool/mr7_sandbox.dart'])
            self.assertIs(kwargs['stdout'], subprocess.DEVNULL)
            self.assertIs(kwargs['stderr'], subprocess.DEVNULL)
            self.assertFalse(kwargs.get('shell', False))
            self.assertTrue(kwargs['start_new_session'])
            env = kwargs['env']
            self.assertNotIn('FAKE_API_KEY', env)
            self.assertNotIn(SECRET, str(command) + str(env))
            config_path = Path(env['MR7_SANDBOX_CONFIG_FILE'])
            receipt_path = Path(env['MR7_SANDBOX_RECEIPT_FILE'])
            self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(receipt_path.stat().st_mode), 0o600)
            config = json.loads(config_path.read_text())
            self.config_path, self.receipt_path = config_path, receipt_path
            if inspect:
                inspect(config, env)
            if returned is not None:
                receipt_path.write_text(json.dumps(returned))
            class Process:
                pid = 987654321
                stopped = False
                def poll(self):
                    return -15 if self.stopped else None
                def wait(self, timeout=None):
                    if interrupted and timeout is None:
                        raise KeyboardInterrupt()
                    self.stopped = True
                    return returncode
            return Process()
        return run

    def test_default_production_and_temporary_files(self):
        def inspect(config, env):
            self.assertEqual(config, {'expectedUserId': 7, 'namespace': 'synthetic-owner',
                                      'releaseSha': SHA, 'policy': 'production',
                                      'suite': 'all', 'provider': {}})
        with mock.patch.dict(os.environ, {'FAKE_API_KEY': SECRET}, clear=True), \
             mock.patch.object(runner.subprocess, 'Popen', side_effect=self.child(returned=receipt(), inspect=inspect)):
            code, out, err = self.invoke()
        self.assertEqual(code, 0)
        self.assertIn('live NOT_RUN', out)
        self.assertEqual(err, '')
        expected = receipt()
        expected['sourceProvenance'] = self.provenance
        self.assertEqual(json.loads(self.output.read_text()), expected)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertFalse(self.config_path.exists())
        self.assertFalse(self.receipt_path.exists())
        self.assertNotIn(SECRET, out + err + self.output.read_text())

    def test_candidate_not_final(self):
        with mock.patch.object(runner.subprocess, 'Popen', side_effect=self.child(returned=receipt('candidate'))):
            code, _, _ = self.invoke(self.args + ['--policy', 'candidate'])
        self.assertEqual(code, 0)
        result = json.loads(self.output.read_text())
        self.assertTrue(runner.validate_receipt(result))
        self.assertFalse(runner.validate_receipt(result, final=True))
        self.assertFalse(runner.validate_receipt(receipt(), final=True))
        self.assertFalse(runner.validate_receipt(receipt('candidate', finalEligible=True)))
        self.assertFalse(runner.validate_receipt(receipt('candidate', evidenceClass='SYNTHETIC')))

    def test_live_rejected_without_credentials_or_child(self):
        with mock.patch.object(runner.subprocess, 'Popen') as run, \
             mock.patch.object(runner.getpass, 'getpass') as prompt:
            code, out, err = self.invoke(self.args + ['--transport', 'live'])
        self.assertEqual(code, 2)
        self.assertIn('NOT_RUN', err)
        self.assertEqual(out, '')
        run.assert_not_called()
        prompt.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_verified_noop_requires_independent_parent_state_evidence(self):
        row = {'classification': 'verifiedNoOp', 'operation': 'setStar',
               'mutationCount': 1, 'observerRequests': 3, 'parentStateVerified': True,
               'readback': 'PASS', 'status': 'PASS', 'outcome': 'noChange',
               'coreOutcome': 'succeeded', 'coreNoChange': False, 'responseStatus': 304}
        self.assertTrue(runner.validate_receipt(receipt(scenarios=[row])))
        for changes in ({'parentStateVerified': False}, {'observerRequests': 0},
                        {'mutationCount': 0}, {'mutationCount': 2}, {'mutationCount': True},
                        {'responseStatus': 302}, {'operation': 'createIssue'},
                        {'coreOutcome': 'writeUncertain'}, {'readback': 'NOT_VERIFIED'}):
            with self.subTest(changes=changes):
                self.assertFalse(runner.validate_receipt(receipt(scenarios=[{**row, **changes}])))
        conflict = {**row, 'operation': 'cancelAutoMerge', 'responseStatus': 409, 'coreNoChange': True}
        self.assertTrue(runner.validate_receipt(receipt(scenarios=[conflict])))
        self.assertFalse(runner.validate_receipt(receipt(scenarios=[{**conflict, 'coreNoChange': False}])))
        self.assertFalse(runner.validate_receipt(receipt(scenarios=[conflict]), final=True))

    def test_forged_verified_noop_child_receipt_quarantines(self):
        forged = receipt(scenarios=[{'classification': 'verifiedNoOp', 'responseStatus': 304}])
        with mock.patch.object(runner.subprocess, 'Popen', side_effect=self.child(returned=forged)):
            code, _, _ = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(self.output.read_text())['reason'], 'invalid_or_missing_receipt')

    def test_rejected_secret_argument_is_not_echoed(self):
        code, out, err = self.invoke(self.args + ['--token', SECRET])
        self.assertEqual(code, 2)
        self.assertNotIn(SECRET, out + err)
        self.assertFalse(self.output.exists())

    def test_untrusted_or_missing_receipt_quarantines(self):
        cases = [None, receipt(policy='candidate'), receipt(releaseSha='b' * 40),
                 receipt(status='PASS', details=SECRET)]
        for index, child_receipt in enumerate(cases):
            with self.subTest(case=index):
                output = Path(self.temp.name) / f'out{index}.json'
                args = ['--output', str(output), '--expect-release-sha', SHA]
                with mock.patch.dict(os.environ, {'FAKE_API_KEY': SECRET}), \
                     mock.patch.object(runner.subprocess, 'Popen', side_effect=self.child(returned=child_receipt)):
                    code, out, err = self.invoke(args)
                self.assertEqual(code, 1)
                data = json.loads(output.read_text())
                self.assertEqual(data['status'], 'FAIL')
                self.assertEqual(data['cleanup'], 'NOT_RUN')
                self.assertEqual(data['sandbox'], 'quarantined')
                self.assertNotIn(SECRET, out + err + output.read_text())

    def test_failed_or_interrupted_process_quarantines(self):
        for name, interrupted, returncode, expected in [('fail', False, 7, 1), ('interrupt', True, 0, 130)]:
            output = Path(self.temp.name) / f'{name}.json'
            with self.subTest(name=name), mock.patch.object(os, 'killpg'), mock.patch.object(
                    runner.subprocess, 'Popen', side_effect=self.child(returned=receipt(),
                                                                      returncode=returncode,
                                                                      interrupted=interrupted)):
                code, _, _ = self.invoke(['--output', str(output), '--expect-release-sha', SHA])
            self.assertEqual(code, expected)
            result = json.loads(output.read_text())
            self.assertEqual(result['remaining'], 'NOT_RUN')
            self.assertEqual(result['cleanup'], 'NOT_RUN')
            self.assertFalse(self.config_path.exists())
            self.assertFalse(self.receipt_path.exists())

    def test_mismatched_sha_fails_before_child_start(self):
        with mock.patch.object(runner.subprocess, 'Popen') as child:
            code, _, _ = self.invoke(['--output', str(self.output), '--expect-release-sha', 'b' * 40])
        self.assertEqual(code, 2)
        child.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_existing_output_not_overwritten_and_child_not_started(self):
        self.output.write_text('existing')
        with mock.patch.object(runner.subprocess, 'Popen') as child:
            code, _, _ = self.invoke()
        self.assertEqual(code, 2)
        self.assertEqual(self.output.read_text(), 'existing')
        child.assert_not_called()

    def test_child_failure_details_are_preserved_on_nonzero_exit(self):
        failed = receipt(status='FAIL', reason='noScenarios', scenarios=[{'status': 'NOT_RUN'}])
        with mock.patch.object(runner.subprocess, 'Popen',
                               side_effect=self.child(returned=failed, returncode=1)):
            code, _, _ = self.invoke()
        self.assertEqual(code, 1)
        actual = json.loads(self.output.read_text())
        self.assertEqual(actual['reason'], 'noScenarios')
        self.assertEqual(actual['scenarios'], [{'status': 'NOT_RUN'}])
        self.assertEqual(actual['sourceProvenance'], self.provenance)

    def test_provisional_exists_before_child_and_modified_output_is_preserved(self):
        def inspect(config, env):
            provisional = json.loads(self.output.read_text())
            self.assertEqual(provisional['reason'], 'in_progress')
            self.assertEqual(provisional['cleanup'], 'NOT_RUN')
            self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
            self.output.write_text('external edit')
        with mock.patch.object(runner.subprocess, 'Popen',
                               side_effect=self.child(returned=receipt(), inspect=inspect)):
            code, _, _ = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.output.read_text(), 'external edit')

    def test_source_provenance_hashes_submitted_files_and_lock(self):
        current = actual_source_provenance()
        self.assertTrue(set(runner.SOURCE_FILES + runner.DEPENDENCY_FILES).issubset(current['files']))
        dart_files = {path.relative_to(ROOT).as_posix() for path in (ROOT / 'lib').rglob('*.dart') if path.is_file()}
        self.assertTrue(dart_files.issubset(current['files']))
        for name in ('tool/run_mr7_sandbox.py', 'tool/tests/test_mr7_sandbox_runner.py', 'pubspec.lock'):
            self.assertEqual(current['files'][name]['sha256'],
                             hashlib.sha256((ROOT / name).read_bytes()).hexdigest())
        self.assertEqual(len(current['files']['tool/run_mr7_sandbox.py']['gitStatus']), 2)
        self.assertEqual(current['dirty'], any(item['gitStatus'] != '  ' for item in current['files'].values()))

    def test_head_and_source_drift_quarantine(self):
        changed = {'dirty': True, 'files': {}}
        for label, heads, sources in [
            ('head', [SHA, 'c' * 40], [self.source_provenance, self.source_provenance]),
            ('files', [SHA, SHA], [self.source_provenance, changed]),
        ]:
            output = Path(self.temp.name) / f'{label}-drift.json'
            with self.subTest(label=label), \
                    mock.patch.object(runner, '_head_sha', side_effect=heads), \
                    mock.patch.object(runner, '_source_provenance', side_effect=sources), \
                    mock.patch.object(runner.subprocess, 'Popen', side_effect=self.child(returned=receipt())):
                code, _, _ = self.invoke(['--output', str(output), '--expect-release-sha', SHA])
            self.assertEqual(code, 1)
            result = json.loads(output.read_text())
            self.assertEqual(result['reason'], 'source_drift')
            self.assertEqual(result['sourceProvenance'], self.provenance)

    def test_real_production_and_dependency_source_edits_stop_run(self):
        scenarios = [
            ('production_edit', 'lib/core/example.dart', 'edit'),
            ('production_add', 'lib/core/new.dart', 'add'),
            ('production_delete', 'lib/core/example.dart', 'delete'),
            ('candidate_edit', 'tool/mr7/candidate_release_policy.dart', 'edit'),
            ('config_edit', '.dart_tool/package_config.json', 'edit'),
        ]
        for label, relative, action in scenarios:
            with self.subTest(label=label):
                fake_root = Path(self.temp.name) / label
                target = fake_root / relative
                target.parent.mkdir(parents=True)
                if action != 'add':
                    target.write_text('before')
                output = fake_root / 'receipt.json'

                def change(config, env):
                    if action == 'delete':
                        target.unlink()
                    else:
                        target.write_text('after')

                fake_git = subprocess.CompletedProcess(['git'], 0, stdout='')
                with mock.patch.object(runner, 'ROOT', fake_root), \
                        mock.patch.object(runner, '_source_provenance', side_effect=actual_source_provenance), \
                        mock.patch.object(runner.subprocess, 'run', return_value=fake_git), \
                        mock.patch.object(runner.subprocess, 'Popen',
                                          side_effect=self.child(returned=receipt(), inspect=change)):
                    code, _, _ = self.invoke(['--output', str(output), '--expect-release-sha', SHA])
                self.assertEqual(code, 1)
                result = json.loads(output.read_text())
                self.assertEqual(result['reason'], 'source_drift')
                self.assertEqual(result['cleanup'], 'NOT_RUN')

    def test_sigterm_kills_descendant_even_when_leader_exits(self):
        fake_fvm = Path(self.temp.name) / 'fvm'
        descendant_code = (
            "import os,signal,time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "open(os.path.join(os.environ['HOME'], 'descendant-pid'), 'w').write(str(os.getpid()))\n"
            "time.sleep(60)\n"
        )
        fake_fvm.write_text(
            f'#!{sys.executable}\nimport os,subprocess,sys,time\n'
            "open(os.path.join(os.environ['HOME'], 'leader-pid'), 'w').write(str(os.getpid()))\n"
            f'subprocess.Popen([sys.executable, "-c", {descendant_code!r}])\n'
            'time.sleep(60)\n'
        )
        fake_fvm.chmod(0o700)
        output = Path(self.temp.name) / 'descendant-signal.json'
        leader_file = Path(self.temp.name) / 'leader-pid'
        descendant_file = Path(self.temp.name) / 'descendant-pid'
        env = os.environ.copy()
        env['PATH'] = self.temp.name + os.pathsep + env.get('PATH', '')
        env['HOME'] = self.temp.name
        proc = subprocess.Popen([sys.executable, str(ROOT / 'tool/run_mr7_sandbox.py'),
                                 '--output', str(output)], cwd=ROOT, env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        leader = descendant = None
        try:
            deadline = time.monotonic() + 10
            while not descendant_file.exists() and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(descendant_file.exists(), 'TERM-ignoring descendant did not start')
            leader = int(leader_file.read_text())
            descendant = int(descendant_file.read_text())
            proc.send_signal(signal.SIGTERM)
            self.assertEqual(proc.wait(timeout=10), 130)
            self.assertEqual(json.loads(output.read_text())['reason'], 'interrupted')
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                state = subprocess.run(['ps', '-o', 'stat=', '-p', str(descendant)],
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       text=True, check=False).stdout.strip()
                if not state or state.startswith('Z'):
                    break
                time.sleep(0.02)
            self.assertTrue(not state or state.startswith('Z'), f'descendant survived: {state}')
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            if leader is not None:
                try:
                    os.killpg(leader, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_real_sigterm_and_sigkill_leave_quarantine(self):
        fake_fvm = Path(self.temp.name) / 'fvm'
        fake_fvm.write_text(f'#!{sys.executable}\nimport os,time\n'
                            "open(os.path.join(os.environ['HOME'], 'child-pid'), 'w').write(str(os.getpid()))\n"
                            'time.sleep(60)\n')
        fake_fvm.chmod(0o700)
        for signal_number in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=signal_number):
                output = Path(self.temp.name) / f'signal-{signal_number}.json'
                marker = Path(self.temp.name) / 'child-pid'
                marker.unlink(missing_ok=True)
                env = os.environ.copy()
                env['PATH'] = self.temp.name + os.pathsep + env.get('PATH', '')
                env['HOME'] = self.temp.name
                proc = subprocess.Popen([sys.executable, str(ROOT / 'tool/run_mr7_sandbox.py'),
                                         '--output', str(output)], cwd=ROOT, env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                pid = None
                try:
                    deadline = time.monotonic() + 10
                    while not marker.exists() and proc.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(marker.exists(), 'synthetic child did not start')
                    pid = int(marker.read_text())
                    self.assertEqual(json.loads(output.read_text())['reason'], 'in_progress')
                    proc.send_signal(signal_number)
                    proc.wait(timeout=10)
                    result = json.loads(output.read_text())
                    self.assertEqual(result['status'], 'FAIL')
                    self.assertEqual(result['cleanup'], 'NOT_RUN')
                    self.assertEqual(result['sandbox'], 'quarantined')
                    self.assertEqual(result['reason'], 'interrupted' if signal_number == signal.SIGTERM else 'in_progress')
                    self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
                    if signal_number == signal.SIGTERM:
                        with self.assertRaises(ProcessLookupError):
                            os.kill(pid, 0)
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait(timeout=5)
                    if pid is not None:
                        try:
                            os.killpg(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_provider_config_uses_only_nonsecret_metadata(self):
        config = {'endpoint': 'https://provider.example/v1', 'format': 'responses',
                  'model': 'synthetic-model', 'caps': {'tools': True, 'maxTokens': 1000},
                  'maxCost': 1.5, 'maxCalls': 3, 'keyEnv': 'TEST_PROVIDER_KEY'}
        path = Path(self.temp.name) / 'provider.json'
        path.write_text(json.dumps(config))
        self.assertEqual(runner.provider_config(str(path)), config)
        for change in ({'apiKey': SECRET}, {'endpoint': 'https://user:password@provider.example/v1'},
                       {'endpoint': 'https://provider.example/v1?key=private'},
                       {'caps': {'secret': SECRET}}, {'maxCalls': True}, {'maxCost': -1}):
            bad = config.copy()
            bad.update(change)
            path.write_text(json.dumps(bad))
            with self.subTest(change=change), self.assertRaises(ValueError):
                runner.provider_config(str(path))

    def test_credential_helper_uses_private_files_and_removes_them(self):
        with mock.patch.dict(os.environ, {'TEST_PAT': SECRET, 'TEST_KEY': 'other-secret-123'}):
            with runner.credential_files(pat_env='TEST_PAT', key_env='TEST_KEY') as (pat, key):
                self.assertEqual(pat.read_text(), SECRET)
                self.assertEqual(key.read_text(), 'other-secret-123')
                self.assertEqual(stat.S_IMODE(pat.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
            self.assertFalse(pat.exists())
            self.assertFalse(key.exists())


if __name__ == '__main__':
    unittest.main()
