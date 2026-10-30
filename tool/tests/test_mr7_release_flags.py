"""Exercise build flag propagation with synthetic tools, never an SDK or key."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'ci/build_android.sh'


class AndroidReleaseFlagTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ('bin', 'android/app', 'ci', 'sdk/build-tools/36.0.0'):
            (self.root / directory).mkdir(parents=True)
        (self.root / 'ci/mr7_attestation.py').write_text(
            "def source_digests(**kwargs):\n"
            "    return dict(tree='b' * 40, lock_sha256='c' * 64, "
            "capability_sha256='d' * 64, policy_sha256='e' * 64)\n")
        (self.root / 'pubspec.lock').write_text('synthetic lock\n')
        (self.root / 'pubspec.yaml').write_text('version: 1.0.0+4\n')
        (self.root / 'signing.properties').write_text('synthetic\n')
        self.stub('python3', '#!/bin/bash\nif [ "$1" = tool/android_signing.py ]; then exit 0; fi\nexec ' +
                  shutil.which('python3') + ' "$@"\n')
        self.stub('dart', '#!/bin/bash\nexit 0\n')
        self.sdk_stub('aapt2', "#!/bin/bash\nprintf \"package: name='io.gitlabmobile.gitlab_mobile'\\napplication-debuggable\\n\"\n")
        self.sdk_stub('apksigner', "#!/bin/bash\nprintf 'Signer #1 certificate SHA-256 digest: %s\\n' '" + 'f' * 64 + "'\n")
        self.stub('flutter', '''#!/bin/bash
set -eu
if [ "$1" = --version ]; then
  printf '%s\\n' '{"frameworkVersion":"test","frameworkRevision":"test","dartSdkVersion":"test"}'
  exit
fi
if [ "$1" = build ]; then
  printf '%s\\n' "$@" > flutter-args.txt
  mkdir -p build/app/outputs/flutter-apk
  printf 'synthetic apk' > "build/app/outputs/flutter-apk/app-${GITLAB_MOBILE_FLAVOR}-${BUILD_TYPE}.apk"
fi
''')
        self.env = os.environ.copy()
        for name in ('ANDROID_DEBUG_KEYSTORE_B64', 'CI_PIPELINE_IID',
                     'GITLAB_MOBILE_BUILD_TYPE', 'MR7_AI_ASSISTANT', 'MR7_AI_BACKGROUND'):
            self.env.pop(name, None)
        self.env.update(PATH=str(self.root / 'bin') + os.pathsep + self.env['PATH'],
                        CI_PROJECT_DIR=str(self.root),
                        ANDROID_HOME=str(self.root / 'sdk'),
                        GITLAB_MOBILE_SIGNING_PROPERTIES=str(self.root / 'signing.properties'),
                        CI_COMMIT_SHA='a' * 40, CI_COMMIT_SHORT_SHA='a' * 8)

    def stub(self, name, content):
        path = self.root / 'bin' / name
        path.write_text(content)
        path.chmod(0o755)

    def sdk_stub(self, name, content):
        path = self.root / 'sdk/build-tools/36.0.0' / name
        path.write_text(content)
        path.chmod(0o755)

    def build(self, *args, extra_env=None):
        env = dict(self.env)
        env.update(extra_env or {})
        return subprocess.run(['bash', str(SCRIPT), *args], cwd=self.root, env=env,
                              text=True, capture_output=True)

    def read_build(self):
        args = (self.root / 'flutter-args.txt').read_text().splitlines()
        metadata = json.loads((self.root / 'artifacts/build-metadata.json').read_text())
        return args, metadata

    def test_undefined_flags_are_off_even_with_ambient_overrides(self):
        result = self.build(extra_env={'MERGELINE_AI_ASSISTANT': 'true',
                                       'MERGELINE_AI_BACKGROUND': 'true',
                                       'MR7_AI_ASSISTANT': 'true', 'MR7_AI_BACKGROUND': 'true'})
        self.assertEqual(result.returncode, 0, result.stderr)
        args, metadata = self.read_build()
        self.assertIn('--dart-define=MERGELINE_AI_ASSISTANT=false', args)
        self.assertIn('--dart-define=MERGELINE_AI_BACKGROUND=false', args)
        self.assertIs(metadata['ai_assistant'], False)
        self.assertIs(metadata['ai_background'], False)
        self.assertEqual(metadata['apk_sha256'], hashlib.sha256(b'synthetic apk').hexdigest())
        self.assertIsNone(metadata['package'])
        self.assertIsNone(metadata['debuggable'])
        self.assertIsNone(metadata['certificate_sha256'])
        self.assertEqual(metadata['tree'], 'b' * 40)
        self.assertEqual(metadata['lock_sha256'], 'c' * 64)
        self.assertEqual(metadata['capability_sha256'], 'd' * 64)
        self.assertEqual(metadata['policy_sha256'], 'e' * 64)
        self.assertEqual(metadata['channel'], 'gitlab')

    def test_explicit_flags_are_passed_and_recorded(self):
        result = self.build('--ai-assistant', 'true', '--ai-background', 'false')
        self.assertEqual(result.returncode, 0, result.stderr)
        args, metadata = self.read_build()
        self.assertIn('--dart-define=MERGELINE_AI_ASSISTANT=true', args)
        self.assertIn('--dart-define=MERGELINE_AI_BACKGROUND=false', args)
        self.assertIs(metadata['ai_assistant'], True)
        self.assertIs(metadata['ai_background'], False)
        self.assertEqual(metadata['package'], 'io.gitlabmobile.gitlab_mobile')
        self.assertIs(metadata['debuggable'], True)
        self.assertEqual(metadata['certificate_sha256'], 'f' * 64)

    def test_ai_on_requires_apk_inspection_and_matching_package(self):
        self.sdk_stub('aapt2', "#!/bin/bash\nprintf \"package: name='wrong.package'\\n\"\n")
        result = self.build('--ai-assistant', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APK package does not match', result.stderr)
        (self.root / 'sdk/build-tools/36.0.0/apksigner').unlink()
        result = self.build('--ai-assistant', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires Android SDK aapt2 and apksigner', result.stderr)

    def test_background_true_is_recorded_only_with_assistant_true(self):
        result = self.build('--ai-assistant', 'true', '--ai-background', 'true')
        self.assertEqual(result.returncode, 0, result.stderr)
        args, metadata = self.read_build()
        self.assertIn('--dart-define=MERGELINE_AI_BACKGROUND=true', args)
        self.assertIs(metadata['ai_background'], True)
        result = self.build('--ai-background', 'true')
        self.assertNotEqual(result.returncode, 0)

    def test_play_allows_the_assistant_but_not_background(self):
        result = self.build('--flavor', 'play')
        self.assertEqual(result.returncode, 0, result.stderr)
        args, metadata = self.read_build()
        self.assertIn('--dart-define=MERGELINE_AI_ASSISTANT=false', args)
        self.assertIs(metadata['ai_assistant'], False)
        self.assertEqual(metadata['channel'], 'play')
        result = self.build('--flavor', 'play', '--ai-assistant', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APK package does not match build flavor', result.stderr)
        self.sdk_stub('aapt2', "#!/bin/bash\nprintf \"package: name='app.mergeline'\\n\"\n")
        result = self.build('--flavor', 'play', '--ai-assistant', 'true')
        self.assertEqual(result.returncode, 0, result.stderr)
        args, metadata = self.read_build()
        self.assertIn('--dart-define=MERGELINE_AI_ASSISTANT=true', args)
        self.assertIn('--dart-define=MERGELINE_AI_BACKGROUND=false', args)
        self.assertIs(metadata['ai_assistant'], True)
        self.assertIs(metadata['ai_background'], False)
        self.assertEqual(metadata['channel'], 'play')
        result = self.build('--flavor', 'play', '--ai-assistant', 'true', '--ai-background', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Play AI background must remain off.', result.stderr)

    def test_invalid_or_missing_options_fail_before_build(self):
        for args in (('--ai-assistant', 'yes'), ('--ai-background', ''),
                     ('--ai-assistant',), ('--flavor', 'other'), ('--unknown',)):
            with self.subTest(args=args):
                result = self.build(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'flutter-args.txt').exists())


if __name__ == '__main__':
    unittest.main()
