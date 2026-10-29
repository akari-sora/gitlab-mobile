"""Exercise the real approval reader on an isolated controlling terminal."""
import json
import os
from pathlib import Path
import select
import signal
import sys
import tempfile
import time
import unittest

if os.name == 'posix':
    import pty
    import termios

ROOT = Path(__file__).resolve().parents[2]
HOST = r'''
import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timedelta, timezone

root, directory, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
sys.path.insert(0, str(root / 'tool'))
import run_mr7_sandbox as runner

child = subprocess.Popen([sys.executable, '-c', r"""
import json
from pathlib import Path
import sys
import time
directory = Path(sys.argv[1])
response = directory / 'response.json'
while not response.exists():
    if (directory / 'exit').exists():
        sys.exit(7)
    time.sleep(0.01)
answer = json.loads(response.read_text())
proposal = json.loads((directory / 'request.json').read_text())
approved = answer['approved'] and (
    'requiredTypedName' not in proposal or
    answer.get('typedName') == proposal['requiredTypedName'])
if approved:
    (directory / 'proceeded').write_text('explicitly approved')
sys.exit(0 if approved else 7)
""", str(directory)], stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = datetime.now(timezone.utc) + timedelta(seconds=1) if mode == 'deadline' else None
try:
    code = runner._wait_live_child(child, directory / 'request.json',
                                   directory / 'response.json', [], deadline=deadline)
    result = f'child_exit {code}'
except runner._LiveTimedOut:
    result = 'timed_out'
except KeyboardInterrupt:
    result = 'interrupted'
finally:
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=3)
    (directory / 'result').write_text(result)
    # Inspect restoration at wrapper return, without interpreter shutdown
    # attempting to flush an abandoned daemon's buffered terminal stream.
    os._exit(0)
'''


@unittest.skipUnless(os.name == 'posix', 'requires a POSIX controlling terminal')
class ConfirmationPtyTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mr7-confirm-pty-', dir=ROOT.parent)
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.response = self.directory / 'response.json'
        self.proceeded = self.directory / 'proceeded'
        self.transcript = b''

    def launch(self, *, mode='exit', typed=False):
        proposal = {'operation': 'deleteProject' if typed else 'setStar',
                    'tier': 'hardLine' if typed else 'T1', 'projectId': 9,
                    'payloadDigest': 'a' * 64, 'preview': 'Synthetic sandbox only.'}
        if typed:
            proposal['requiredTypedName'] = 'mr7-fixture'
        (self.directory / 'request.json').write_text(json.dumps(proposal))
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            os.execve(sys.executable,
                      [sys.executable, '-c', HOST, str(ROOT), str(self.directory), mode],
                      {'PATH': os.defpath, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.returncode = None
        self.original = termios.tcgetattr(self.master)
        self.assertTrue(self.original[3] & termios.ECHO)
        self.addCleanup(self.close)
        self.read_until(b'Type yes to approve: ')
        self.assertFalse(termios.tcgetattr(self.master)[3] & termios.ECHO)

    def poll(self):
        if self.returncode is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def wait(self, timeout):
        end = time.monotonic() + timeout
        while self.poll() is None:
            if time.monotonic() >= end:
                self.fail('approval wrapper did not return before the test deadline')
            time.sleep(0.02)

    def close(self):
        if self.master is not None:
            os.close(self.master)
            self.master = None
        if self.poll() is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.wait(5)

    def read_until(self, marker):
        end = time.monotonic() + 10
        while marker not in self.transcript and time.monotonic() < end:
            if select.select([self.master], [], [], 0.05)[0]:
                self.transcript += os.read(self.master, 4096)
        self.assertIn(marker, self.transcript)

    def finish(self, result, *, timeout=10):
        result_path = self.directory / 'result'
        end = time.monotonic() + timeout
        while not result_path.exists() and time.monotonic() < end:
            if select.select([self.master], [], [], 0.05)[0]:
                self.transcript += os.read(self.master, 4096)
        self.assertTrue(result_path.exists(), 'approval wrapper did not return before the test deadline')
        self.assertEqual(result_path.read_text(), result)
        # Inspect before closing the controlling terminal: closing it can release
        # a Darwin session leader that is already in its final exit sequence.
        self.assertTrue(termios.tcgetattr(self.master)[3] & termios.ECHO,
                        'approval reader left terminal ECHO disabled')
        self.assertEqual(termios.tcgetattr(self.master), self.original)
        os.close(self.master)
        self.master = None
        self.wait(5)
        self.assertEqual(self.returncode, 0, self.transcript)

    def assert_cancelled(self):
        self.assertFalse(self.response.exists(), 'cancelled prompt published an answer')
        self.assertFalse(self.proceeded.exists(), 'cancelled prompt approved the child')

    def test_unanswered_prompt_child_exit_restores_echo(self):
        self.launch()
        (self.directory / 'exit').touch()
        self.finish('child_exit 7')
        self.assert_cancelled()

    def test_unanswered_prompt_deadline_restores_echo(self):
        self.launch(mode='deadline')
        end = time.monotonic() + 4
        while not termios.tcgetattr(self.master)[3] & termios.ECHO and time.monotonic() < end:
            time.sleep(0.02)
        self.assertTrue(termios.tcgetattr(self.master)[3] & termios.ECHO,
                        'run deadline did not cancel the unanswered prompt')
        self.assert_cancelled()
        # The child still receives the existing bounded 30-second shutdown grace.
        self.finish('timed_out', timeout=35)
        self.assert_cancelled()

    def test_unanswered_prompt_interrupt_restores_echo(self):
        self.launch()
        os.kill(self.pid, signal.SIGINT)
        self.finish('interrupted')
        self.assert_cancelled()

    def test_typed_yes_allows_child_to_proceed(self):
        self.launch()
        os.write(self.master, b'yes\n')
        self.finish('child_exit 0')
        self.assertEqual(json.loads(self.response.read_text()), {'approved': True})
        self.assertTrue(self.proceeded.exists())
        self.assertNotIn(b'\r\nyes\r\n', self.transcript)

    def test_other_input_denies_approval(self):
        self.launch()
        os.write(self.master, b'no\n')
        self.finish('child_exit 7')
        self.assertEqual(json.loads(self.response.read_text()), {'approved': False})
        self.assertFalse(self.proceeded.exists())

    def test_whitespace_around_yes_denies_approval(self):
        self.launch()
        os.write(self.master, b' yes \n')
        self.finish('child_exit 7')
        self.assertEqual(json.loads(self.response.read_text()), {'approved': False})
        self.assertFalse(self.proceeded.exists())

    def test_typed_target_requires_a_second_explicit_answer(self):
        self.launch(typed=True)
        self.assertIn(b'Typed target required: mr7-fixture', self.transcript)
        os.write(self.master, b'yes\n')
        self.read_until(b'Type the target name: ')
        self.assert_cancelled()
        self.assertIsNone(self.poll())
        os.write(self.master, b'mr7-fixture\n')
        self.finish('child_exit 0')
        self.assertEqual(json.loads(self.response.read_text()),
                         {'approved': True, 'typedName': 'mr7-fixture'})
        self.assertTrue(self.proceeded.exists())

    def test_child_exit_during_typed_target_restores_echo(self):
        self.launch(typed=True)
        os.write(self.master, b'yes\n')
        self.read_until(b'Type the target name: ')
        (self.directory / 'exit').touch()
        self.finish('child_exit 7')
        self.assert_cancelled()


if __name__ == '__main__':
    unittest.main()
