from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import android_signing


TEMPLATE = '''plugins {
    id("com.android.application")
}

android {
    namespace = "io.gitlabmobile.gitlab_mobile"
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
'''


class AndroidSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_configure_gradle_is_idempotent_and_removes_release_debug_fallback(self):
        path = self.root / 'build.gradle.kts'
        path.write_text(TEMPLATE, encoding='utf-8')
        self.assertTrue(android_signing.configure_gradle(path))
        first = path.read_bytes()
        self.assertFalse(android_signing.configure_gradle(path))
        self.assertEqual(path.read_bytes(), first)
        text = first.decode()
        self.assertTrue(text.startswith(android_signing.IMPORTS))
        self.assertEqual(text.count(android_signing.BEGIN_IMPORTS), 1)
        self.assertEqual(text.count(android_signing.BEGIN_LOADER), 1)
        self.assertEqual(text.count(android_signing.BEGIN_CONFIG), 1)
        self.assertNotIn('signingConfigs.getByName("debug")', text)
        self.assertIn('setOf("debug", "profile", "release")', text)
        self.assertIn('setOf("debug")', text)

    def test_configure_gradle_rejects_unknown_or_partial_template(self):
        path = self.root / 'build.gradle.kts'
        path.write_text('plugins {}\n', encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'expected one android block'):
            android_signing.configure_gradle(path)
        path.write_text(android_signing.BEGIN_LOADER + '\nandroid {}\n', encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'Incomplete Android signing markers'):
            android_signing.configure_gradle(path)

    def test_configure_gradle_rejects_stale_managed_content(self):
        path = self.root / 'build.gradle.kts'
        path.write_text(TEMPLATE, encoding='utf-8')
        android_signing.configure_gradle(path)
        path.write_text(
            path.read_text().replace(
                'Stable Android signing certificate identity changed',
                'Old unchecked certificate behavior'),
            encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'Stale managed Android signing configuration'):
            android_signing.configure_gradle(path)

    def test_configure_gradle_rejects_stale_managed_imports(self):
        path = self.root / 'build.gradle.kts'
        path.write_text(TEMPLATE, encoding='utf-8')
        android_signing.configure_gradle(path)
        path.write_text(
            path.read_text().replace(
                'import java.io.File as GitLabMobileFile',
                'import java.io.File as OldSigningFile'),
            encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'Stale managed Android signing configuration'):
            android_signing.configure_gradle(path)

    def _keytool(self, password_seen: list[str]):
        def run(command, **kwargs):
            password_seen.append(kwargs['env']['GITLAB_MOBILE_KEYSTORE_PASSWORD'])
            self.assertNotIn(password_seen[-1], command)
            if '-genkeypair' in command:
                Path(command[command.index('-keystore') + 1]).write_bytes(b'pkcs12')
                return subprocess.CompletedProcess(command, 0, b'', b'')
            return subprocess.CompletedProcess(command, 0, b'public certificate', b'')
        return run

    def test_cli_init_creates_private_atomic_identity_without_printing_secret(self):
        destination = self.root / 'shared-signing'
        passwords: list[str] = []
        stdout = io.StringIO()
        stderr = io.StringIO()
        arguments = [
            'android_signing.py', 'init',
            '--properties', str(destination / 'signing.properties'),
        ]
        with mock.patch.object(subprocess, 'run', side_effect=self._keytool(passwords)), \
                mock.patch.object(sys, 'argv', arguments), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            self.assertEqual(android_signing.main(), 0)
        properties = destination / 'signing.properties'
        keystore = destination / android_signing.KEYSTORE_NAME
        self.assertTrue(properties.is_file())
        self.assertTrue(keystore.is_file())
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(properties.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(keystore.stat().st_mode), 0o600)
        content = properties.read_text()
        self.assertIn(
            f'storeFile={destination.resolve() / android_signing.KEYSTORE_NAME}', content)
        self.assertNotIn('.android-signing-', content)
        self.assertIn('allowedBuildTypes=debug,profile,release', content)
        self.assertIn(hashlib.sha256(b'public certificate').hexdigest().upper(), content)
        for password in passwords:
            self.assertNotIn(password, stdout.getvalue())
            self.assertNotIn(password, stderr.getvalue())

    def test_init_names_a_play_upload_identity_and_rejects_dn_injection(self):
        commands = []
        def run(command, **kwargs):
            commands.append(command)
            if '-genkeypair' in command:
                Path(command[command.index('-keystore') + 1]).write_bytes(b'pkcs12')
            return subprocess.CompletedProcess(command, 0, b'public certificate', b'')
        destination = self.root / 'play-upload'
        with mock.patch.object(subprocess, 'run', side_effect=run):
            android_signing.init_identity(destination, common_name='GitLab Mobile Play Upload')
        generate = next(command for command in commands if '-genkeypair' in command)
        self.assertEqual(generate[generate.index('-dname') + 1], 'CN=GitLab Mobile Play Upload')
        self.assertIn('allowedBuildTypes=debug,profile,release',
                      (destination / 'signing.properties').read_text())
        for name in ('', 'X, O=Evil', 'CN=Other', 'x' * 65):
            with self.assertRaisesRegex(RuntimeError, 'common name'):
                android_signing.init_identity(self.root / 'other', common_name=name)
        self.assertFalse((self.root / 'other').exists())

    def test_cli_verify_keytool_failure_does_not_echo_secret_output(self):
        secret = 'synthetic-password-must-stay-private'
        keystore = self.root / 'identity.p12'
        keystore.write_bytes(b'pkcs12')
        properties = self.root / 'signing.properties'
        properties.write_text(
            f'storeFile={keystore}\nstorePassword={secret}\nkeyPassword={secret}\n'
            'keyAlias=gitlab-mobile\nstoreType=PKCS12\ncertificateSha256=00\n'
            'allowedBuildTypes=debug,profile,release\n')
        failure = subprocess.CalledProcessError(
            1, ['keytool', '-exportcert'],
            output=f'stdout contains {secret}'.encode(),
            stderr=f'stderr contains {secret}'.encode())
        stdout = io.StringIO()
        stderr = io.StringIO()
        arguments = [
            'android_signing.py', 'verify', '--properties', str(properties),
        ]
        with mock.patch.object(subprocess, 'run', side_effect=failure), \
                mock.patch.object(sys, 'argv', arguments), \
                redirect_stdout(stdout), redirect_stderr(stderr), \
                self.assertRaises(SystemExit) as stopped:
            android_signing.main()
        self.assertNotEqual(stopped.exception.code, 0)
        self.assertIn('Android signing stopped:', stderr.getvalue())
        self.assertNotIn(secret, stdout.getvalue())
        self.assertNotIn(secret, stderr.getvalue())

    def test_init_refuses_complete_or_incomplete_existing_identity(self):
        for name, populate in (('complete', True), ('incomplete', False)):
            destination = self.root / name
            destination.mkdir()
            if populate:
                (destination / 'signing.properties').write_text('existing=true\n')
            with mock.patch.object(subprocess, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'refusing to replace or repair'):
                    android_signing.init_identity(destination)
                run.assert_not_called()

    def test_init_concurrent_publication_never_overwrites_winner(self):
        destination = self.root / 'shared-signing'
        def concurrent_winner(command, **kwargs):
            if '-genkeypair' in command:
                Path(command[command.index('-keystore') + 1]).write_bytes(b'loser')
                destination.mkdir()
                (destination / 'winner').write_text('keep')
                return subprocess.CompletedProcess(command, 0, b'', b'')
            return subprocess.CompletedProcess(command, 0, b'certificate', b'')
        with mock.patch.object(subprocess, 'run', side_effect=concurrent_winner):
            with self.assertRaisesRegex(RuntimeError, 'created concurrently'):
                android_signing.init_identity(destination)
        self.assertEqual((destination / 'winner').read_text(), 'keep')
        self.assertFalse((destination / android_signing.KEYSTORE_NAME).exists())

    def test_init_does_not_remove_another_process_lock(self):
        destination = self.root / 'shared-signing'
        lock = self.root / '.shared-signing.init-lock'
        lock.mkdir()
        marker = lock / 'owner'
        marker.write_text('other process')
        with self.assertRaisesRegex(RuntimeError, 'already running'):
            android_signing.init_identity(destination)
        self.assertEqual(marker.read_text(), 'other process')

    def test_verify_rejects_changed_certificate_and_redacts_password(self):
        keystore = self.root / 'identity.p12'
        keystore.write_bytes(b'pkcs12')
        secret = 'do-not-print-this'
        properties = self.root / 'signing.properties'
        properties.write_text(
            f'storeFile={keystore}\nstorePassword={secret}\nkeyPassword={secret}\n'
            'keyAlias=gitlab-mobile\nstoreType=PKCS12\ncertificateSha256=00\n'
            'allowedBuildTypes=debug,profile,release\n')
        stderr = io.StringIO()
        with mock.patch.object(subprocess, 'run', side_effect=self._keytool([])):
            with redirect_stderr(stderr), self.assertRaisesRegex(RuntimeError, 'identity'):
                android_signing.verify_identity(properties)
        self.assertNotIn(secret, stderr.getvalue())

    def test_ci_properties_are_debug_only_and_require_ci(self):
        keystore = self.root / 'ci.p12'
        keystore.write_bytes(b'pkcs12')
        properties = self.root / 'ci/signing.properties'
        environment = {'CI': 'true', 'GITLAB_MOBILE_CI_KEYSTORE_PASSWORD': 'android'}
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(subprocess, 'run', side_effect=self._keytool([])):
            android_signing.write_ci_properties(
                properties, keystore, 'ephemeral-debug')
        content = properties.read_text()
        self.assertIn('allowedBuildTypes=debug\n', content)
        self.assertNotIn('allowedBuildTypes=debug,profile,release', content)
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'CI=true'):
                android_signing.write_ci_properties(
                    self.root / 'nope', keystore, 'ephemeral-debug')

    def test_only_the_stable_key_on_a_protected_ref_signs_release(self):
        keystore = self.root / 'ci.p12'
        keystore.write_bytes(b'pkcs12')
        properties = self.root / 'ci/signing.properties'
        environment = {'CI': 'true', 'GITLAB_MOBILE_CI_KEYSTORE_PASSWORD': 'android'}
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(subprocess, 'run', side_effect=self._keytool([])):
            with self.assertRaisesRegex(RuntimeError, 'protected refs'):
                android_signing.write_ci_properties(properties, keystore, 'stable-legacy-release')
        self.assertFalse(properties.exists())
        protected = {**environment, 'CI_COMMIT_REF_PROTECTED': 'true'}
        with mock.patch.dict(os.environ, protected, clear=True), \
                mock.patch.object(subprocess, 'run', side_effect=self._keytool([])):
            android_signing.write_ci_properties(properties, keystore, 'stable-legacy-release')
            self.assertIn('allowedBuildTypes=debug,profile,release\n', properties.read_text())
            android_signing.write_ci_properties(properties, keystore, 'ephemeral-debug')
            self.assertIn('allowedBuildTypes=debug\n', properties.read_text(),
                          'a key made for one pipeline stays debug-only even on a protected ref')

    def test_debug_only_identity_is_rejected_outside_explicit_ci_path(self):
        keystore = self.root / 'ci.p12'
        keystore.write_bytes(b'pkcs12')
        properties = self.root / 'signing.properties'
        certificate = hashlib.sha256(b'public certificate').hexdigest().upper()
        properties.write_text(
            f'storeFile={keystore}\nstorePassword=android\nkeyPassword=android\n'
            'keyAlias=androiddebugkey\nstoreType=PKCS12\n'
            f'certificateSha256={certificate}\nallowedBuildTypes=debug\n')
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(subprocess, 'run', side_effect=self._keytool([])):
            with self.assertRaisesRegex(RuntimeError, 'explicit CI path'):
                android_signing.verify_identity(properties)
        environment = {
            'CI': 'true', 'GITLAB_MOBILE_ALLOW_DEBUG_ONLY_SIGNING': '1',
        }
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(subprocess, 'run', side_effect=self._keytool([])):
            android_signing.verify_identity(properties)

    def test_gradle_loader_fails_release_and_profile_with_ci_debug_identity(self):
        self.assertIn('CI debug signing cannot build release or profile variants',
                      android_signing.LOADER)
        self.assertIn('task.name.contains("release"', android_signing.LOADER)
        self.assertIn('task.name.contains("profile"', android_signing.LOADER)
        self.assertIn('task.project == project', android_signing.LOADER)
        self.assertIn('gradle.taskGraph.whenReady {\n', android_signing.LOADER)
        self.assertNotIn('whenReady { graph ->', android_signing.LOADER)
        self.assertIn('reader(Charsets.UTF_8)', android_signing.LOADER)
        self.assertNotIn('java.io.File(', android_signing.LOADER)

    def test_gitlab_ci_discovers_all_signing_tests(self):
        pipeline = (Path(__file__).resolve().parents[2] / '.gitlab-ci.yml').read_text()
        self.assertIn("unittest discover -s tool/tests -p 'test_*.py'", pipeline)

    def test_incomplete_properties_fail_without_keytool(self):
        properties = self.root / 'signing.properties'
        properties.write_text('storeFile=missing.p12\n')
        with mock.patch.object(subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Incomplete'):
                android_signing.verify_identity(properties)
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
