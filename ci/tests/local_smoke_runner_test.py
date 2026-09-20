import contextlib
import io
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from tool import run_live_smoke as runner


class LocalSmokeRunnerTests(unittest.TestCase):
    def test_no_sdk_never_prompts_for_a_credential(self):
        with patch.object(runner.shutil, 'which', return_value=None), patch.object(runner.getpass, 'getpass') as prompt:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(runner.run(), 2)
            prompt.assert_not_called()

    def test_non_positive_account_never_prompts(self):
        with patch.object(runner.shutil, 'which', return_value='/sdk/dart'), patch.object(runner.getpass, 'getpass') as prompt:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(runner.run(0), 2)
            prompt.assert_not_called()

    def test_temporary_file_is_private_cleaned_and_exit_code_preserved(self):
        credential = 'synthetic-unit-fixture-only'
        observed = []
        def execute(argv, **kwargs):
            self.assertEqual(argv, ['/sdk/dart', 'run', 'tool/live_smoke.dart'])
            self.assertNotIn(credential, str(argv))
            self.assertNotIn(credential, kwargs['env'].values())
            self.assertEqual(kwargs['env']['SMOKE_EXPECTED_USER_ID'], '9571238')
            path = Path(kwargs['env']['SMOKE_TOKEN_FILE'])
            observed.append(path)
            self.assertEqual(path.read_text(), credential)
            if os.name != 'nt':
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            return subprocess.CompletedProcess(argv, 3)
        with patch.object(runner.shutil, 'which', return_value='/sdk/dart'), \
                patch.object(runner.getpass, 'getpass', return_value=credential), \
                patch.object(runner.subprocess, 'run', side_effect=execute):
            self.assertEqual(runner.run(), 3)
        self.assertEqual(len(observed), 1)
        self.assertFalse(observed[0].exists())
        self.assertFalse(observed[0].parent.exists())

    def test_failed_process_start_still_removes_file_without_echoing_secret(self):
        observed = []
        def execute(_argv, **kwargs):
            observed.append(Path(kwargs['env']['SMOKE_TOKEN_FILE']))
            raise OSError('synthetic-secret-should-not-be-echoed')
        errors = io.StringIO()
        with patch.object(runner.shutil, 'which', return_value='/sdk/dart'), \
                patch.object(runner.getpass, 'getpass', return_value='synthetic-credential'), \
                patch.object(runner.subprocess, 'run', side_effect=execute), contextlib.redirect_stderr(errors):
            self.assertEqual(runner.run(), 2)
        self.assertFalse(observed[0].exists())
        self.assertNotIn('synthetic', errors.getvalue())

    def test_invalid_token_never_starts_dart(self):
        with patch.object(runner.shutil, 'which', return_value='/sdk/dart'), \
                patch.object(runner.getpass, 'getpass', return_value='contains whitespace'), \
                patch.object(runner.subprocess, 'run') as execute, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(runner.run(), 2)
        execute.assert_not_called()
