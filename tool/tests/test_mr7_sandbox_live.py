import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
from datetime import datetime, timedelta, timezone
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import warnings

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mr7_live_wrapper', ROOT / 'tool/run_mr7_sandbox.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
SHA = 'a' * 40
PAT = 'fake-pat-123456789'
KEY = 'fake-provider-key-123456789'


class LiveWrapperTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mr7-wrapper-test-', dir=ROOT.parent)
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.output = self.directory / 'receipt.json'
        self.config = {'endpoint': 'https://example.invalid/v1', 'format': 'chat_completions',
                       'model': 'fixture', 'caps': {'tools': True, 'maxTokens': 512},
                       'maxCost': 1.0, 'maxCalls': 3, 'keyEnv': 'FAKE_PROVIDER',
                       'priceInputPerMTok': 2, 'priceOutputPerMTok': 3}
        self.config_path = self.directory / 'provider.json'
        self.config_path.write_text(json.dumps(self.config))
        self.args = ['--transport', 'live', '--suite', 'rest', '--only', 'b0-star',
                     '--provider-config', str(self.config_path), '--pat-env', 'FAKE_PAT',
                     '--output', str(self.output)]
        self.env = {'MR7_EXPECTED_USER_ID': '7', 'MR7_OWNER_NAMESPACE': 'owner',
                    'FAKE_PAT': PAT, 'FAKE_PROVIDER': KEY}
        self.patchers = [mock.patch.dict(os.environ, self.env, clear=True),
                         mock.patch.object(runner, '_head_sha', return_value=SHA),
                         mock.patch.object(runner, '_source_provenance', return_value={'dirty': False, 'files': {}})]
        for p in self.patchers:
            p.start()
            self.addCleanup(p.stop)

    def invoke(self, args=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = runner.main(self.args if args is None else args)
            except SystemExit as exc:
                code = exc.code
        return code, out.getvalue(), err.getvalue()

    def receipt(self):
        return {'schema': 1, 'status': 'PASS', 'transport': 'live', 'policy': 'production',
                'evidenceClass': 'live-candidate', 'finalEligible': False,
                'releaseSha': SHA, 'live': 'PASS', 'quarantined': False, 'secretLeakScan': 'PASS',
                'identity': {'projectId': 9, 'ownerId': 7, 'namespaceId': 70,
                             'pathDigest': 'a' * 64, 'instanceDigest': 'b' * 64,
                             'nonceDigest': 'c' * 64},
                'events': {'status': 'PASS', 'complete': True, 'passes': 2, 'pages': 2,
                           'start': '2026-01-01T00:00:00Z', 'end': '2026-01-01T00:01:00Z', 'items': []},
                'cleanup': {'status': 'PASS', 'accepted': True, 'deletionVerified': True,
                            'parentChecked': True, 'identityChecked': True},
                'requestLedger': [{'operation': 'harnessSetup', 'method': 'POST', 'path': 'projects'},
                                  {'operation': 'harnessCleanup', 'method': 'DELETE', 'path': 'projects/9'}],
                'provider': {'calls': 1, 'usage': [{'inputTokens': 100, 'outputTokens': 50,
                                                    'spend': 0.00035, 'usageEstimated': 0}],
                             'spend': 0.00035},
                'scenarios': [{'id': 'b0-star', 'status': 'PASS', 'live': 'PASS', 'mutationCount': 1,
                               'confirmation': 'explicitOwnerConfirmation', 'observerRequests': 1,
                               'readback': 'PASS'}]}

    def test_prerequisites_reject_before_credentials(self):
        for missing in ('MR7_EXPECTED_USER_ID', 'MR7_OWNER_NAMESPACE'):
            with self.subTest(missing=missing), mock.patch.dict(os.environ, {missing: ''}):
                del os.environ[missing]
                with mock.patch.object(runner, 'credential_files') as credentials:
                    code, _, _ = self.invoke()
                    self.assertEqual(code, 2)
                    credentials.assert_not_called()
        for removed in ('--suite', '--provider-config'):
            args = list(self.args)
            index = args.index(removed)
            del args[index:index + 2]
            with self.subTest(removed=removed), mock.patch.object(runner, 'credential_files') as credentials:
                code, _, _ = self.invoke(args)
                self.assertEqual(code, 2)
                credentials.assert_not_called()

    def test_live_config_prices_capabilities_and_selection(self):
        self.assertEqual(runner.provider_config(str(self.config_path), live=True), self.config)
        bad_configs = [dict(self.config, priceInputPerMTok=value) for value in (0, -1, True, float('nan'))]
        bad_configs += [dict(self.config, priceOutputPerMTok=0), dict(self.config, format='responses'),
                        dict(self.config, caps={'tools': True, 'maxTokens': 0}),
                        dict(self.config, caps={'tools': True, 'maxTokens': 511}),
                        dict(self.config, caps={'tools': True, 'maxTokens': 1_000_001}),
                        dict(self.config, caps={'tools': False, 'maxTokens': 512}),
                        dict(self.config, caps={'tools': True, 'maxTokens': 512, 'unknown': True}),
                        dict(self.config, format='anthropic_messages', preset='opencode-go')]
        for value in bad_configs:
            self.config_path.write_text(json.dumps(value))
            with self.subTest(value=value), self.assertRaises(ValueError):
                runner.provider_config(str(self.config_path), live=True)
        self.config_path.write_text(json.dumps(self.config))
        for selection in ('', 'b0-star,', 'b0-star,b0-star', '../no'):
            args = self.args.copy()
            args[args.index('--only') + 1] = selection
            with self.subTest(selection=selection), mock.patch.object(runner, 'credential_files') as credentials:
                self.assertEqual(self.invoke(args)[0], 2)
                credentials.assert_not_called()

    def test_shell_free_handoff_and_confirmation(self):
        def spawn(command, **kwargs):
            self.assertEqual(command[-1], 'tool/mr7_sandbox.dart')
            self.assertFalse(kwargs.get('shell', False))
            self.assertIs(kwargs['stdout'], subprocess.DEVNULL)
            self.assertIs(kwargs['stderr'], subprocess.DEVNULL)
            env = kwargs['env']
            self.assertNotIn(PAT, str(command) + str(env))
            self.assertNotIn(KEY, str(command) + str(env))
            self.assertNotIn('FAKE_PAT', env)
            self.assertNotIn('FAKE_PROVIDER', env)
            self.assertEqual(Path(env['MR7_GITLAB_PAT_FILE']).read_text(), PAT)
            self.assertEqual(Path(env['MR7_PROVIDER_KEY_FILE']).read_text(), KEY)
            self.assertEqual(stat.S_IMODE(Path(env['MR7_GITLAB_PAT_FILE']).stat().st_mode), 0o600)
            config = json.loads(Path(env['MR7_SANDBOX_CONFIG_FILE']).read_text())
            self.assertEqual(config['only'], ['b0-star'])
            self.assertEqual(config['transport'], 'live')
            state = Path(config['stateDirectory'])
            self.assertEqual(state.parent, self.directory)
            self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o700)
            self.assertEqual(json.loads(self.output.read_text())['stateDirectory'], str(state))
            persisted = json.loads((state / 'run.json').read_text())
            self.assertIn('nonce', persisted)
            self.assertIn('projectPath', persisted)
            self.assertEqual(persisted['nonce'], config['nonce'])
            self.assertEqual(persisted['projectPath'], config['projectPath'])
            self.assertEqual(persisted['projectPath'], f"owner/mr7-{config['nonce']}")
            self.assertEqual(stat.S_IMODE((state / 'run.json').stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE((state / 'journal-key.json').stat().st_mode), 0o600)
            journal_key = json.loads((state / 'journal-key.json').read_text())['key']
            self.assertNotIn(journal_key, str(command) + str(env) + self.output.read_text())
            Path(env['MR7_SANDBOX_RECEIPT_FILE']).write_text(json.dumps(self.receipt()))
            Path(env['MR7_CONFIRM_REQUEST_FILE']).write_text(json.dumps({
                'operation': 'setStar', 'tier': 'T1', 'projectId': 9,
                'payloadDigest': 'a' * 64, 'preview': 'Star the synthetic sandbox.'}))
            class Process:
                pid = 9999999
                def poll(self):
                    return None
                def wait(self, timeout=None):
                    answer = json.loads(Path(env['MR7_CONFIRM_RESPONSE_FILE']).read_text())
                    self_outer.assertEqual(answer, {'approved': True})
                    return 0
            self_outer = self
            return Process()
        with mock.patch.object(runner.subprocess, 'Popen', side_effect=spawn), \
             mock.patch.object(runner, '_hidden_input', return_value='yes') as prompt:
            code, out, err = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(prompt.call_count, 1)
        self.assertNotIn(PAT, out + err + self.output.read_text())
        self.assertNotIn(KEY, out + err + self.output.read_text())
        saved = json.loads(self.output.read_text())
        self.assertFalse(Path(saved['stateDirectory']).exists())
        self.assertNotIn(saved['stateDirectory'], out + err)
        self.assertTrue(runner.validate_receipt(saved, transport='live'))
        self.assertFalse(runner.validate_receipt(saved, transport='live', final=True))

    def test_malformed_confirmation_never_prompts(self):
        request = self.directory / 'request'
        response = self.directory / 'response'
        request.write_text(json.dumps({'operation': PAT, 'tier': 'T1', 'projectId': 9,
                                       'payloadDigest': 'a' * 64, 'preview': 'synthetic'}))
        with mock.patch.object(runner.getpass, 'getpass') as prompt:
            with self.assertRaises(ValueError):
                runner._confirm_request(request, response, [PAT, KEY])
            prompt.assert_not_called()
        self.assertFalse(response.exists())

    def test_bounded_preview_and_explicit_typed_target(self):
        request = self.directory / 'request'
        response = self.directory / 'response'
        proposal = {'operation': 'deleteProject', 'tier': 'hardLine', 'projectId': 9,
                    'payloadDigest': 'a' * 64, 'preview': 'Delete synthetic sandbox',
                    'requiredTypedName': 'mr7-fixture'}
        request.write_text(json.dumps(proposal))
        with mock.patch.object(runner.getpass, 'getpass', side_effect=['yes', 'mr7-fixture']) as prompt:
            runner._confirm_request(request, response, [PAT, KEY])
        self.assertEqual(prompt.call_count, 2)
        self.assertEqual(json.loads(response.read_text()), {'approved': True, 'typedName': 'mr7-fixture'})
        response.unlink()
        for preview in ('x' * 2049, 'bad\x1bcontrol', 'bad\u009bcontrol', PAT):
            request.write_text(json.dumps({**proposal, 'preview': preview}))
            with self.subTest(preview=preview), mock.patch.object(runner.getpass, 'getpass') as prompt:
                with self.assertRaises(ValueError):
                    runner._confirm_request(request, response, [PAT, KEY])
                prompt.assert_not_called()
            self.assertFalse(response.exists())

    def test_confirmation_publication_is_complete_and_exclusive(self):
        response = self.directory / 'response'
        original_link = os.link
        def verify_before_publish(source, target):
            self.assertFalse(Path(target).exists())
            self.assertEqual(json.loads(Path(source).read_text()), {'approved': True})
            self.assertEqual(stat.S_IMODE(Path(source).stat().st_mode), 0o600)
            original_link(source, target)
        with mock.patch.object(runner.os, 'link', side_effect=verify_before_publish):
            runner._publish_confirmation(response, json.dumps({'approved': True}))
        self.assertEqual(json.loads(response.read_text()), {'approved': True})
        with self.assertRaises(FileExistsError):
            runner._publish_confirmation(response, json.dumps({'approved': False}))
        self.assertEqual(json.loads(response.read_text()), {'approved': True})
        self.assertFalse(list(self.directory.glob('.mr7-confirm-*')))

    def test_cancellation_after_input_never_publishes_confirmation(self):
        request = self.directory / 'request'
        response = self.directory / 'response'
        proposal = {'operation': 'setStar', 'tier': 'T1', 'projectId': 9,
                    'payloadDigest': 'a' * 64, 'preview': 'Synthetic sandbox only.'}
        for reason in ('child_exit', 'withdrawn', 'deadline'):
            request.write_text(json.dumps(proposal))
            response.unlink(missing_ok=True)
            exited = False
            def answer(*args, **kwargs):
                nonlocal exited
                if reason == 'child_exit':
                    exited = True
                if reason == 'withdrawn':
                    request.unlink()
                return 'yes'
            deadline = (datetime.now(timezone.utc) - timedelta(seconds=1)
                        if reason == 'deadline' else None)
            with self.subTest(reason=reason), mock.patch.object(runner, '_hidden_input', side_effect=answer):
                with self.assertRaises(runner._ConfirmationCancelled):
                    runner._confirm_request(request, response, [],
                                            cancelled=lambda: exited or not request.exists(),
                                            deadline=deadline)
                self.assertFalse(response.exists())

    def test_receipt_secrets_are_quarantined_including_escaped_strings(self):
        secret = 'fake-quote-"-key-123456'
        os.environ['FAKE_PROVIDER'] = secret
        def spawn(command, **kwargs):
            env = kwargs['env']
            receipt = self.receipt()
            receipt['scenarios'][0]['leak'] = secret
            Path(env['MR7_SANDBOX_RECEIPT_FILE']).write_text(json.dumps(receipt))
            class Process:
                pid = 9999999
                def wait(self, timeout=None):
                    return 0
            return Process()
        with mock.patch.object(runner.subprocess, 'Popen', side_effect=spawn), \
             mock.patch.object(runner, '_stop_child'):
            code, out, err = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(self.output.read_text())['reason'], 'invalid_or_missing_receipt')
        self.assertNotIn(secret, out + err + self.output.read_text())

    def test_interruption_preserves_quarantine(self):
        class Process:
            pid = 9999999
            def wait(self, timeout=None):
                raise KeyboardInterrupt()
        def spawn(command, **kwargs):
            config = json.loads(Path(kwargs['env']['MR7_SANDBOX_CONFIG_FILE']).read_text())
            state = Path(config['stateDirectory'])
            (state / 'uncertain-journal').write_text('synthetic journal marker')
            return Process()
        with mock.patch.object(runner.subprocess, 'Popen', side_effect=spawn), \
             mock.patch.object(runner, '_stop_child') as stop:
            code, out, err = self.invoke()
        self.assertEqual(code, 130)
        self.assertTrue(stop.called)
        result = json.loads(self.output.read_text())
        self.assertEqual(result['reason'], 'interrupted')
        self.assertEqual(result['cleanup'], 'NOT_RUN')
        self.assertEqual(result['sandbox'], 'quarantined')
        self.assertEqual((Path(result['stateDirectory']) / 'uncertain-journal').read_text(),
                         'synthetic journal marker')
        self.assertNotIn(result['stateDirectory'], out + err)
        self.assertNotIn(PAT, out + err + self.output.read_text())
        self.assertNotIn(KEY, out + err + self.output.read_text())

    def test_parent_deadline_allows_child_stateful_stop_grace(self):
        deadline = datetime.now(timezone.utc) - timedelta(seconds=1)
        child = mock.Mock()
        child.wait.return_value = 1
        self.assertEqual(runner._wait_live_child(
            child, self.directory / 'request', self.directory / 'response',
            [], deadline=deadline), 1)
        child.wait.assert_called_once()

    def test_parent_deadline_stops_stuck_child_after_grace(self):
        deadline = datetime.now(timezone.utc) - timedelta(seconds=31)
        child = mock.Mock()
        with self.assertRaises(runner._LiveTimedOut):
            runner._wait_live_child(child, self.directory / 'request',
                                    self.directory / 'response', [], deadline=deadline)
        child.wait.assert_not_called()

    def test_receipt_requires_matching_live_evidence(self):
        result = self.receipt()
        self.assertTrue(runner.validate_receipt(result, transport='live'))
        self.assertFalse(runner.validate_receipt(result))
        for field, value in [('evidenceClass', 'SYNTHETIC'), ('finalEligible', True),
                             ('releaseSha', 'invalid'), ('live', 'NOT_RUN')]:
            self.assertFalse(runner.validate_receipt({**result, field: value}, transport='live'))
        result['scenarios'][0]['live'] = 'NOT_VERIFIED'
        self.assertFalse(runner.validate_receipt(result, transport='live'))

    def test_pass_requires_complete_sandbox_evidence(self):
        missing = {'schema': 1, 'status': 'PASS', 'transport': 'live', 'policy': 'production',
                   'evidenceClass': 'live-candidate', 'finalEligible': False, 'releaseSha': SHA,
                   'live': 'PASS', 'scenarios': []}
        self.assertFalse(runner.validate_receipt(missing, transport='live'))
        for field in ('identity', 'events', 'cleanup', 'quarantined', 'secretLeakScan',
                      'requestLedger', 'provider', 'scenarios'):
            result = self.receipt()
            del result[field]
            with self.subTest(field=field):
                self.assertFalse(runner.validate_receipt(result, transport='live'))
        for field, value in [('confirmation', 'rejected'), ('observerRequests', 0),
                             ('readback', 'NOT_VERIFIED')]:
            result = self.receipt()
            result['scenarios'][0][field] = value
            with self.subTest(field=field):
                self.assertFalse(runner.validate_receipt(result, transport='live'))
        result = self.receipt()
        result['provider']['usage'][0]['spend'] = float('nan')
        self.assertFalse(runner.validate_receipt(result, transport='live'))
        result = self.receipt()
        result['events']['items'] = [{'id': 1, 'at': '2026-01-01T00:00:30Z',
                                     'action': 'created', 'projectId': 10}]
        self.assertFalse(runner.validate_receipt(result, transport='live'))

    def test_scheduled_deletion_is_terminal_live_cleanup(self):
        # gitlab.com keeps a deleted project for 30 days under a renamed path.
        scheduled = {'status': 'scheduledForDeletion', 'accepted': True, 'deletionVerified': False,
                     'markedForDeletionOn': '2026-10-29', 'parentChecked': True,
                     'identityChecked': True}
        result = self.receipt()
        result['cleanup'] = dict(scheduled)
        self.assertTrue(runner.validate_receipt(result, transport='live'))
        for changes in ({'deletionVerified': True}, {'markedForDeletionOn': None},
                        {'markedForDeletionOn': ''}, {'markedForDeletionOn': '2026-13-40'},
                        {'markedForDeletionOn': '2026-10-29T00:00:00Z'},
                        {'markedForDeletionOn': 20261029}, {'accepted': False},
                        {'status': 'PENDING'}, {'status': 'NOT_VERIFIED'},
                        {'parentChecked': False}, {'identityChecked': False}):
            result = self.receipt()
            result['cleanup'] = {**scheduled, **changes}
            with self.subTest(changes=changes):
                self.assertFalse(runner.validate_receipt(result, transport='live'))
        result = self.receipt()
        result['cleanup'] = {key: value for key, value in scheduled.items()
                             if key != 'markedForDeletionOn'}
        self.assertFalse(runner.validate_receipt(result, transport='live'))
        # A hard delete must not also claim a scheduled date.
        result = self.receipt()
        result['cleanup']['markedForDeletionOn'] = '2026-10-29'
        self.assertFalse(runner.validate_receipt(result, transport='live'))
        result = self.receipt()
        result['cleanup']['deletionVerified'] = False
        self.assertFalse(runner.validate_receipt(result, transport='live'))

    def test_rate_limited_live_receipt_is_a_valid_failure(self):
        result = self.receipt()
        result.update(status='FAIL', live='FAIL', quarantined=True, stopReason='rateLimited',
                      rateLimit={'status': 429, 'retryAfter': 60, 'limit': 100})
        result['cleanup'] = {'status': 'NOT_RUN', 'accepted': False, 'deletionVerified': False}
        result['scenarios'][0].update(status='NOT_RUN', live='NOT_VERIFIED')
        self.assertTrue(runner.validate_receipt(result, transport='live'))
        result.update(status='PASS', live='PASS')
        self.assertFalse(runner.validate_receipt(result, transport='live'))

    def test_rate_limit_is_numeric_and_only_on_a_rate_limited_stop(self):
        def failed(**changes):
            result = self.receipt()
            result.update(status='FAIL', live='FAIL', quarantined=True, stopReason='rateLimited',
                          rateLimit={'status': 429, 'retryAfter': 60, 'limit': 100, 'observed': 101,
                                     'remaining': 0, 'reset': 1761740000})
            result['cleanup'] = {'status': 'NOT_RUN', 'accepted': False, 'deletionVerified': False}
            result['scenarios'][0].update(status='NOT_RUN', live='NOT_VERIFIED')
            result.update(changes)
            return result

        self.assertTrue(runner.validate_receipt(failed(), transport='live'))
        self.assertTrue(runner.validate_receipt(failed(rateLimit={'status': 429}), transport='live'))
        # A complete PASS receipt is otherwise valid; a rate limit contradicts it.
        passed = self.receipt()
        self.assertTrue(runner.validate_receipt(passed, transport='live'))
        passed['rateLimit'] = {'status': 429, 'retryAfter': 60}
        self.assertFalse(runner.validate_receipt(passed, transport='live'))
        for changes in ({'stopReason': 'sandboxIdentity'}, {'stopReason': None},
                        {'rateLimit': None}, {'rateLimit': []}, {'rateLimit': {}},
                        {'rateLimit': {'retryAfter': 60}},
                        {'rateLimit': {'status': 200, 'retryAfter': 60}},
                        {'rateLimit': {'status': '429'}},
                        {'rateLimit': {'status': 429, 'retryAfter': '60'}},
                        {'rateLimit': {'status': 429, 'retryAfter': 60.0}},
                        {'rateLimit': {'status': 429, 'retryAfter': True}},
                        {'rateLimit': {'status': 429, 'remaining': -1}},
                        {'rateLimit': {'status': 429, 'reset': 10 ** 15}},
                        {'rateLimit': {'status': 429, 'name': 'burst_traffic_per_user_free_plan'}},
                        {'rateLimit': {'status': 429, 'resetTime': 'Thu, 29 Oct 2026 12:13:20 GMT'}}):
            with self.subTest(changes=changes):
                self.assertFalse(runner.validate_receipt(failed(**changes), transport='live'))
        no_stop = failed()
        del no_stop['stopReason']
        self.assertFalse(runner.validate_receipt(no_stop, transport='live'))

    def test_overall_pass_rejects_fail_rows_in_both_transports(self):
        for transport in ('live', 'synthetic'):
            result = self.receipt()
            if transport == 'synthetic':
                result.update(transport='synthetic', evidenceClass='SYNTHETIC', live='NOT_RUN')
                result['scenarios'][0]['live'] = 'NOT_RUN'
            self.assertTrue(runner.validate_receipt(result, transport=transport))
            result['scenarios'].append({'id': 'other', 'status': 'FAIL',
                                        'live': 'FAIL' if transport == 'live' else 'NOT_RUN',
                                        'mutationCount': 0})
            with self.subTest(transport=transport):
                self.assertFalse(runner.validate_receipt(result, transport=transport))
                result.update(status='FAIL', live='FAIL' if transport == 'live' else 'NOT_RUN')
                self.assertTrue(runner.validate_receipt(result, transport=transport))

    def test_overall_pass_rejects_unverified_or_uncertain_rows_in_both_transports(self):
        for transport in ('live', 'synthetic'):
            for changes in ({'status': 'NOT_VERIFIED'}, {'status': 'writeUncertain'},
                            {'readback': 'FAIL'}, {'readback': 'NOT_VERIFIED'},
                            {'outcome': 'writeUncertain'}, {'coreOutcome': 'writeUncertain'}):
                result = self.receipt()
                if transport == 'synthetic':
                    result.update(transport='synthetic', evidenceClass='SYNTHETIC', live='NOT_RUN')
                    result['scenarios'][0]['live'] = 'NOT_RUN'
                row = {'id': 'other', 'status': 'NOT_RUN', 'mutationCount': 0, **changes}
                row['live'] = 'NOT_VERIFIED' if transport == 'live' else 'NOT_RUN'
                result['scenarios'].append(row)
                with self.subTest(transport=transport, changes=changes):
                    self.assertFalse(runner.validate_receipt(result, transport=transport))
                    result.update(status='FAIL', live='FAIL' if transport == 'live' else 'NOT_RUN')
                    self.assertTrue(runner.validate_receipt(result, transport=transport))

    def test_overlapping_credentials_rejected_before_file_creation(self):
        for key in (PAT, 'prefix-' + PAT, PAT[:8]):
            with self.subTest(key=key), mock.patch.dict(os.environ, {'FAKE_PROVIDER': key}):
                with mock.patch.object(runner, '_private_file') as write:
                    with self.assertRaises(ValueError):
                        with runner.credential_files(pat_env='FAKE_PAT', key_env='FAKE_PROVIDER',
                                                     directory=self.tmp.name):
                            self.fail('overlapping credentials accepted')
                    write.assert_not_called()

    def test_getpass_fallback_warning_fails_closed(self):
        def warn(_prompt):
            warnings.warn('terminal echo unavailable', runner.getpass.GetPassWarning)
            self.fail('warning should raise')
        with mock.patch.object(runner.getpass, 'getpass', side_effect=warn):
            with self.assertRaises(EOFError):
                with runner.credential_files(key_env='FAKE_PROVIDER', directory=self.tmp.name):
                    self.fail('fallback accepted')


if __name__ == '__main__':
    unittest.main()
