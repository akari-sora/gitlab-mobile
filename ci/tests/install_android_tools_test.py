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
    """Create a minimal valid zip file containing cmdline-tools."""
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

    def test_curl_exit_code_35_recovery(self):
        """Test that exit code 35 (TLS connect error) triggers adaptive IPv4 retry and recovers."""
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'
            dummy_zip = Path(folder) / 'dummy.zip'
            valid_sha = create_dummy_tools_zip(dummy_zip)
            zip_bytes = dummy_zip.read_bytes()

            call_count = 0
            captured_cmds = []

            def fake_run(cmd, *args, **kwargs):
                nonlocal call_count
                call_count += 1
                captured_cmds.append(list(cmd))
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
            self.assertNotIn('--ipv4', captured_cmds[0])
            self.assertIn('--ipv4', captured_cmds[1])
            self.assertTrue(dest.is_dir())
            sdkmanager = dest / 'bin' / 'sdkmanager'
            self.assertTrue(sdkmanager.is_file())
            self.assertEqual((sdkmanager.stat().st_mode & 0o777), 0o755)

    def test_url_failover_to_gvt1(self):
        """Test that failure on primary URL fails over to redirector.gvt1.com fallback URL."""
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'
            dummy_zip = Path(folder) / 'dummy.zip'
            valid_sha = create_dummy_tools_zip(dummy_zip)
            zip_bytes = dummy_zip.read_bytes()

            primary_url = 'https://dl.google.com/android/repository/tools.zip'
            fallback_url = 'https://redirector.gvt1.com/edgedl/android/repository/tools.zip'

            call_count = 0
            captured_cmds = []

            def fake_run(cmd, *args, **kwargs):
                nonlocal call_count
                call_count += 1
                captured_cmds.append(list(cmd))
                if call_count == 1:
                    # Primary URL times out (exit 28)
                    return subprocess.CompletedProcess(cmd, 28)
                # Fallback URL succeeds
                out_idx = cmd.index('--output') + 1
                out_file = Path(cmd[out_idx])
                out_file.write_bytes(zip_bytes)
                return subprocess.CompletedProcess(cmd, 0)

            mock_sleep = MagicMock()
            with patch.object(installer.subprocess, 'run', side_effect=fake_run):
                installer.install_tools(
                    urls=[primary_url, fallback_url],
                    expected_sha256=valid_sha,
                    destination=dest,
                    max_retries=3,
                    sleep_fn=mock_sleep,
                )

            self.assertEqual(call_count, 2)
            self.assertEqual(captured_cmds[0][-1], primary_url)
            self.assertEqual(captured_cmds[1][-1], fallback_url)
            self.assertTrue(dest.is_dir())
            sdkmanager = dest / 'bin' / 'sdkmanager'
            self.assertTrue(sdkmanager.is_file())
            self.assertEqual((sdkmanager.stat().st_mode & 0o777), 0o755)

    def test_python_urllib_fallback(self):
        """Test fallback to Python urllib when all curl attempts fail."""
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'
            dummy_zip = Path(folder) / 'dummy.zip'
            valid_sha = create_dummy_tools_zip(dummy_zip)
            zip_bytes = dummy_zip.read_bytes()

            def fake_download_python(url, output_path, timeout=90):
                output_path.write_bytes(zip_bytes)

            mock_sleep = MagicMock()
            # Curl constantly fails with exit code 35
            with patch.object(installer.subprocess, 'run') as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(['curl'], 35)
                with patch.object(installer, 'download_with_python', side_effect=fake_download_python) as mock_py:
                    installer.install_tools(
                        urls=['https://dl.google.com/tools.zip', 'https://redirector.gvt1.com/tools.zip'],
                        expected_sha256=valid_sha,
                        destination=dest,
                        max_retries=2,
                        sleep_fn=mock_sleep,
                    )
                    self.assertEqual(mock_run.call_count, 2)
                    self.assertEqual(mock_py.call_count, 1)

            self.assertTrue(dest.is_dir())
            sdkmanager = dest / 'bin' / 'sdkmanager'
            self.assertTrue(sdkmanager.is_file())
            self.assertEqual((sdkmanager.stat().st_mode & 0o777), 0o755)

    def test_checksum_mismatch_error_handling(self):
        """Test that SHA-256 checksum mismatch aborts installation and leaves destination clean."""
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

            def fake_py(url, out_path, timeout=90):
                out_path.write_bytes(zip_bytes)

            with patch.object(installer.subprocess, 'run', side_effect=fake_run):
                with patch.object(installer, 'download_with_python', side_effect=fake_py):
                    with self.assertRaises(ValueError) as ctx:
                        installer.install_tools(
                            url='https://dl.google.com/tools.zip',
                            expected_sha256='0000000000000000000000000000000000000000000000000000000000000000',
                            destination=dest,
                            max_retries=1,
                        )
                    self.assertIn('checksum mismatch', str(ctx.exception).lower())
                    self.assertFalse(dest.exists())

    def test_prefer_ipv4_flag_passes_ipv4_on_first_attempt(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'archive.zip'
            with patch.object(installer.subprocess, 'run') as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(['curl'], 0)
                installer.download_with_retry(
                    url='https://dl.google.com/test.zip',
                    output_path=archive,
                    max_retries=1,
                    prefer_ipv4=True,
                )
                self.assertEqual(mock_run.call_count, 1)
                cmd = mock_run.call_args[0][0]
                self.assertIn('--ipv4', cmd)

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

    def test_all_attempts_and_fallback_failed_raises(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'installed_tools'
            mock_sleep = MagicMock()

            with patch.object(installer.subprocess, 'run') as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(['curl'], 35)
                with patch.object(installer, 'download_with_python', side_effect=RuntimeError('network down')):
                    with self.assertRaises(subprocess.CalledProcessError) as ctx:
                        installer.install_tools(
                            url='https://dl.google.com/tools.zip',
                            expected_sha256='any_hash',
                            destination=dest,
                            max_retries=2,
                            sleep_fn=mock_sleep,
                        )
                    self.assertEqual(ctx.exception.returncode, 35)
                    self.assertFalse(dest.exists())

    def test_cli_argument_parsing(self):
        args = installer.parse_args([
            '--output-dir', '/opt/android-sdk/cmdline-tools',
            '--tools-revision', '15859902',
            '--expected-sha256', 'deadbeef',
            '--primary-url', 'https://dl.google.com/tools.zip',
            '--fallback-url', 'https://redirector.gvt1.com/tools.zip',
            '--ipv4',
            '--ensure-network',
        ])
        self.assertEqual(str(args.output_dir), '/opt/android-sdk/cmdline-tools')
        self.assertEqual(args.tools_revision, '15859902')
        self.assertEqual(args.expected_sha256, 'deadbeef')
        self.assertEqual(args.primary_url, 'https://dl.google.com/tools.zip')
        self.assertEqual(args.fallback_url, 'https://redirector.gvt1.com/tools.zip')
        self.assertTrue(args.ipv4)
        self.assertTrue(args.ensure_network)

    def test_ensure_route_when_already_accessible(self):
        with patch.object(installer, 'is_http_accessible', return_value=True):
            self.assertTrue(installer.ensure_dl_google_com_route())

    def test_ensure_route_appends_to_hosts_file_when_unreachable(self):
        with tempfile.TemporaryDirectory() as folder:
            fake_hosts = Path(folder) / 'hosts'
            fake_hosts.write_text('127.0.0.1 localhost\n')

            with patch.object(installer, 'is_http_accessible', return_value=False):
                with patch.object(installer, 'verify_tls_sni', return_value=True):
                    with patch('socket.getaddrinfo', return_value=[(None, None, None, None, ('173.194.174.100', 443))]):
                        result = installer.ensure_dl_google_com_route(hosts_file=fake_hosts)
                        self.assertTrue(result)
                        content = fake_hosts.read_text()
                        self.assertIn('173.194.174.100 dl.google.com', content)

    def test_install_sdk_components_downloads_and_extracts(self):
        with tempfile.TemporaryDirectory() as folder:
            android_home = Path(folder) / 'sdk'
            
            def fake_download(*args, **kwargs):
                out = kwargs['output_path']
                with zipfile.ZipFile(out, 'w') as zf:
                    if 'platform-tools' in out.name:
                        zf.writestr('platform-tools/adb', 'dummy')
                    elif 'platforms' in out.name:
                        zf.writestr('android-36/android.jar', 'dummy')
                    elif 'build-tools' in out.name:
                        zf.writestr('android-16/aapt2', 'dummy')

            with patch.object(installer, 'download_with_retry', side_effect=fake_download):
                installer.install_sdk_components(android_home, compile_sdk='36')

            self.assertTrue((android_home / 'platform-tools' / 'adb').is_file())
            self.assertTrue((android_home / 'platforms' / 'android-36' / 'android.jar').is_file())
            self.assertTrue((android_home / 'build-tools' / '36.0.0' / 'aapt2').is_file())


if __name__ == '__main__':
    unittest.main()
