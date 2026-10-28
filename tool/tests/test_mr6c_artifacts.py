import json
import io
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mr6c_artifacts as m


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / 'app.apk'
        self.apk.write_bytes(b'not-an-actual-apk')
        self.tools = {'aapt2': 'aapt2', 'apksigner': 'apksigner', 'apkanalyzer': 'apkanalyzer'}
        self.badging = ("package: name='io.gitlabmobile.gitlab_mobile' versionCode='5' "
                        "versionName='0.5.0' compileSdkVersion='36'\n"
                        "sdkVersion:'24'\ntargetSdkVersion:'36'\napplication-debuggable\n")
        self.signing = ('Verified using v2 scheme (APK Signature Scheme v2): true\n'
                        f'Signer #1 certificate SHA-256 digest: {m.LOCAL_SIGNER}\n')

    def jar(self, classes):
        path = self.root / 'input.jar'
        with zipfile.ZipFile(path, 'w') as zf:
            for name in classes:
                zf.writestr(name.replace('.', '/') + '.class', b'class')
        return path

    def receipt(self, path, *, complete=True, digest=None):
        receipt = self.root / 'inputs.json'
        receipt.write_text(json.dumps({
            'apk_sha256': digest or m.sha256_file(self.apk),
            'complete_program_inputs': complete,
            'inputs': [{'path': path.name, 'sha256': m.hash_input(path)}],
        }))
        return receipt

    def dump(self, path, *, tool='R8', mode='release', classes=None, feature_classes=None):
        def jar_bytes(names):
            data = io.BytesIO()
            with zipfile.ZipFile(data, 'w') as jar:
                for name in names:
                    jar.writestr(name.replace('.', '/') + '.class', b'class')
            return data.getvalue()
        with zipfile.ZipFile(path, 'w') as dump:
            dump.writestr('build.properties', f'tool={tool}\nmode={mode}\n')
            dump.writestr('program.jar', jar_bytes(classes if classes is not None else [m.SERVICE]))
            if feature_classes is not None:
                dump.writestr('feature-1.jar', jar_bytes(feature_classes))

    def captured_runner(self, commands, *, task_state='', make_dump=True):
        def runner(cmd, **kwargs):
            commands.append(cmd)
            flavor = cmd[-1]
            options = shlex.split(kwargs['env']['JAVA_TOOL_OPTIONS'])
            dump_option = next(x for x in options if x.startswith('-D' + m.DUMP_PROPERTY + '='))
            dump_dir = Path(dump_option.split('=', 1)[1])
            self.assertEqual(dump_dir.stat().st_mode & 0o777, 0o700)
            self.assertIn('-Dorg.gradle.daemon=false', kwargs['env']['GRADLE_OPTS'])
            self.assertIn('-Dorg.gradle.caching=false', kwargs['env']['GRADLE_OPTS'])
            kwargs['stdout'].write(f'> Task :app:minify{flavor.capitalize()}ReleaseWithR8{task_state}\n')
            fixture = Path(__file__).with_name('fixtures') / 'mr6c_gradle_9_3_1_r8.txt'
            kwargs['stdout'].write(fixture.read_text().replace('Gitlab', flavor.capitalize()))
            apk = self.root / f'build/app/outputs/flutter-apk/app-{flavor}-release.apk'
            apk.parent.mkdir(parents=True, exist_ok=True)
            apk.write_bytes(('apk-' + flavor).encode())
            mapping = self.root / f'build/app/outputs/mapping/{flavor}Release/mapping.txt'
            mapping.parent.mkdir(parents=True, exist_ok=True)
            mapping.write_text(m.SERVICE + ' -> a.b:\n')
            if make_dump:
                self.dump(dump_dir / 'dump1.zip')
            return type('Result', (), {'returncode': 0})()
        return runner

    def test_uses_c1_per_manifest_verifier_for_each_actual_merged_manifest(self):
        base = self.root / 'build/app/intermediates/merged_manifest/gitlabRelease/a'
        base.mkdir(parents=True)
        path = base / 'AndroidManifest.xml'
        path.write_text('<manifest/>')
        with patch.object(m._c1, 'verify_merged_manifest') as verify:
            found = m.manifests(self.root, 'gitlab', 'release')
        verify.assert_called_once_with(path, 'gitlab')
        self.assertEqual(found[0]['sha256'], m.sha256_file(path))
        with self.assertRaises(m.EvidenceError):
            m.manifests(self.root, 'play', 'release')

    def test_apk_public_metadata_and_signer(self):
        with patch.object(m, 'run', side_effect=[self.badging, self.signing]):
            data = m.apk_info(self.apk, 'gitlab', 'debug', self.tools)
        self.assertEqual(data['package'], m.PACKAGES['gitlab'])
        self.assertEqual(data['version_code'], 5)
        self.assertEqual(data['signer_sha256'], m.LOCAL_SIGNER)
        self.assertEqual(data['verified_schemes'], {'v2': 'true'})
        self.assertEqual(data['sha256'], m.sha256_file(self.apk))

    def test_bad_package_sdk_signer_and_variant_fail_closed(self):
        bad_pairs = [
            (self.badging.replace('gitlab_mobile', 'different'), self.signing),
            (self.badging.replace("compileSdkVersion='36'", "compileSdkVersion='35'"), self.signing),
            (self.badging.replace("sdkVersion:'24'", "sdkVersion:'23'"), self.signing),
            (self.badging, self.signing.replace(m.LOCAL_SIGNER, 'f' * 64)),
            (self.badging, self.signing.replace('true', 'false')),
        ]
        for badging, signing in bad_pairs:
            with self.subTest(badging=badging, signing=signing):
                with patch.object(m, 'run', side_effect=[badging, signing]):
                    with self.assertRaises(m.EvidenceError):
                        m.apk_info(self.apk, 'gitlab', 'debug', self.tools)
        with patch.object(m, 'run', side_effect=[self.badging, self.signing]):
            with self.assertRaises(m.EvidenceError):
                m.apk_info(self.apk, 'gitlab', 'release', self.tools)

    def test_old_and_aapt2_36_sdk_fields_require_exact_values(self):
        for field in ('sdkVersion', 'minSdkVersion'):
            badging = self.badging.replace('sdkVersion:', field + ':')
            with self.subTest(field=field), patch.object(m, 'run', side_effect=[badging, self.signing]):
                data = m.apk_info(self.apk, 'gitlab', 'debug', self.tools)
                self.assertEqual((data['min_sdk'], data['target_sdk']), (24, 36))
            for invalid in (badging.replace(f"{field}:'24'", f"{field}:'23'"),
                            badging.replace("targetSdkVersion:'36'", "targetSdkVersion:'35'"),
                            badging.replace(field + ':', 'unknownSdkVersion:'),
                            badging + "minSdkVersion:'23'\n",
                            badging + "targetSdkVersion:'35'\n"):
                with self.subTest(field=field, invalid=invalid), \
                     patch.object(m, 'run', side_effect=[invalid, self.signing]):
                    with self.assertRaises(m.EvidenceError):
                        m.apk_info(self.apk, 'gitlab', 'debug', self.tools)

    def test_r8_execution_from_recorded_gradle_info_log(self):
        fixture = Path(__file__).with_name('fixtures') / 'mr6c_gradle_9_3_1_r8.txt'
        recorded = fixture.read_text()
        for flavor in ('gitlab', 'play'):
            log = recorded.replace('Gitlab', flavor.capitalize())
            with self.subTest(flavor=flavor):
                self.assertEqual(m.executed_r8_task(io.StringIO(log), flavor),
                                 f':app:minify{flavor.capitalize()}ReleaseWithR8')
                prefixed = ''.join('[ +12 ms] ' + re.sub(r'^\[[^\]]*\]\s*', '', line) + '\n'
                                   for line in log.splitlines())
                self.assertEqual(m.executed_r8_task(io.StringIO(prefixed), flavor),
                                 f':app:minify{flavor.capitalize()}ReleaseWithR8')
        for invalid in ('', recorded * 2,
                        recorded.replace("Task ':app:minifyGitlabReleaseWithR8' is not up-to-date because:", ''),
                        recorded.replace(':app:minifyGitlabReleaseWithR8 (Thread', ':app:unrelated (Thread'),
                        recorded + "Skipping task ':app:minifyGitlabReleaseWithR8' as it is up-to-date.\n",
                        recorded + "Loaded cache entry for task ':app:minifyGitlabReleaseWithR8' with cache key abc\n",
                        *(recorded + f'> Task :app:minifyGitlabReleaseWithR8 {state}\n'
                          for state in ('UP-TO-DATE', 'FROM-CACHE', 'SKIPPED', 'NO-SOURCE', 'FAILED'))):
            with self.subTest(invalid=invalid), self.assertRaises(m.EvidenceError):
                m.executed_r8_task(io.StringIO(invalid), 'gitlab')

    def test_pre_r8_inputs_bound_to_apk_and_scanned_for_qa_classes(self):
        jar = self.jar([m.SERVICE, 'example.Foo'])
        receipt = self.receipt(jar)
        result = m.read_r8_inputs(receipt, m.sha256_file(self.apk))
        self.assertEqual(result['class_count'], 2)
        self.assertEqual(result['completeness'], 'OPERATOR_ATTESTED')
        with self.assertRaisesRegex(m.EvidenceError, 'different APK'):
            m.read_r8_inputs(receipt, '0' * 64)
        receipt = self.receipt(jar, complete=False)
        with self.assertRaisesRegex(m.EvidenceError, 'completeness'):
            m.read_r8_inputs(receipt, m.sha256_file(self.apk))
        receipt = self.receipt(jar)
        jar.write_bytes(b'modified')
        with self.assertRaisesRegex(m.EvidenceError, 'digest mismatch'):
            m.read_r8_inputs(receipt, m.sha256_file(self.apk))
        jar = self.jar([m.SERVICE, m.QA_ADAPTER])
        receipt = self.receipt(jar)
        with self.assertRaisesRegex(m.EvidenceError, 'QA classes'):
            m.read_r8_inputs(receipt, m.sha256_file(self.apk))

    def test_empty_or_service_missing_r8_input_is_not_accepted(self):
        jar = self.jar(['example.Unrelated'])
        with self.assertRaisesRegex(m.EvidenceError, 'AgentRunService'):
            m.read_r8_inputs(self.receipt(jar), m.sha256_file(self.apk))
        receipt = self.root / 'bad.json'
        receipt.write_text('{}')
        with self.assertRaises(m.EvidenceError):
            m.read_r8_inputs(receipt, m.sha256_file(self.apk))

    def test_dex_mapping_follows_renamed_service_and_methods(self):
        mapping = self.root / 'mapping.txt'
        mapping.write_text(m.SERVICE + ' -> a.b:\n'
                           '    1:2:void onTimeout(int,int):4:5 -> c\n'
                           '    void onDestroy() -> d\n')
        calls = []
        def fake_run(args, **_kwargs):
            calls.append(args)
            if 'packages' in args:
                return 'C d 2 0 10 a.b\n'
            method = args[args.index('--method') + 1]
            return f'.method public {method}\n.registers 1\n.end method\n'
        with patch.object(m, 'run', side_effect=fake_run):
            result = m.verify_dex(self.apk, 'release', self.tools, mapping)
        self.assertEqual(result['service_methods'][0]['dex'], 'a.b.c(II)V')
        self.assertEqual(result['service_methods'][1]['dex'], 'a.b.d()V')
        self.assertEqual(result['mapping_sha256'], m.sha256_file(mapping))

    def test_debug_adapter_must_be_a_defined_class_not_a_string(self):
        def fake_run(args, **_kwargs):
            if 'packages' in args:
                return f'C d 1 0 1 {m.SERVICE}\nR x 0 0 0 {m.QA_ADAPTER}\n'
            method = args[args.index('--method') + 1]
            return f'.method public {method}\n.registers 1\n.end method\n'
        with patch.object(m, 'run', side_effect=fake_run):
            with self.assertRaisesRegex(m.EvidenceError, 'does not define'):
                m.verify_dex(self.apk, 'debug', self.tools)

    def test_release_mapping_cannot_hide_qa_class(self):
        mapping = self.root / 'mapping.txt'
        mapping.write_text(m.QA_ADAPTER + ' -> z.a:\n')
        with patch.object(m, 'run', return_value=f'C d 1 0 1 {m.SERVICE}\nC d 1 0 1 z.a\n'):
            with self.assertRaisesRegex(m.EvidenceError, 'QA class'):
                m.verify_dex(self.apk, 'release', self.tools, mapping)

    def test_readback_never_promotes_native_checks_to_dart_aot_proof(self):
        receipts = {'gitlab': self.root / 'gitlab.json', 'play': self.root / 'play.json'}
        with patch.object(m, 'source_head', return_value='a' * 40), \
             patch.object(m._c1, 'verify_android_build_config'), \
             patch.object(m, 'sdk_tools', return_value=self.tools), \
             patch.object(m, 'manifests', return_value=[{'sha256': 'b' * 64}]), \
             patch.object(m, 'apk_info', return_value={'sha256': 'c' * 64}), \
             patch.object(m, 'read_r8_inputs', side_effect=lambda path, _: {
                 'mapping_sha256': None, 'completeness': 'SAME_INVOCATION_CAPTURE',
                 'source_head': 'a' * 40, 'flavor': path.stem}), \
             patch.object(m, 'verify_dex', return_value={'defined_class_count': 2}):
            report = m.readback(self.root, receipts)
        self.assertEqual(report['status'], 'NOT_VERIFIED')
        self.assertEqual(report['dart_aot_qa_handler'], 'NOT_VERIFIED')
        self.assertTrue(all(item['status'] == 'NATIVE_CHECKS_PASS' for item in report['artifacts'].values()))

    def test_readback_rejects_mapping_not_bound_to_receipt(self):
        mapping = self.root / 'build/app/outputs/mapping/gitlabRelease/mapping.txt'
        mapping.parent.mkdir(parents=True)
        mapping.write_text('example.Foo -> a:\n')
        with patch.object(m, 'source_head', return_value='a' * 40), \
             patch.object(m._c1, 'verify_android_build_config'), \
             patch.object(m, 'sdk_tools', return_value=self.tools), \
             patch.object(m, 'manifests', return_value=[]), \
             patch.object(m, 'apk_info', return_value={'sha256': 'c' * 64}), \
             patch.object(m, 'read_r8_inputs', return_value={'mapping_sha256': 'd' * 64}), \
             patch.object(m, 'verify_dex', return_value={}):
            report = m.readback(self.root, {'gitlab': self.root / 'receipt.json'})
        self.assertEqual(report['status'], 'FAIL')
        self.assertIn('mapping is not bound', report['error'])

    def test_legacy_input_attestation_never_yields_native_release_pass(self):
        receipts = {'gitlab': self.root / 'gitlab.json', 'play': self.root / 'play.json'}
        with patch.object(m, 'source_head', return_value='a' * 40), \
             patch.object(m._c1, 'verify_android_build_config'), \
             patch.object(m, 'sdk_tools', return_value=self.tools), \
             patch.object(m, 'manifests', return_value=[]), \
             patch.object(m, 'apk_info', return_value={'sha256': 'c' * 64}), \
             patch.object(m, 'read_r8_inputs', return_value={'mapping_sha256': None,
                                                               'completeness': 'OPERATOR_ATTESTED'}), \
             patch.object(m, 'verify_dex', return_value={}):
            report = m.readback(self.root, receipts)
        self.assertEqual(report['status'], 'NOT_VERIFIED')
        for flavor in ('gitlab', 'play'):
            self.assertEqual(report['artifacts'][flavor + '_debug']['status'], 'NATIVE_CHECKS_PASS')
            self.assertEqual(report['artifacts'][flavor + '_release']['status'], 'NATIVE_CHECKS_UNVERIFIED')

    def test_record_r8_inputs_binds_apk_and_mapping_digests(self):
        jar = self.jar([m.SERVICE])
        mapping = self.root / 'mapping.txt'
        mapping.write_text(m.SERVICE + ' -> a.b:\n')
        receipt = self.root / 'created.json'
        result = m.main(['record-r8-inputs', '--apk', str(self.apk), '--input', str(jar),
                         '--mapping', str(mapping), '--output', str(receipt)])
        self.assertEqual(result, 0)
        doc = json.loads(receipt.read_text())
        self.assertEqual(doc['apk_sha256'], m.sha256_file(self.apk))
        self.assertEqual(doc['mapping_sha256'], m.sha256_file(mapping))
        self.assertEqual(m.read_r8_inputs(receipt, m.sha256_file(self.apk))['class_count'], 1)

    def test_release_build_hashes_both_sides_even_after_failure(self):
        lock = self.root / 'pubspec.lock'
        lock.write_text('approved')
        expected = m.sha256_file(lock)
        output = self.root / 'build.json'
        calls = []
        def runner(cmd, **_kwargs):
            calls.append(cmd)
            lock.write_text('modified')
            return type('Result', (), {'returncode': 1})()
        with patch.object(m, 'source_head', return_value='a' * 40):
            result = m.release_builds(self.root, expected, output, runner=runner)
        entry = result['release_builds']['gitlab']
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(entry['exit_code'], 1)
        self.assertEqual(entry['lock_before'], expected)
        self.assertEqual(entry['lock_after'], m.sha256_file(lock))
        self.assertNotIn('--no-pub', calls[0])
        self.assertEqual(len(calls), 1)
        self.assertEqual(json.loads(output.read_text()), result)
        entry_log = Path(entry['gradle_log'])
        self.assertTrue(entry_log.is_file())
        self.assertEqual(entry_log.stat().st_mode & 0o777, 0o600)
        self.assertEqual(entry['gradle_log_sha256'], m.sha256_file(entry_log))

    def test_release_build_stops_on_lock_drift_even_if_build_succeeded(self):
        lock = self.root / 'pubspec.lock'
        lock.write_text('approved')
        expected = m.sha256_file(lock)
        def runner(_cmd, **_kwargs):
            lock.write_text('changed')
            return type('Result', (), {'returncode': 0})()
        with patch.object(m, 'source_head', return_value='a' * 40):
            result = m.release_builds(self.root, expected, self.root / 'result.json', runner=runner)
        self.assertEqual(result['status'], 'FAIL')
        self.assertIn('changed during build', result['error'])
        self.assertNotIn('play', result['release_builds'])

    def test_release_build_success_runs_both_flavors_without_no_pub(self):
        lock = self.root / 'pubspec.lock'
        lock.write_text('approved')
        commands = []
        with patch.object(m, 'source_head', return_value='a' * 40):
            result = m.release_builds(self.root, m.sha256_file(lock), self.root / 'result.json',
                                      runner=self.captured_runner(commands))
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual([c[-1] for c in commands], ['gitlab', 'play'])
        self.assertTrue(all('--no-pub' not in c for c in commands))
        for flavor in ('gitlab', 'play'):
            entry = result['release_builds'][flavor]
            receipt = Path(entry['r8_receipt'])
            verified = m.read_r8_inputs(receipt, entry['apk_sha256'])
            self.assertEqual(verified['completeness'], 'SAME_INVOCATION_CAPTURE')
            self.assertEqual(verified['flavor'], flavor)
            self.assertEqual(verified['mapping_sha256'], entry['mapping_sha256'])
            log = Path(entry['gradle_log'])
            self.assertIn('is not up-to-date because:', log.read_text())
            self.assertEqual(entry['gradle_log_sha256'], m.sha256_file(log))

    def test_missing_or_cached_r8_build_never_generates_a_receipt(self):
        lock = self.root / 'pubspec.lock'
        lock.write_text('approved')
        for suffix, state, make_dump in (('cached', ' UP-TO-DATE', True),
                                         ('missing', '', False)):
            with self.subTest(suffix=suffix), patch.object(m, 'source_head', return_value='a' * 40):
                result = m.release_builds(self.root, m.sha256_file(lock), self.root / (suffix + '.json'),
                                          runner=self.captured_runner([], task_state=state, make_dump=make_dump))
            self.assertEqual(result['status'], 'FAIL')
            self.assertNotIn('r8_receipt', result['release_builds']['gitlab'])
            self.assertNotIn('play', result['release_builds'])

    def test_r8_dump_selection_ignores_d8_but_rejects_ambiguous_and_qa_feature(self):
        directory = self.root / 'dumps'
        directory.mkdir()
        self.dump(directory / 'dump1.zip', tool='D8')
        self.dump(directory / 'dump2.zip', feature_classes=['example.Feature'])
        path, data = m.select_r8_dump(directory)
        self.assertEqual(path.name, 'dump2.zip')
        self.assertEqual([entry['name'] for entry in data['inputs']], ['program.jar', 'feature-1.jar'])
        self.dump(directory / 'dump3.zip')
        with self.assertRaisesRegex(m.EvidenceError, 'exactly one'):
            m.select_r8_dump(directory)
        (directory / 'dump3.zip').unlink()
        self.dump(directory / 'dump2.zip', feature_classes=[m.QA_ADAPTER])
        with self.assertRaisesRegex(m.EvidenceError, 'QA classes'):
            m.select_r8_dump(directory)

    def test_captured_receipt_rejects_tampered_dump_and_wrong_apk(self):
        lock = self.root / 'pubspec.lock'
        lock.write_text('approved')
        with patch.object(m, 'source_head', return_value='a' * 40):
            result = m.release_builds(self.root, m.sha256_file(lock), self.root / 'result.json',
                                      runner=self.captured_runner([]))
        entry = result['release_builds']['gitlab']
        receipt = Path(entry['r8_receipt'])
        with self.assertRaisesRegex(m.EvidenceError, 'different APK'):
            m.read_r8_inputs(receipt, '0' * 64)
        dump = receipt.parent / 'dump1.zip'
        self.dump(dump, classes=[m.SERVICE, 'example.Other'])
        with self.assertRaisesRegex(m.EvidenceError, 'digest mismatch'):
            m.read_r8_inputs(receipt, entry['apk_sha256'])

    def test_existing_dump_directory_and_inherited_override_fail_before_build(self):
        lock = self.root / 'pubspec.lock'
        lock.write_text('approved')
        (self.root / 'result-r8-gitlab').mkdir()
        commands = []
        with patch.object(m, 'source_head', return_value='a' * 40):
            result = m.release_builds(self.root, m.sha256_file(lock), self.root / 'result.json',
                                      runner=self.captured_runner(commands))
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(commands, [])
        with patch.dict(os.environ, {'JAVA_TOOL_OPTIONS': '-Dcom.android.tools.r8.dumpinputtofile=/tmp/old.zip'}):
            with self.assertRaisesRegex(m.EvidenceError, 'Conflicting inherited'):
                m.r8_build_environment(self.root)


if __name__ == '__main__':
    unittest.main()
