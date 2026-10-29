"""Cross-process MR7 recovery regressions. Every network endpoint is loopback."""
import base64
import contextlib
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mr7_fix1_wrapper', ROOT / 'tool/run_mr7_sandbox.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
PAT = 'synthetic-pat-for-local-gitlab'
KEY = 'synthetic-key-for-local-provider'


# The wrapper starts the Dart host with fvm; python_checks runs in an image
# without Flutter, so these cross-process tests run only where fvm exists.
@unittest.skipUnless(shutil.which('fvm'), 'needs the fvm Flutter toolchain')
class ProcessRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mr7-fix1-process-', dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.config = {
            'transport': 'live', 'policy': 'candidate', 'suite': 'rest',
            'releaseSha': 'a' * 40, 'expectedUserId': 7,
            'namespace': 'synthetic-owner', 'stateDirectory': str(self.state),
            'only': ['b0-star'],
            'provider': {'endpoint': 'https://provider.invalid/v1',
                         'format': 'chat_completions', 'model': 'fixture-model',
                         'caps': {'tools': True, 'maxTokens': 2048},
                         'maxCost': 1.0, 'maxCalls': 4,
                         'priceInputPerMTok': 1.0, 'priceOutputPerMTok': 2.0,
                         'keyEnv': 'FAKE_PROVIDER'},
        }
        runner._prepare_live_state(self.config, self.state)
        self.config_path = self.root / 'config.json'
        self.receipt = self.root / 'receipt.json'
        self.request = self.root / 'request.json'
        self.response = self.root / 'response.json'
        self.marker = self.root / 'marker.json'
        for name, value in [('pat', PAT), ('key', KEY)]:
            runner._private_file(self.root / name, value)
        self.env = {name: os.environ[name] for name in runner.SAFE_ENV if name in os.environ}
        self.env.update({
            'MR7_SANDBOX_CONFIG_FILE': str(self.config_path),
            'MR7_SANDBOX_RECEIPT_FILE': str(self.receipt),
            'MR7_GITLAB_PAT_FILE': str(self.root / 'pat'),
            'MR7_PROVIDER_KEY_FILE': str(self.root / 'key'),
            'MR7_CONFIRM_REQUEST_FILE': str(self.request),
            'MR7_CONFIRM_RESPONSE_FILE': str(self.response),
            'MR7_FIXTURE_MARKER': str(self.marker),
        })
        self.process = None
        self.addCleanup(self._stop)

    def _stop(self):
        if self.process is not None and self.process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=15)
        if self.process is not None and self.process.stdout is not None:
            self.process.stdout.close()

    def launch(self, mode):
        runner._private_file(self.config_path, json.dumps(self.config))
        runner._private_file(self.receipt, '')
        self.env['MR7_FIXTURE_MODE'] = mode
        self.process = subprocess.Popen(
            ['fvm', 'flutter', 'test', '--no-pub', '--reporter', 'expanded',
             'test/ai/mr7_fix1_cli_fixture.dart'],
            cwd=ROOT, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True, text=True)

    def wait_for(self, path, timeout=45):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if path.exists():
                return
            if self.process.poll() is not None:
                self.fail(f'CLI exited before {path.name}: {self.process.stdout.read()}')
            time.sleep(0.05)
        self.fail(f'CLI did not publish {path.name} in {timeout} seconds')

    def approve(self):
        self.wait_for(self.request)
        runner._private_file(self.response, json.dumps({'approved': True}))

    def reconcile(self):
        # This invokes a new host process through the production wrapper.
        return subprocess.run(
            ['python3', 'tool/run_mr7_sandbox.py', '--reconcile', str(self.state)],
            cwd=ROOT, env=self.env, text=True, capture_output=True, timeout=90)

    def test_interrupted_encrypted_journal_reopens_in_new_process(self):
        self.launch('pause-write')
        self.approve()
        self.wait_for(self.marker)
        self._stop()
        self.assertEqual(json.loads((self.state / 'run.json').read_text())['projectId'], 909)
        journals = list(self.state.rglob('journal.v1.enc'))
        self.assertEqual(len(journals), 1)
        original = journals[0].read_bytes()
        self.assertNotIn(b'setStar', original)
        self.assertNotIn(b'Synthetic sandbox star requested', original)
        self.assertEqual((self.state.stat().st_mode & 0o777), 0o700)
        key_path = self.state / 'journal-key.json'
        self.assertEqual((key_path.stat().st_mode & 0o777), 0o600)
        recovered = self.reconcile()
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        self.assertIn('setStar', recovered.stdout)
        metadata = json.loads(recovered.stdout)['entries'][0]
        self.assertIn('909', metadata['targetIds'])
        self.assertIsNotNone(metadata['createdAt'])
        self.assertIsNotNone(metadata['dispatchedAt'])
        self.assertNotIn('Synthetic sandbox star requested', recovered.stdout)
        self.assertEqual(journals[0].read_bytes(), original)

        saved_key = key_path.read_bytes()
        key_path.unlink()
        missing = self.reconcile()
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('journalKeyMissing', missing.stdout + missing.stderr)
        self.assertEqual(journals[0].read_bytes(), original)
        self.assertFalse(key_path.exists())
        data = json.loads(saved_key)
        data['key'] = base64.b64encode(os.urandom(32)).decode()
        runner._private_file(key_path, json.dumps(data))
        foreign_key = key_path.read_bytes()
        foreign = self.reconcile()
        self.assertNotEqual(foreign.returncode, 0)
        self.assertIn('journalUnreadableOrForeignKey', foreign.stdout + foreign.stderr)
        self.assertEqual(journals[0].read_bytes(), original)
        self.assertEqual(key_path.read_bytes(), foreign_key)

    def test_lost_create_reply_is_reconciled_by_exact_path(self):
        self.launch('lost-create')
        self.wait_for(self.marker)
        self.process.wait(timeout=45)
        created = json.loads(self.marker.read_text())
        state = json.loads((self.state / 'run.json').read_text())
        self.assertEqual(created['path_with_namespace'], state['projectPath'])
        self.assertEqual(state['projectPath'],
                         f"{state['namespace']}/mr7-{state['nonce']}")
        requests = []
        expected = state['projectPath']

        class GitLab(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                if self.path == '/api/v4/user':
                    data = {'id': 7, 'username': 'synthetic-owner'}
                elif self.path == '/api/v4/projects/' + quote(expected, safe=''):
                    data = created
                elif self.path == '/api/v4/projects/' + quote('synthetic-owner/mr7-foreign', safe=''):
                    data = {**created, 'id': 910,
                            'path_with_namespace': 'synthetic-owner/mr7-foreign'}
                else:
                    self.send_error(404)
                    return
                contents = json.dumps(data).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(contents)))
                self.end_headers()
                self.wfile.write(contents)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), GitLab)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            found = runner._reconcile_project(
                state, PAT, origin=f'http://127.0.0.1:{server.server_port}')
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        self.assertEqual(found['status'], 'FOUND')
        self.assertEqual(found['projectId'], created['id'])
        self.assertEqual(requests, ['/api/v4/user', '/api/v4/projects/' + quote(expected, safe='')])
        self.assertNotIn('mr7-foreign', unquote(' '.join(requests)))

    def test_foreign_same_account_key_is_rejected_before_first_write(self):
        key_path = self.state / 'journal-key.json'
        key = json.loads(key_path.read_text())
        key['key'] = base64.b64encode(os.urandom(32)).decode()
        key_path.write_text(json.dumps(key))
        before = {str(path.relative_to(self.state)): path.read_bytes()
                  for path in self.state.rglob('*') if path.is_file()}
        result = self.reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('journalUnreadableOrForeignKey', result.stdout + result.stderr)
        after = {str(path.relative_to(self.state)): path.read_bytes()
                 for path in self.state.rglob('*') if path.is_file()}
        self.assertEqual(before, after)

    def test_cli_confirmation_after_old_two_minute_limit_completes(self):
        self.launch('normal')
        self.wait_for(self.request)
        time.sleep(121)
        self.assertIsNone(self.process.poll(), 'host timed out before its confirmation window')
        runner._private_file(self.response, json.dumps({'approved': True}))
        out, _ = self.process.communicate(timeout=90)
        self.assertEqual(self.process.returncode, 0, out)
        self.assertEqual(json.loads(self.receipt.read_text())['status'], 'PASS')

    def test_cli_timeout_keeps_readable_quarantine(self):
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=25)).isoformat()
        self.config['deadlineAt'] = deadline
        state_path = self.state / 'run.json'
        state = json.loads(state_path.read_text())
        state['deadlineAt'] = deadline
        state_path.write_text(json.dumps(state))
        self.launch('pause-write')
        self.approve()
        self.wait_for(self.marker)
        output, _ = self.process.communicate(timeout=60)
        self.assertNotEqual(self.process.returncode, 0, output)
        self.assertTrue(self.state.exists())
        self.assertEqual(json.loads((self.state / 'run.json').read_text())['stopReason'], 'liveTimeout')
        recovered = self.reconcile()
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        self.assertIn('setStar', recovered.stdout)


if __name__ == '__main__':
    unittest.main()
