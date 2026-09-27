import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    'install_android_tools', Path(__file__).resolve().parents[1] / 'install_android_tools.py',
)
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


def create_dummy_tools_zip(dest: Path) -> str:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(dest, 'w') as zf:
        zf.writestr('cmdline-tools/bin/sdkmanager', '#!/bin/sh\nexit 0\n')
        zf.writestr('cmdline-tools/source.properties', 'Pkg.Revision=15859902\n')
    hasher = hashlib.sha256()
    with open(dest, 'rb') as f:
        hasher.update(f.read())
    return hasher.hexdigest()


class InstallAndroidToolsTests(unittest.TestCase):
    def test_https_protocol_enforced(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'tools'
            with self.assertRaises(ValueError) as ctx:
                installer.install_tools(
                    url='http://dl.google.com/tools.zip',
                    expected_sha256='abc',
                    destination=dest,
                )
            self.assertIn('Only HTTPS URLs are permitted', str(ctx.exception))
            self.assertFalse(dest.exists())

    def test_curl_command_flags_and_no_insecure(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'archive.zip'
            with patch.object(installer.subprocess, 'run') as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(['curl'], 0)
                installer.download_with_retry(
                    url='https://dl.google.com/test.zip',
                    output_path=archive,
                    max_retries=1,
                    connect_timeout=25,
                    max_time=180,
                )
                self.assertEqual(mock_run.call_count, 1)
                cmd = mock_run.call_args[0][0]
                self.assertIn('--proto', cmd)
                self.assertIn('=https', cmd)
                self.assertIn('--proto-redir', cmd)
                self.assertIn('--connect-timeout', cmd)
                self.assertIn('25', cmd)
                self.assertIn('--max-time', cmd)
                self.assertIn('180', cmd)
                self.assertNotIn('-k', cmd)
                self.assertNotIn('--insecure', cmd)

    def test_first_exit_35_then_success(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'
            dummy_zip = Path(folder) / 'dummy.zip'
            valid_sha = create_dummy_tools_zip(dummy_zip)
            zip_bytes = dummy_zip.read_bytes()

            call_count = 0

            def fake_run(cmd, *args, **kwargs):
                nonlocal call_count
                call_count += 1
                if call_count == 1:
                    # Simulate curl exit 35 (TLS connect error)
                    return subprocess.CompletedProcess(cmd, 35)
                # Second call succeeds
                out_idx = cmd.index('--output') + 1
                out_file = Path(cmd[out_idx])
                out_file.write_bytes(zip_bytes)
                return subprocess.CompletedProcess(cmd, 0)

            mock_sleep = MagicMock()
            with patch.object(installer.subprocess, 'run', side_effect=fake_run):
                installer.install_tools(
                    url='https://dl.google.com/tools.zip',
                    expected_sha256=valid_sha,
                    destination=dest,
                    max_retries=3,
                    sleep_fn=mock_sleep,
                )

            self.assertEqual(call_count, 2)
            mock_sleep.assert_called_once_with(2)
            self.assertTrue(dest.is_dir())
            sdkmanager = dest / 'bin' / 'sdkmanager'
            self.assertTrue(sdkmanager.is_file())
            self.assertEqual((sdkmanager.stat().st_mode & 0o777), 0o755)

    def test_continuous_failure_reaches_retry_limit_without_swallowing_exit_code(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'
            mock_sleep = MagicMock()

            with patch.object(installer.subprocess, 'run') as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(['curl'], 35)
                with self.assertRaises(subprocess.CalledProcessError) as ctx:
                    installer.install_tools(
                        url='https://dl.google.com/tools.zip',
                        expected_sha256='any_hash',
                        destination=dest,
                        max_retries=3,
                        sleep_fn=mock_sleep,
                    )
                self.assertEqual(ctx.exception.returncode, 35)
                self.assertEqual(mock_run.call_count, 3)
                self.assertEqual(mock_sleep.call_count, 2)
                # Destination must not have been created or modified
                self.assertFalse(dest.exists())

    def test_non_retryable_exit_code_fails_immediately(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'
            mock_sleep = MagicMock()

            with patch.object(installer.subprocess, 'run') as mock_run:
                # 22 is CURLE_HTTP_RETURNED_ERROR (e.g. 404 Not Found)
                mock_run.return_value = subprocess.CompletedProcess(['curl'], 22)
                with self.assertRaises(subprocess.CalledProcessError) as ctx:
                    installer.install_tools(
                        url='https://dl.google.com/tools.zip',
                        expected_sha256='any_hash',
                        destination=dest,
                        max_retries=3,
                        sleep_fn=mock_sleep,
                    )
                self.assertEqual(ctx.exception.returncode, 22)
                self.assertEqual(mock_run.call_count, 1)
                mock_sleep.assert_not_called()
                self.assertFalse(dest.exists())

    def test_checksum_mismatch_prevents_installation(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'
            dummy_zip = Path(folder) / 'dummy.zip'
            create_dummy_tools_zip(dummy_zip)
            zip_bytes = dummy_zip.read_bytes()

            def fake_run(cmd, *args, **kwargs):
                out_idx = cmd.index('--output') + 1
                out_file = Path(cmd[out_idx])
                out_file.write_bytes(zip_bytes)
                return subprocess.CompletedProcess(cmd, 0)

            with patch.object(installer.subprocess, 'run', side_effect=fake_run):
                with self.assertRaises(ValueError) as ctx:
                    installer.install_tools(
                        url='https://dl.google.com/tools.zip',
                        expected_sha256='0000000000000000000000000000000000000000000000000000000000000000',
                        destination=dest,
                    )
                self.assertIn('checksum mismatch', str(ctx.exception).lower())
                # Destination must not exist
                self.assertFalse(dest.exists())

    def test_interruption_leaves_no_artifacts_in_destination(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'

            with patch.object(installer.subprocess, 'run', side_effect=KeyboardInterrupt):
                with self.assertRaises(KeyboardInterrupt):
                    installer.install_tools(
                        url='https://dl.google.com/tools.zip',
                        expected_sha256='any_hash',
                        destination=dest,
                    )
                self.assertFalse(dest.exists())


if __name__ == '__main__':
    unittest.main()
