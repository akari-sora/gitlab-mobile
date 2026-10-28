import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mr6c_emulator_checks as m
import mr6c_artifacts as artifacts


class Result:
    def __init__(self, out=b'', code=0):
        self.stdout, self.stderr, self.returncode = out, b'', code


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.pkg = m.PACKAGES['gitlab']
        self.installed = b'original-apk'
        self.fail_install = False
        self.failed_install_once = False
        self.pkg_path = '/data/app/abc/base.apk'
        self.settings = {'sync_mode': 'none', 'timeout': 'null', 'compat': 'absent'}
        self.fail_setting = None
        self.notification_dump = ''
        self.doze = {'battery_updates_stopped': False, 'force_idle': False}
        self.mailbox_present = False
        self.sandbox_results = ['EMPTY']

    def __call__(self, argv, *, stdin=None, check=True, timeout=120):
        self.calls.append((list(argv), stdin))
        args = argv[1:] if argv[:2] == ['adb', 'devices'] else argv[3:]
        output, rc = b'', 0
        if args == ['devices', '-l']:
            output = b'List of devices attached\nemulator-5554 device product:synthetic\n'
        elif args == ['shell', 'getprop', 'ro.kernel.qemu']:
            output = b'1\n'
        elif args == ['emu', 'avd', 'name']:
            output = b'Pixel_9_MR6c_API35\nOK\n'
        elif args == ['shell', 'getprop', 'ro.build.version.sdk']:
            output = b'35\n'
        elif args[:4] == ['shell', 'pm', 'list', 'packages']:
            output = ('package:' + self.pkg + '\n').encode() if self.installed else b''
        elif args[:3] == ['shell', 'pm', 'path']:
            output = ('package:' + self.pkg_path + '\n').encode()
        elif args[:3] == ['shell', 'sha256sum', self.pkg_path]:
            output = (hashlib.sha256(self.installed).hexdigest() + '  ' + self.pkg_path + '\n').encode()
        elif args and args[0] == 'pull':
            Path(args[2]).write_bytes(self.installed)
        elif args and args[0] == 'install':
            if self.fail_install and not self.failed_install_once:
                self.failed_install_once = True
                rc = 1
            else:
                self.installed = Path(args[-1]).read_bytes()
        elif args[:3] == ['shell', 'pidof', self.pkg]:
            rc = 1
        elif args[:4] == ['shell', 'dumpsys', 'activity', 'services']:
            output = b'no services'
        elif args[:3] == ['shell', 'dumpsys', 'notification']:
            output = self.notification_dump.encode()
        elif len(args) == 2 and args[0] == 'shell' and 'listing=$(ls -A files/mr6c_qa)' in args[1]:
            output = b'present' if self.mailbox_present else b'absent'
        elif len(args) == 2 and args[0] == 'shell' and args[1].startswith('su 0 sh -c '):
            value = self.sandbox_results[0] if len(self.sandbox_results) == 1 else self.sandbox_results.pop(0)
            output = value.encode()
        elif args == ['shell', 'dumpsys', 'battery', 'unplug']:
            self.doze['battery_updates_stopped'] = True
        elif args == ['shell', 'dumpsys', 'battery', 'reset']:
            self.doze['battery_updates_stopped'] = False
        elif args == ['shell', 'dumpsys', 'deviceidle', 'force-idle']:
            self.doze['force_idle'] = True
        elif args == ['shell', 'dumpsys', 'deviceidle', 'unforce']:
            self.doze['force_idle'] = False
        elif args == ['shell', 'dumpsys', 'deviceidle']:
            output = b'mState=IDLE' if self.doze['force_idle'] else b'mState=ACTIVE'
        elif args[:3] == ['shell', 'device_config', 'get_sync_disabled_for_tests']:
            output = self.settings['sync_mode'].encode()
        elif args[:4] == ['shell', 'device_config', 'get', 'activity_manager']:
            output = self.settings['timeout'].encode()
        elif args[:3] == ['shell', 'device_config', 'set_sync_disabled_for_tests']:
            self.settings['sync_mode'] = args[3]
        elif args[:3] == ['shell', 'device_config', 'put']:
            if self.fail_setting == 'put':
                self.fail_setting = None
                rc = 1
            else:
                self.settings['timeout'] = args[-1]
        elif args[:3] == ['shell', 'device_config', 'delete']:
            self.settings['timeout'] = 'null'
        elif args[:3] == ['shell', 'am', 'compat']:
            self.settings['compat'] = {'enable': 'enabled', 'disable': 'disabled', 'reset': 'absent'}[args[3]]
        if rc and check:
            raise m.CheckError('fake command failed')
        return Result(output, rc)

    def compat(self):
        return {'exact': True, 'scope': 'package', 'package': self.pkg, 'version_scoped': False,
                'change': 'FGS_INTRODUCE_TIME_LIMITS', 'state': self.settings['compat']}


class HostChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runner = FakeRunner()
        self.adb = m.Adb('emulator-5554', 'Pixel_9_MR6c_API35', 35, 'gitlab', self.runner)
        self.adb.verify_identity()
        identity = {'avd': self.adb.avd, 'api': self.adb.api, 'flavor': self.adb.flavor,
                    'package': self.adb.package, 'synthetic_only': True, 'owner_data_absent': True}
        proof = self.root / 'creation.json'
        proof.write_text(json.dumps(identity))
        receipt = dict(identity, qa_package_may_remain=True,
                       proof={'kind': 'dedicated_avd_creation', 'path': proof.name, 'sha256': m.digest(proof)})
        self.receipt = self.root / 'sandbox.json'
        self.receipt.write_text(json.dumps(receipt))

    def verified(self):
        self.adb.verify_sandbox(self.receipt)
        return self.adb

    def metadata(self, apk):
        return {'package': self.adb.package, 'version_name': '1.0', 'version_code': 5,
                'signer_sha256': 'a' * 64, 'debuggable': Path(apk).read_bytes().startswith(b'qa')}

    def event(self, cmd, name):
        evidence = {}
        if cmd['case'] == 'V9' and name == 'barrier':
            evidence = {'execution_digest': '1' * 64, 'file_digest': '2' * 64,
                        'dispatch_accepted': True, 'journal_flushed': True, 'native_service_active': True,
                        'model_calls': 3, 'mutation_calls': 1}
        return {**cmd, 'event': name, 'outcome': 'RUNNING', 'evidence': evidence}

    def test_offline_plan_and_normal_invocation_never_call_adb(self):
        out = self.root / 'evidence.json'
        args = ['--avd', 'Pixel_9_MR6c_API35', '--api', '35', '--output', str(out)]
        with patch.object(m, 'Runner', side_effect=AssertionError('device accessed')), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.main(args + ['--plan']), 0)
            out.unlink()
            self.assertEqual(m.main(args + ['--serial', 'emulator-5554']), 2)
        report = json.loads(out.read_text())
        self.assertEqual(report['device_os'], 'NOT_RUN')
        self.assertEqual(set(report['cases']), set(m.CASES))
        self.assertTrue(all(v == 'NOT_RUN' for case in report['cases'].values() for v in case.values()))

    def cli_inputs(self):
        candidate = self.root / 'qa.apk'
        candidate.write_bytes(b'qa-apk')
        source = self.root / 'source.json'
        source.write_text('{"revision":"synthetic"}')
        provenance = self.root / 'provenance.json'
        provenance.write_text(json.dumps({'schema': 1, 'flavor': 'gitlab', 'variant': 'debug',
                                          'qa_enabled': True, 'apk_sha256': m.digest(candidate),
                                          'source_metadata_sha256': m.digest(source)}))
        args = ['--serial', 'emulator-5554', '--avd', 'Pixel_9_MR6c_API35', '--api', '35',
                '--output', str(self.root / 'result.json'), '--sandbox-receipt', str(self.receipt),
                '--sandbox-receipt-sha256', m.digest(self.receipt)]
        return args, candidate, source, provenance

    def test_cli_installs_once_restores_and_keeps_unavailable_cases_not_run(self):
        args, candidate, source, provenance = self.cli_inputs()
        args += ['--cases', 'V9', '--qa-apk', str(candidate), '--source-metadata', str(source),
                 '--qa-provenance', str(provenance), '--qa-provenance-sha256', m.digest(provenance),
                 '--work-dir', str(self.root / 'session')]
        def unavailable(adb, cmd):
            return {**cmd, 'event': 'done', 'outcome': 'NOT_RUN', 'evidence': {'reason': 'fixture_unavailable'}}
        with patch.object(m, 'Adb', return_value=self.adb), patch.object(artifacts, 'sdk_tools', return_value={}), \
             patch.object(artifacts, 'apk_info', return_value={}), \
             patch.object(m, 'inspect_public_apk', side_effect=lambda path, flavor, tools: self.metadata(path)), \
             patch.object(m, 'wait_event', side_effect=lambda adb, cmd, expected: self.event(cmd, expected)), \
             patch.object(m, 'wait_phase_result', side_effect=unavailable), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.main(args), 2)
        self.assertEqual(self.runner.installed, b'original-apk')
        report = json.loads((self.root / 'result.json').read_text())
        self.assertEqual(report['restoration'], 'restored')
        self.assertTrue(all(value == 'NOT_RUN' for value in report['cases']['V9'].values()))
        installs = [a for a, _ in self.runner.calls if len(a) > 3 and a[3] == 'install']
        self.assertEqual(len(installs), 2)
        self.assertFalse(any('uninstall' in a or 'clear' in a for a, _ in self.runner.calls))

    def test_cli_provenance_mismatch_never_accesses_device(self):
        args, candidate, source, provenance = self.cli_inputs()
        args += ['--qa-apk', str(candidate), '--source-metadata', str(source),
                 '--qa-provenance', str(provenance), '--qa-provenance-sha256', m.digest(provenance),
                 '--work-dir', str(self.root / 'session')]
        source.write_text('changed')
        with patch.object(m, 'Adb', side_effect=AssertionError('device accessed')), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(m.main(args), 2)
        self.assertEqual(json.loads((self.root / 'result.json').read_text())['status'], 'NOT_RUN')

    def test_live_sandbox_unknown_or_nonempty_before_install_never_mutates(self):
        for answers in (['NONEMPTY'], ['UNKNOWN'], [''], ['EMPTY', 'NONEMPTY']):
            with self.subTest(answers=answers):
                args, candidate, source, provenance = self.cli_inputs()
                work = self.root / ('session-' + str(len(answers)) + '-' + (answers[-1] or 'empty'))
                output = self.root / 'result.json'
                if output.exists():
                    output.unlink()
                args += ['--cases', 'V9', '--qa-apk', str(candidate), '--source-metadata', str(source),
                         '--qa-provenance', str(provenance), '--qa-provenance-sha256', m.digest(provenance),
                         '--work-dir', str(work)]
                self.runner.sandbox_results = list(answers)
                self.runner.calls.clear()
                with patch.object(m, 'Adb', return_value=self.adb), patch.object(artifacts, 'sdk_tools', return_value={}), \
                     patch.object(artifacts, 'apk_info', return_value={}), \
                     patch.object(m, 'inspect_public_apk', side_effect=lambda path, flavor, tools: self.metadata(path)), \
                     contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(m.main(args), 2)
                self.assertEqual(json.loads(output.read_text())['status'], 'NOT_RUN')
                self.assertFalse(any('install' in a or 'force-stop' in a or 'uninstall' in a for a, _ in self.runner.calls))
                scans = [a for a, _ in self.runner.calls if len(a) > 4 and a[4].startswith('su 0 sh -c ')]
                self.assertEqual(len(scans), len(answers))
                self.assertIn('/data/user_de/0/', scans[0][4])
                self.assertIn('/Android/obb/', scans[0][4])
                if len(answers) == 2:
                    saved = json.loads((work / 'restore.json').read_text())
                    self.assertEqual(saved['state'], 'prepared_no_install')
                    self.assertEqual(saved['reason'], 'live_sandbox_refused')
                    self.assertFalse(saved['restore_pending'])
                    self.assertTrue((work / 'original.apk').is_file())

    def test_sandbox_scan_shell_allows_empty_directories_and_rejects_nodes(self):
        sandbox = self.root / 'scan'
        (sandbox / 'cache' / 'nested').mkdir(parents=True)
        (sandbox / 'code_cache').mkdir()
        def scan():
            result = subprocess.run(['sh', '-c', m.sandbox_scan_script(), 'sh', str(sandbox)],
                                    capture_output=True, text=True, check=True)
            return result.stdout.strip()
        self.assertEqual(scan(), 'EMPTY')
        file = sandbox / 'cache' / 'nested' / 'sensitive-name'
        file.write_text('never output this')
        self.assertEqual(scan(), 'NONEMPTY')
        file.unlink()
        (sandbox / 'cache' / 'link').symlink_to(sandbox / 'code_cache', target_is_directory=True)
        self.assertEqual(scan(), 'NONEMPTY')

    def test_cli_retained_mailbox_fails_before_case_reset_and_restores(self):
        args, candidate, source, provenance = self.cli_inputs()
        args += ['--cases', 'V9', '--qa-apk', str(candidate), '--source-metadata', str(source),
                 '--qa-provenance', str(provenance), '--qa-provenance-sha256', m.digest(provenance),
                 '--work-dir', str(self.root / 'session')]
        self.runner.mailbox_present = True
        with patch.object(m, 'Adb', return_value=self.adb), patch.object(artifacts, 'sdk_tools', return_value={}), \
             patch.object(artifacts, 'apk_info', return_value={}), \
             patch.object(m, 'inspect_public_apk', side_effect=lambda path, flavor, tools: self.metadata(path)), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(m.main(args), 2)
        report = json.loads((self.root / 'result.json').read_text())
        self.assertEqual((report['status'], report['reason'], report['failure_phase']),
                         ('FAIL', 'attempt_failed', 'mailbox_preflight'))
        self.assertFalse(report['restoration_pending'])
        self.assertEqual(report['cases']['V9']['task_manager_stop'], 'NOT_RUN')
        self.assertEqual(self.runner.installed, b'original-apk')
        self.assertFalse(any('run-as' in ' '.join(a) and 'cat >' in ' '.join(a) for a, _ in self.runner.calls))

    def test_cli_case_deadline_is_fail_and_error_is_sanitized(self):
        args, candidate, source, provenance = self.cli_inputs()
        args += ['--cases', 'V9', '--qa-apk', str(candidate), '--source-metadata', str(source),
                 '--qa-provenance', str(provenance), '--qa-provenance-sha256', m.digest(provenance),
                 '--work-dir', str(self.root / 'session')]
        err = io.StringIO()
        with patch.object(m, 'Adb', return_value=self.adb), patch.object(artifacts, 'sdk_tools', return_value={}), \
             patch.object(artifacts, 'apk_info', return_value={}), \
             patch.object(m, 'inspect_public_apk', side_effect=lambda path, flavor, tools: self.metadata(path)), \
             patch.object(m, 'wait_event', side_effect=m.CheckError('secret-deadline-details')), \
             contextlib.redirect_stderr(err):
            self.assertEqual(m.main(args), 2)
        report = json.loads((self.root / 'result.json').read_text())
        self.assertEqual(report['status'], 'FAIL')
        self.assertEqual(report['cases']['V9']['task_manager_stop'], 'FAIL')
        self.assertFalse(report['restoration_pending'])
        self.assertNotIn('secret-deadline-details', err.getvalue())
        self.assertNotIn('secret-deadline-details', json.dumps(report))

    def test_cli_restore_failure_marks_pending(self):
        args, candidate, source, provenance = self.cli_inputs()
        args += ['--cases', 'V9', '--qa-apk', str(candidate), '--source-metadata', str(source),
                 '--qa-provenance', str(provenance), '--qa-provenance-sha256', m.digest(provenance),
                 '--work-dir', str(self.root / 'session')]
        with patch.object(m, 'Adb', return_value=self.adb), patch.object(artifacts, 'sdk_tools', return_value={}), \
             patch.object(artifacts, 'apk_info', return_value={}), \
             patch.object(m, 'inspect_public_apk', side_effect=lambda path, flavor, tools: self.metadata(path)), \
             patch.object(m, 'run_cases', side_effect=m.CheckError('case')), \
             patch.object(m.InstallSession, 'restore', side_effect=m.CheckError('restore')), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(m.main(args), 2)
        report = json.loads((self.root / 'result.json').read_text())
        self.assertEqual((report['status'], report['reason']), ('FAIL', 'restoration_failed'))
        self.assertTrue(report['restoration_pending'])
        self.assertTrue(json.loads((self.root / 'session' / 'restore.json').read_text())['restore_pending'])

    def test_cli_recovery_verifies_receipt_and_restores_original(self):
        args, candidate, _, _ = self.cli_inputs()
        self.verified()
        session = m.InstallSession(self.adb, self.root / 'session', self.metadata)
        session.prepare(candidate)
        session.install(candidate)
        args += ['--recover', '--restore-receipt', str(session.receipt),
                 '--restore-receipt-sha256', m.digest(session.receipt)]
        with patch.object(m, 'Adb', return_value=self.adb), patch.object(artifacts, 'sdk_tools', return_value={}), \
             patch.object(m, 'inspect_public_apk', side_effect=lambda path, flavor, tools: self.metadata(path)), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.main(args), 2)
        self.assertEqual(self.runner.installed, b'original-apk')
        self.assertFalse(json.loads(session.receipt.read_text())['restore_pending'])
        self.assertEqual(json.loads((self.root / 'result.json').read_text())['restoration'], 'restored')

    def test_cli_recovery_bad_receipt_hash_does_not_touch_device(self):
        args, candidate, _, _ = self.cli_inputs()
        self.verified()
        session = m.InstallSession(self.adb, self.root / 'session', self.metadata)
        session.prepare(candidate)
        session.install(candidate)
        args += ['--recover', '--restore-receipt', str(session.receipt), '--restore-receipt-sha256', '0' * 64]
        with patch.object(m, 'Adb', side_effect=AssertionError('device accessed')), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(m.main(args), 2)
        self.assertTrue(json.loads(session.receipt.read_text())['restore_pending'])

    def test_v9_driver_requires_matching_journal_and_specific_recovery_evidence(self):
        self.verified()
        report = m.plan('gitlab', 35, ['V9'])
        def phase(adb, cmd):
            if cmd['phase'] == 'prepare':
                return self.event(cmd, 'barrier')
            evidence = {'execution_digest': '1' * 64, 'file_digest': '3' * 64,
                        'uncertain': True, 'isolated': True, 'permit_absent': True,
                        'persistent_accounts_verified': True, 'model_calls': 0, 'mutation_calls': 0}
            return {**cmd, 'event': 'done', 'outcome': 'PASS', 'evidence': evidence}
        with patch.object(self.adb, 'process_gone', side_effect=[True, False, True, True]), \
             patch.object(m, 'service_gone', side_effect=[False, True, True, True]), \
             patch.object(m, 'wait_event', side_effect=lambda adb, cmd, expected: self.event(cmd, expected)), \
             patch.object(m, 'wait_phase_result', side_effect=phase):
            m.run_cases(self.adb, ['V9'], report, self.root / 'matrix.json', session='s')
        self.assertEqual(report['cases']['V9']['recents_swipe'], 'NOT_RUN')
        self.assertEqual(report['cases']['V9']['settings_force_stop'], 'NOT_RUN')
        self.assertEqual(report['cases']['V9']['task_manager_stop'], 'NOT_VERIFIED')
        evidence = report['case_evidence']['task_manager_stop']
        self.assertEqual(evidence['recovery_subcheck'], 'PASS')
        self.assertEqual(report['device_os'], 'PARTIAL')
        self.assertEqual(report['status'], 'PARTIAL')
        self.assertNotEqual(evidence['file_digest_before'], evidence['file_digest_after'])
        self.assertEqual(evidence['prepare_model_calls'], 3)
        cmd = m.command('s', 'V9', 'task_manager_stop', 'recover', 2)
        invalid = phase(self.adb, cmd)
        invalid['evidence']['mutation_calls'] = 1
        with self.assertRaises(m.CheckError):
            m.validate_event(invalid, cmd, 'done')

    def test_v9_recovery_pass_requires_service_absent(self):
        self.verified()
        report = m.plan('gitlab', 35, ['V9'])
        def phase(adb, cmd):
            if cmd['phase'] == 'prepare':
                return self.event(cmd, 'barrier')
            return {**cmd, 'event': 'done', 'outcome': 'PASS', 'evidence': {
                'execution_digest': '1' * 64, 'file_digest': '3' * 64, 'uncertain': True,
                'isolated': True, 'permit_absent': True, 'persistent_accounts_verified': True,
                'model_calls': 0, 'mutation_calls': 0}}
        with patch.object(self.adb, 'process_gone', side_effect=[True, False, True, True]), \
             patch.object(m, 'service_gone', side_effect=[False, True, True, False]), \
             patch.object(m, 'wait_event', side_effect=lambda adb, cmd, expected: self.event(cmd, expected)), \
             patch.object(m, 'wait_phase_result', side_effect=phase), self.assertRaises(m.CheckError):
            m.run_cases(self.adb, ['V9'], report, self.root / 'matrix.json', session='s')
        self.assertEqual(report['cases']['V9']['task_manager_stop'], 'NOT_RUN')

    def test_v9_not_run_after_termination_is_failure(self):
        self.verified()
        report = m.plan('gitlab', 35, ['V9'])
        def phase(adb, cmd):
            if cmd['phase'] == 'prepare':
                return self.event(cmd, 'barrier')
            return {**cmd, 'event': 'done', 'outcome': 'NOT_RUN', 'evidence': {'reason': 'fixture_unavailable'}}
        with patch.object(self.adb, 'process_gone', side_effect=[True, False, True, True]), \
             patch.object(m, 'service_gone', side_effect=[False, True, True]), \
             patch.object(m, 'wait_event', side_effect=lambda adb, cmd, expected: self.event(cmd, expected)), \
             patch.object(m, 'wait_phase_result', side_effect=phase), self.assertRaises(m.CheckError):
            m.run_cases(self.adb, ['V9'], report, self.root / 'matrix.json', session='s')
        self.assertEqual(report['cases']['V9']['task_manager_stop'], 'NOT_RUN')

    def test_identity_strict_serial_and_explicit_avd_api(self):
        for serial in ['emulator-abc', 'emulator-5554;bad', '5554', 'physical']:
            with self.subTest(serial=serial), self.assertRaises(m.CheckError):
                m.Adb(serial, 'Pixel_9', 35, 'gitlab', self.runner)
        with self.assertRaises(m.CheckError):
            m.Adb('emulator-5554', 'Pixel_9_MR6c_API34', 35, 'gitlab', self.runner)
        self.assertEqual(self.runner.calls[0][0], ['adb', 'devices', '-l'])
        self.assertIn(['adb', '-s', 'emulator-5554', 'emu', 'avd', 'name'], [c[0] for c in self.runner.calls])

    def test_sandbox_proof_before_mutation_and_flavor_bound(self):
        with self.assertRaises(m.CheckError):
            self.adb.reset_case()
        receipt = json.loads(self.receipt.read_text())
        receipt['flavor'] = 'play'
        self.receipt.write_text(json.dumps(receipt))
        with self.assertRaises(m.CheckError):
            self.adb.verify_sandbox(self.receipt)
        self.assertFalse(any('force-stop' in args for args, _ in self.runner.calls))

    def test_mailbox_has_atomic_remote_shell_quoted_and_stdin(self):
        self.verified()
        cmd = m.command('session1', 'V9', 'task_manager_stop', 'prepare', 1)
        self.adb.write_mailbox('command', cmd)
        found = [(a, data) for a, data in self.runner.calls if any('sh -c' in part for part in a)]
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][0][-1], "run-as io.gitlabmobile.gitlab_mobile sh -c 'cat > files/mr6c_qa/command.tmp'")
        self.assertEqual(json.loads(found[0][1]), cmd)
        with self.assertRaises(m.CheckError):
            self.adb.write_mailbox('../../x', cmd)

    def test_invalid_command_marker_fails_before_an_old_ready_can_be_read(self):
        marker = {'schema': 1, 'event': 'error', 'outcome': 'FAIL', 'reason': 'invalid_command'}
        with patch.object(self.adb, 'call', return_value=Result(json.dumps(marker).encode())) as call:
            with self.assertRaisesRegex(m.CheckError, 'rejected a command'):
                self.adb.event()
            self.assertEqual(call.call_count, 1)
            self.assertEqual(call.call_args.args[-1], 'files/mr6c_qa/error.json')
        calls = [Result(b'', 1), Result(b'{"event":"ready"}')]
        with patch.object(self.adb, 'call', side_effect=calls):
            self.assertEqual(self.adb.event(), {'event': 'ready'})

    def test_event_schema_rejects_boolean_integers_and_private_error_fields(self):
        cmd = m.command('session1', 'V9', 'task_manager_stop', 'prepare', 1)
        for field in ('schema', 'sequence'):
            event = self.event(cmd, 'ready')
            event[field] = True
            with self.subTest(field=field), self.assertRaises(m.CheckError):
                m.validate_event(event, cmd, 'ready')
        error = {**cmd, 'event': 'error', 'outcome': 'FAIL',
                 'evidence': {'reason': 'io_error', 'token': 'must-not-export'}}
        with self.assertRaises(m.CheckError):
            m.validate_event(error, cmd, 'error')

    def test_prepare_recover_no_reset_or_install_and_next_case_resets(self):
        self.verified()
        seq = m.CaseSequence(self.adb, 'nonce1')
        p = seq.prepare('V9', 'task_manager_stop')
        with self.assertRaises(m.CheckError):
            seq.accepted_barrier(self.event(p, 'barrier'))
        seq.accepted_ready(self.event(p, 'ready'))
        seq.accepted_barrier(self.event(p, 'barrier'), '1' * 64, '2' * 64)
        seq.terminate('task_manager_stop')
        mark = len(self.runner.calls)
        rec = seq.recover()
        commands = [a for a, _ in self.runner.calls[mark:]]
        self.assertFalse(any('install' in a or 'uninstall' in a or 'force-stop' in a for a in commands))
        self.assertEqual(rec['phase'], 'recover')
        with self.assertRaises(m.CheckError):
            seq.accepted_ready(self.event(p, 'ready'))
        seq.accepted_ready(self.event(rec, 'ready'))
        self.assertEqual(seq.check_journal('1' * 64, '3' * 64),
                         {'execution_digest': '1' * 64, 'file_digest_before': '2' * 64,
                          'file_digest_after': '3' * 64})
        with self.assertRaises(m.CheckError):
            seq.check_journal('2' * 64, '2' * 64)
        seq.finish()
        seq.prepare('V1', 'screen_off')
        resets = [a for a, _ in self.runner.calls if 'force-stop' in a]
        self.assertEqual(len(resets), 2)
        self.assertTrue(any(a[-4:] == ['cmd', 'activity', 'stop-app', self.adb.package] for a, _ in self.runner.calls))

    def test_v9_recents_manual_and_force_stop_separate(self):
        self.verified()
        for variant in ('recents_swipe', 'settings_force_stop'):
            seq = m.CaseSequence(self.adb, 's')
            p = seq.prepare('V9', variant)
            seq.accepted_ready(self.event(p, 'ready'))
            seq.accepted_barrier(self.event(p, 'barrier'))
            before = len(self.runner.calls)
            seq.terminate(variant)
            calls = [a for a, _ in self.runner.calls[before:]]
            self.assertEqual(any('force-stop' in a for a in calls), variant == 'settings_force_stop')
            self.assertFalse(any('stop-app' in a for a in calls))

    def test_notification_history_is_not_active_and_any_approval_after_fails(self):
        pkg = self.adb.package
        raw = ('  Notification List:\n'
               f'    NotificationRecord(x pkg={pkg} id=6201)\n'
               f'    NotificationRecord(y pkg={pkg} id=6301)\n'
               '  Historical notifications:\n'
               f'    NotificationRecord(z pkg={pkg} id=6202)\n')
        self.assertEqual(m.notification_ids(raw, pkg), {6201, 6301})
        with self.assertRaises(m.CheckError):
            m.verify_notifications({6201, 6301}, {6201, 6301}, {6202, 6301})
        self.assertEqual(m.verify_notifications({6201, 6301}, {6201, 6301}, {6301})['after'], [6301])

    def test_install_failure_is_not_retried_and_receipt_is_pending(self):
        self.verified()
        qa = self.root / 'qa.apk'
        qa.write_bytes(b'qa-apk')
        session = m.InstallSession(self.adb, self.root / 'session', self.metadata)
        session.prepare(qa)
        self.runner.fail_install = True
        with self.assertRaises(m.CheckError):
            session.install(qa)
        self.assertTrue(json.loads(session.receipt.read_text())['restore_pending'])
        self.assertEqual(sum(a[3:4] == ['install'] for a, _ in self.runner.calls), 1)
        self.assertFalse(any('uninstall' in a or 'clear' in a for a, _ in self.runner.calls))
        session.restore()
        self.assertEqual(json.loads(session.receipt.read_text())['state'], 'restored')

    def test_successful_install_restores_original_on_interrupt(self):
        self.verified()
        qa = self.root / 'qa.apk'
        qa.write_bytes(b'qa-apk')
        session = m.InstallSession(self.adb, self.root / 'session', self.metadata)
        session.prepare(qa)
        def interrupted():
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            session.run(qa, interrupted)
        self.assertEqual(self.runner.installed, b'original-apk')
        self.assertEqual(json.loads(session.receipt.read_text())['state'], 'restored')
        installs = [a for a, _ in self.runner.calls if len(a) > 3 and a[3] == 'install']
        self.assertEqual(len(installs), 2)
        self.assertTrue(all(a[4] == '-r' for a in installs))

    def test_absent_package_requires_dedicated_avd_and_closes_without_uninstall(self):
        self.verified()
        self.runner.installed = None
        qa = self.root / 'qa.apk'
        qa.write_bytes(b'qa-apk')
        session = m.InstallSession(self.adb, self.root / 'session', self.metadata)
        session.prepare(qa, fixed_absent_version=5)
        session.run(qa, lambda: None)
        self.assertEqual(json.loads(session.receipt.read_text())['state'], 'qa_retained_dedicated_avd_closed')
        self.assertTrue(any(a[-2:] == ['emu', 'kill'] for a, _ in self.runner.calls))
        self.assertFalse(any('uninstall' in a for a, _ in self.runner.calls))

    def test_absent_package_restore_rejects_replaced_apk_without_mutation(self):
        self.verified()
        self.runner.installed = None
        qa = self.root / 'qa.apk'
        qa.write_bytes(b'qa-apk')
        session = m.InstallSession(self.adb, self.root / 'session', self.metadata)
        session.prepare(qa, fixed_absent_version=5)
        session.install(qa)
        self.runner.installed = b'replaced-apk'
        mark = len(self.runner.calls)
        with self.assertRaises(m.CheckError):
            session.restore()
        calls = [args for args, _ in self.runner.calls[mark:]]
        self.assertFalse(any('force-stop' in a or 'kill' in a or 'install' in a or 'uninstall' in a for a in calls))
        self.assertTrue(json.loads(session.receipt.read_text())['restore_pending'])

    def test_doze_restores_battery_and_idle_on_interrupt(self):
        self.verified()
        state = m.DozeSettings(self.adb, self.root / 'doze.json', lambda: self.runner.doze.copy())
        def interrupted():
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            state.run(interrupted)
        self.assertEqual(self.runner.doze, {'battery_updates_stopped': False, 'force_idle': False})
        self.assertFalse(json.loads(state.receipt.read_text())['restore_pending'])
        self.assertTrue(any(a[-3:] == ['dumpsys', 'deviceidle', 'unforce'] for a, _ in self.runner.calls))
        self.assertTrue(any(a[-3:] == ['dumpsys', 'battery', 'reset'] for a, _ in self.runner.calls))

    def test_timeout_restores_on_interrupt_and_records_pending_if_restore_fails(self):
        self.verified()
        state = m.TimeoutSettings(self.adb, self.root / 'settings.json', self.runner.compat)
        def interrupted():
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            state.run(interrupted)
        self.assertEqual(self.runner.settings, {'sync_mode': 'none', 'timeout': 'null', 'compat': 'absent'})
        self.assertFalse(json.loads(state.receipt.read_text())['restore_pending'])

    def test_v7_requires_retained_notification_ids_before_recover(self):
        self.verified()
        pkg = self.adb.package
        self.runner.notification_dump = ('  Notification List:\n'
            f'    NotificationRecord(x pkg={pkg} id=6201)\n'
            f'    NotificationRecord(y pkg={pkg} id=6301)\n')
        seq = m.CaseSequence(self.adb, 's')
        cmd = seq.prepare('V7', 'notification_restart')
        seq.accepted_ready(self.event(cmd, 'ready'))
        seq.accepted_barrier(self.event(cmd, 'barrier'))
        with self.assertRaises(m.CheckError):
            seq.terminate('notification_restart')
        seq.notification_baseline()
        self.runner.notification_dump = '  Notification List:\n'
        with self.assertRaises(m.CheckError):
            seq.terminate('notification_restart')
        with self.assertRaises(m.CheckError):
            seq.recover()

    def test_signer_version_mismatch_prevents_install(self):
        self.verified()
        qa = self.root / 'qa.apk'
        qa.write_bytes(b'qa')
        def bad(path):
            data = self.metadata(path)
            if Path(path).name == 'qa.apk':
                data['version_code'] = 9
            return data
        with self.assertRaises(m.CheckError):
            m.InstallSession(self.adb, self.root / 'session', bad).prepare(qa)
        self.assertFalse(any('install' in a for a, _ in self.runner.calls))

    def test_timeout_preserves_null_and_restores_after_failure(self):
        self.verified()
        state = m.TimeoutSettings(self.adb, self.root / 'settings.json', self.runner.compat)
        self.runner.fail_setting = 'put'
        with self.assertRaises(m.CheckError):
            state.begin()
        doc = json.loads((self.root / 'settings.json').read_text())
        self.assertFalse(doc['restore_pending'])
        self.assertEqual(self.runner.settings, {'sync_mode': 'none', 'timeout': 'null', 'compat': 'absent'})
        calls = [a for a, _ in self.runner.calls]
        first_mutation = next(i for i, c in enumerate(calls) if c[3:6] == ['shell', 'am', 'compat'])
        self.assertTrue(any(c[3:6] == ['shell', 'device_config', 'get'] for c in calls[:first_mutation]))
        self.assertTrue(any(c[3:6] == ['shell', 'device_config', 'delete'] for c in calls))

    def test_timeout_rejects_ambiguous_or_version_scoped_compat(self):
        self.verified()
        for reader in [lambda: 'enabled', lambda: dict(self.runner.compat(), version_scoped=True),
                       lambda: dict(self.runner.compat(), state='disabled')]:
            with self.subTest(reader=reader):
                state = m.TimeoutSettings(self.adb, self.root / 'not-written.json', reader)
                with self.assertRaises(m.CheckError):
                    state.begin()
                self.assertFalse(state.receipt.exists())
        self.assertFalse(any(a[3:6] == ['shell', 'am', 'compat'] for a, _ in self.runner.calls))

    def test_v1_requires_full_host_and_device_timestamp_series(self):
        data = {'host_duration_seconds': 720, 'device_duration_seconds': 720,
                'host_sse_times_seconds': list(range(0, 721, 5)),
                'device_sse_times_seconds': list(range(0, 721, 5)),
                'host_gitlab_times_seconds': list(range(0, 721, 30)),
                'device_gitlab_times_seconds': list(range(0, 721, 30)),
                'service_alive': True, 'dart_alive': True, 'socket_tls_verified': True,
                'mode': 'doze', 'verified_device_idle': True}
        self.assertEqual(m.validate_v1(data)['network'], 'PASS')
        for key, value in [('device_sse_times_seconds', [360]),
                           ('device_duration_seconds', 719),
                           ('device_sse_times_seconds', list(range(20, 721, 5))),
                           ('device_sse_times_seconds', list(range(0, 700, 5))),
                           ('device_gitlab_times_seconds', [30, 0, 60]),
                           ('host_sse_times_seconds', list(range(0, 721, 10))),
                           ('verified_device_idle', False)]:
            with self.subTest(key=key, value=value), self.assertRaises(m.CheckError):
                m.validate_v1(dict(data, **{key: value}))

    def test_v3_counts_failed_attempts_and_rejects_expired_consume(self):
        sample = {'elapsed_ms': 100, 'outcome': 'consumed', 'flushed': False, 'rollback': 'none', 'reason': 'none'}
        failure = {'elapsed_ms': 1000, 'outcome': 'expired', 'flushed': True, 'rollback': 'failure', 'reason': 'ttl'}
        samples = [sample.copy() for _ in range(99)] + [failure]
        metrics = {key: list(samples) for key in ('channel', 'model', 'rest', 'graph')}
        result = m.validate_v3(metrics)
        self.assertEqual(result['rest']['denominator'], 100)
        self.assertEqual(result['rest']['within_limit_count'], 99)
        self.assertEqual(result['rest']['ttl_expired'], 1)
        self.assertEqual(result['rest']['rollback_failure'], 1)
        bad = dict(sample, elapsed_ms=1000)
        metrics['model'] = [sample] * 99 + [bad]
        with self.assertRaises(m.CheckError):
            m.validate_v3(metrics)


if __name__ == '__main__':
    unittest.main()
