import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    'install_packages', Path(__file__).resolve().parents[1] / 'install_packages.py',
)
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallPackagesTests(unittest.TestCase):
    def test_upgrades_only_official_debian_sources_in_both_formats(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            parts = root / 'sources.list.d'
            parts.mkdir()
            legacy = root / 'sources.list'
            legacy.write_text('deb http://deb.debian.org/debian trixie main\n')
            source = parts / 'debian.sources'
            source.write_text(
                'URIs: http://deb.debian.org/debian http://security.debian.org/debian-security\n'
                'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg\n',
            )
            other = parts / 'custom.list'
            original = ('deb http://mirror.example/debian trixie main\n'
                        'deb http://deb.debian.org.example/debian trixie main\n')
            other.write_text(original)
            installer.configure_sources(root)
            self.assertIn('https://deb.debian.org/debian', legacy.read_text())
            self.assertIn('https://security.debian.org/debian-security', source.read_text())
            self.assertIn('Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg', source.read_text())
            self.assertEqual(other.read_text(), original)
            before = source.read_bytes()
            installer.configure_sources(root)
            self.assertEqual(source.read_bytes(), before)

    @patch.object(installer, 'configure_sources')
    @patch.object(installer.subprocess, 'check_call')
    def test_update_failure_stops_before_install(self, run, configure):
        run.side_effect = subprocess.CalledProcessError(100, 'apt-get')
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(['git'])
        configure.assert_called_once_with()
        self.assertEqual(run.call_count, 1)
        self.assertIn('update', run.call_args.args[0])
        self.assertIn('APT::Update::Error-Mode=any', run.call_args.args[0])

    @patch.object(installer, 'configure_sources')
    @patch.object(installer.subprocess, 'check_call')
    def test_install_failure_is_not_swallowed(self, run, configure):
        run.side_effect = [0, subprocess.CalledProcessError(100, 'apt-get')]
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(['git'])
        self.assertEqual(run.call_count, 2)

    @patch.object(installer, 'configure_sources')
    @patch.object(installer.subprocess, 'check_call')
    def test_both_steps_use_bounded_retries_and_requested_packages(self, run, configure):
        installer.install(['git', 'curl'])
        self.assertEqual(run.call_count, 2)
        for call in run.call_args_list:
            self.assertIn('Acquire::Retries=3', call.args[0])
            self.assertIn('Acquire::https::Timeout=30', call.args[0])
        self.assertEqual(run.call_args.args[0][-2:], ['git', 'curl'])

    @patch.object(installer, 'configure_sources')
    def test_empty_package_request_has_no_side_effects(self, configure):
        with self.assertRaises(ValueError):
            installer.install([])
        configure.assert_not_called()
