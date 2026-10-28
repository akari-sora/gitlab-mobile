#!/usr/bin/env python3
"""MR6c host coordinator. --plan is offline; device work needs explicit
identity, sandbox and artifact provenance. Unsupported cases stay NOT_RUN.
Host tests do not establish device results.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import secrets

PACKAGES = {'gitlab': 'io.gitlabmobile.gitlab_mobile', 'play': 'app.mergeline'}
ACTIVITY = 'io.gitlabmobile.gitlab_mobile.MainActivity'
AVDS = {'Pixel_9', 'Pixel_9_MR6c_API34', 'Pixel_9_MR6c_API35', 'Pixel_9_MR6c_API36'}
CASES = {
    'V1': ('screen_off', 'doze'),
    'V2': ('synthetic_delivered', 'synthetic_dropped', 'system_delivered', 'system_dropped', 'system_default_six_hours'),
    'V3': ('idle', 'screen_off', 'doze', 'late_reply', 'slow_flush'),
    'V4': ('background_lost_callback',),
    'V5': ('invalidate_before_acquire', 'reply_then_invalidate', 'graph_preflight', 'flush_guard', 'ticket_reuse'),
    'V6': ('permission', 'lock_screen', 'tap_language'),
    'V7': ('swipe_update', 'notification_restart'),
    'V8': ('notification_stop', 'app_lock', 'dropped_callback', 'engine_detach', 'activity_destroy'),
    'V9': ('recents_swipe', 'task_manager_stop', 'settings_force_stop'),
    'V10': ('detail', 'non_home', 'root_active', 'paused', 'no_work', 'app_lock', 'predictive_back', 'api24_30'),
    'V11': ('background_pause', 'start_denied', 'fgs_timeout'),
    'V12': ('switch_account', 'sign_out', 'remove_entry_one', 'remove_entry_two'),
}
SAFE_ID = re.compile(r'^[A-Za-z0-9._:-]{1,128}$')
SHA256 = re.compile(r'^[0-9a-f]{64}$')


class CheckError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CheckError(message)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    with temp.open('w', encoding='utf-8') as f:
        json.dump(value, f, sort_keys=True, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)
    directory = os.open(str(path.parent), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def selected_cases(raw):
    if raw == 'all':
        return list(CASES)
    ids = raw.split(',')
    require(ids and len(ids) == len(set(ids)) and all(x in CASES for x in ids), 'invalid cases')
    return ids


def plan(flavor, api, ids):
    require(flavor in PACKAGES and api in (34, 35, 36), 'invalid flavor or API')
    return {'status': 'NOT_RUN', 'device_os': 'NOT_RUN', 'network': 'NOT_VERIFIED',
            'reason': 'case_drivers_unavailable', 'flavor': flavor, 'package': PACKAGES[flavor],
            'api': api, 'cases': {case: {name: 'NOT_RUN' for name in CASES[case]} for case in ids}}


class Runner:
    def __call__(self, argv, *, stdin=None, check=True, timeout=120):
        try:
            result = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise CheckError(f'command could not complete: {type(exc).__name__}') from exc
        if check and result.returncode:
            raise CheckError(f'{Path(argv[0]).name} command exited {result.returncode}')
        return result


def sandbox_scan_script():
    """Presence-only shell program; its positional arguments are scan roots."""
    return ('for p in "$@"; do '
            'if [ -L "$p" ]; then echo NONEMPTY; exit 0; fi; '
            'parent="$p"; while [ ! -e "$parent" ]; do '
            'parent=${parent%/*}; [ -n "$parent" ] || { echo UNKNOWN; exit 0; }; done; '
            '[ -d "$parent" ] && [ -r "$parent" ] && [ -x "$parent" ] && '
            'ls -A "$parent" >/dev/null 2>&1 || { echo UNKNOWN; exit 0; }; '
            'if [ -e "$p" ]; then [ -d "$p" ] && [ -r "$p" ] && [ -x "$p" ] || { echo UNKNOWN; exit 0; }; '
            'entry=$(find "$p" -mindepth 1 ! -type d -print -quit 2>/dev/null) || { echo UNKNOWN; exit 0; }; '
            '[ -z "$entry" ] || { echo NONEMPTY; exit 0; }; fi; done; echo EMPTY')


class Adb:
    def __init__(self, serial, avd, api, flavor, runner=None):
        require(re.fullmatch(r'emulator-[0-9]+', serial) is not None, 'invalid emulator serial')
        require(avd in AVDS and api in (34, 35, 36), 'AVD/API not allowed')
        require(avd == 'Pixel_9' or avd == f'Pixel_9_MR6c_API{api}', 'AVD/API mismatch')
        require(flavor in PACKAGES, 'invalid flavor')
        self.serial, self.avd, self.api, self.flavor = serial, avd, api, flavor
        self.package = PACKAGES[flavor]
        self.runner = runner or Runner()
        self.sandbox_verified = False
        self.identity_verified = False
        self.sandbox_digest = None
        self.qa_package_may_remain = False
        self.proof_kind = None

    def call(self, *args, stdin=None, check=True, timeout=120):
        return self.runner(['adb', '-s', self.serial, *args], stdin=stdin, check=check, timeout=timeout)

    def text(self, *args, check=True):
        return self.call(*args, check=check).stdout.decode('utf-8', errors='strict').strip()

    def verify_identity(self):
        devices = self.runner(['adb', 'devices', '-l'], stdin=None, check=True, timeout=120).stdout.decode()
        matches = [line.split() for line in devices.splitlines() if line.split() and line.split()[0] == self.serial]
        require(len(matches) == 1 and len(matches[0]) >= 2 and matches[0][1] == 'device', 'serial missing, offline, or ambiguous')
        qemu = self.text('shell', 'getprop', 'ro.kernel.qemu')
        lines = self.text('emu', 'avd', 'name').splitlines()
        require(lines and lines[0].strip() == self.avd and all(line.strip() in ('OK', '') for line in lines[1:]), 'AVD readback mismatch')
        sdk = self.text('shell', 'getprop', 'ro.build.version.sdk')
        require(qemu == '1' and sdk == str(self.api), 'qemu or API readback mismatch')
        self.identity_verified = True
        return {'avd': self.avd, 'api': self.api, 'qemu': 1, 'flavor': self.flavor, 'package': self.package}

    def verify_sandbox(self, receipt_path):
        require(self.identity_verified, 'live AVD identity must be verified first')
        receipt_path = Path(receipt_path)
        receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
        require(isinstance(receipt, dict), 'sandbox receipt missing')
        expected = {'avd': self.avd, 'api': self.api, 'flavor': self.flavor, 'package': self.package}
        require(all(receipt.get(k) == v for k, v in expected.items()), 'sandbox receipt identity mismatch')
        require(receipt.get('synthetic_only') is True and receipt.get('owner_data_absent') is True,
                'sandbox is not proved synthetic-only')
        proof = receipt.get('proof')
        require(isinstance(proof, dict) and proof.get('kind') in ('dedicated_avd_creation', 'synthetic_qa_receipt')
                and isinstance(proof.get('path'), str) and isinstance(proof.get('sha256'), str)
                and SHA256.fullmatch(proof['sha256']), 'sandbox provenance missing')
        proof_path = (receipt_path.parent / proof['path']).resolve()
        require(proof_path.is_file() and digest(proof_path) == proof['sha256'], 'sandbox provenance digest mismatch')
        proof_data = json.loads(proof_path.read_text(encoding='utf-8'))
        require(isinstance(proof_data, dict) and all(proof_data.get(k) == v for k, v in expected.items())
                and proof_data.get('synthetic_only') is True and proof_data.get('owner_data_absent') is True,
                'sandbox provenance does not establish this package')
        self.sandbox_digest = digest(receipt_path)
        self.qa_package_may_remain = receipt.get('qa_package_may_remain') is True
        self.proof_kind = proof['kind']
        self.sandbox_verified = True

    def mutation(self, *args, stdin=None):
        require(self.sandbox_verified, 'sandbox must be verified before mutation')
        return self.call(*args, stdin=stdin)

    def process_gone(self):
        result = self.call('shell', 'pidof', self.package, check=False)
        require(result.returncode in (0, 1), 'pidof failed')
        return not result.stdout.strip()

    def reset_case(self):
        self.mutation('shell', 'am', 'force-stop', self.package)
        require(self.process_gone(), 'process still alive after case reset')

    def require_empty_mailbox(self):
        # The fixed remote command reports only presence; it never emits file contents.
        result = self.text('shell', f"run-as {self.package} sh -c 'if [ -e files/mr6c_qa ]; then [ -d files/mr6c_qa ] || exit 1; listing=$(ls -A files/mr6c_qa) || exit 1; if [ -n \"$listing\" ]; then echo present; else echo absent; fi; else echo absent; fi'")
        require(result == 'absent', 'QA mailbox is not empty or cannot be verified')

    def require_empty_sandbox(self):
        """Read presence only; do not request root or export paths or contents."""
        require(self.sandbox_verified, 'sandbox receipt required before live check')
        paths = (f'/data/user/0/{self.package}', f'/data/user_de/0/{self.package}',
                 f'/storage/emulated/0/Android/data/{self.package}',
                 f'/storage/emulated/0/Android/obb/{self.package}')
        # package comes from a fixed whitelist; failures, inaccessible ancestors,
        # symlinks, and find errors do not get interpreted as an empty sandbox.
        script = sandbox_scan_script()
        result = self.call('shell', f"su 0 sh -c '{script}' sh {' '.join(paths)}", check=False)
        require(result.returncode == 0 and result.stdout.strip() == b'EMPTY', 'live sandbox emptiness unavailable')

    def write_mailbox(self, name, value):
        require(name in ('command', 'ack'), 'unknown mailbox file')
        payload = json.dumps(value, separators=(',', ':')).encode('utf-8')
        require(len(payload) <= 16384, 'oversized mailbox')
        self.mutation('shell', 'run-as', self.package, 'mkdir', '-p', 'files/mr6c_qa')
        # adb joins argv for the remote shell. This is one complete shell string;
        # the package is selected solely from PACKAGES, never user-controlled.
        self.mutation('shell', f"run-as {self.package} sh -c 'cat > files/mr6c_qa/{name}.tmp'", stdin=payload)
        self.mutation('shell', 'run-as', self.package, 'mv', f'files/mr6c_qa/{name}.tmp', f'files/mr6c_qa/{name}.json')

    def start_phase(self, command):
        self.write_mailbox('command', command)
        self.mutation('shell', 'am', 'start', '-W', '-n', f'{self.package}/{ACTIVITY}')

    def event(self):
        # Malformed commands have no trustworthy envelope to echo. The Dart
        # fixture writes a separate, fixed failure marker. Treat even a retained
        # marker as a failure, rather than waiting 30 minutes or accepting an
        # older ready event. Clearing it requires scoped session recovery.
        invalid = self.call('shell', 'run-as', self.package, 'cat', 'files/mr6c_qa/error.json', check=False)
        require(invalid.returncode in (0, 1), 'mailbox error-marker read failed')
        if invalid.returncode == 0:
            require(len(invalid.stdout) <= 16384, 'oversized mailbox error')
            try:
                marker = json.loads(invalid.stdout)
            except (ValueError, UnicodeDecodeError):
                raise CheckError('invalid mailbox error marker') from None
            require(marker == {'schema': 1, 'event': 'error', 'outcome': 'FAIL',
                               'reason': 'invalid_command'}, 'invalid mailbox error marker')
            raise CheckError('QA fixture rejected a command')
        result = self.call('shell', 'run-as', self.package, 'cat', 'files/mr6c_qa/event.json', check=False)
        if result.returncode:
            return None
        require(len(result.stdout) <= 16384, 'oversized mailbox event')
        try:
            return json.loads(result.stdout)
        except (ValueError, UnicodeDecodeError) as exc:
            raise CheckError('invalid mailbox event') from exc

    def ack(self, command, event):
        self.write_mailbox('ack', {**command, 'event': event})


def command(session, case, variant, phase, sequence):
    require(isinstance(session, str) and SAFE_ID.fullmatch(session), 'invalid QA session')
    require(case in CASES and variant in CASES[case] and phase in ('prepare', 'recover'), 'invalid case/variant/phase')
    require(type(sequence) is int and 1 <= sequence <= 9007199254740991, 'invalid sequence')
    return {'schema': 1, 'session': session, 'case': case, 'variant': variant, 'phase': phase, 'sequence': sequence}


def validate_event(event, cmd, expected):
    require(isinstance(event, dict) and set(event) == set(cmd) | {'event', 'outcome', 'evidence'}, 'invalid event shape')
    require(type(event.get('schema')) is int and type(event.get('sequence')) is int and
            all(event.get(key) == value for key, value in cmd.items()), 'stale or mismatched event')
    require(event['event'] == expected and isinstance(event['evidence'], dict), 'unexpected event')
    if expected == 'ready':
        require(event['outcome'] == 'RUNNING' and not event['evidence'], 'invalid ready')
    elif expected == 'barrier':
        evidence = event['evidence']
        if cmd['case'] == 'V9':
            require(cmd['phase'] == 'prepare' and event['outcome'] == 'RUNNING' and
                    set(evidence) == {'execution_digest', 'file_digest', 'dispatch_accepted', 'journal_flushed',
                                      'native_service_active', 'model_calls', 'mutation_calls'}, 'invalid V9 barrier')
            require(all(isinstance(evidence[k], str) and SHA256.fullmatch(evidence[k]) for k in ('execution_digest', 'file_digest')) and
                    all(evidence[k] is True for k in ('dispatch_accepted', 'journal_flushed', 'native_service_active')) and
                    all(type(evidence[k]) is int and evidence[k] >= 0 for k in ('model_calls', 'mutation_calls')), 'invalid V9 barrier evidence')
        else:
            require(event['outcome'] == 'RUNNING' and not evidence, 'invalid barrier')
    elif expected == 'done':
        if event['outcome'] == 'PASS':
            evidence = event['evidence']
            require(cmd['case'] == 'V9' and cmd['phase'] == 'recover' and
                    set(evidence) == {'execution_digest', 'file_digest', 'uncertain', 'isolated', 'permit_absent',
                                      'persistent_accounts_verified', 'model_calls', 'mutation_calls'}, 'invalid V9 recovery evidence')
            require(all(isinstance(evidence[k], str) and SHA256.fullmatch(evidence[k]) for k in ('execution_digest', 'file_digest')) and
                    all(evidence[k] is True for k in ('uncertain', 'isolated', 'permit_absent', 'persistent_accounts_verified')) and
                    all(type(evidence[k]) is int and evidence[k] == 0 for k in ('model_calls', 'mutation_calls')), 'invalid V9 recovery verdict')
        else:
            require(event['outcome'] == 'NOT_RUN' and event['evidence'] == {'reason': 'fixture_unavailable'},
                    'case completion has no verified case driver')
    elif expected == 'error':
        require(event['outcome'] == 'FAIL' and set(event['evidence']) == {'reason'} and
                event['evidence']['reason'] in ('deadline', 'invalid_command', 'io_error', 'unexpected_error'),
                'invalid error marker')
    return event


def wait_event(adb, cmd, expected, *, clock=time.monotonic, sleep=time.sleep, timeout=1800):
    deadline = clock() + timeout
    while clock() < deadline:
        event = adb.event()
        if event and event.get('event') == expected and all(event.get(k) == v for k, v in cmd.items()):
            validate_event(event, cmd, expected)
            return event
        if event and event.get('event') == 'error' and all(event.get(k) == v for k, v in cmd.items()):
            validate_event(event, cmd, 'error')
            raise CheckError('QA fixture reported an error')
        # Old event from another command is never accepted or acknowledged.
        sleep(0.25)
    raise CheckError('phase deadline exceeded')


GateError = CheckError


def notification_ids(raw, package):
    """Extract only package IDs in the active Notification List, never history."""
    require(package in PACKAGES.values(), 'invalid notification package')
    lines = raw.splitlines()
    headers = [i for i, line in enumerate(lines) if line.strip() == 'Notification List:']
    require(len(headers) == 1, 'active notification list unavailable or ambiguous')
    header = lines[headers[0]]
    indent = len(header) - len(header.lstrip())
    ids = set()
    for line in lines[headers[0] + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        if not line.lstrip().startswith('NotificationRecord('):
            continue
        pkg = re.search(r'\bpkg=([^\s,)]+)', line)
        ident = re.search(r'\bid=(\d+)\b', line)
        if pkg and ident and pkg.group(1) == package:
            value = int(ident.group(1))
            if value == 6100 or 6200 <= value <= 6399:
                ids.add(value)
    return ids


def verify_notifications(before, killed, after):
    approvals = {i for i in before if 6200 <= i <= 6299}
    results = {i for i in before if 6300 <= i <= 6399}
    require(approvals and results, 'notification baseline missing approval or result')
    require(approvals <= killed and results <= killed, 'notifications not retained before restart')
    require(not any(6200 <= i <= 6299 for i in after) and results <= after, 'notification restart cleanup mismatch')
    return {'before': sorted(before), 'killed': sorted(killed), 'after': sorted(after)}


def service_gone(adb):
    output = adb.text('shell', 'dumpsys', 'activity', 'services', adb.package)
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    header = 'ACTIVITY MANAGER SERVICES (dumpsys activity services)'
    require(lines and lines[0] == header, 'service listing unavailable or unrecognized')
    if lines == [header, '(nothing)']:
        return True
    # Nonempty AOSP dumps have no completion marker. A matching full record
    # proves presence; absence from a possibly truncated dump proves nothing.
    present = any(re.fullmatch(r'\* ServiceRecord\{[0-9a-f]+ u[0-9]+ ' + re.escape(adb.package) +
                              r'/[^\s}]*AgentRunService(?: c:[A-Za-z0-9_.]+)?\}', line) for line in lines[1:])
    require(present, 'service absence not proven by complete listing')
    return False


class CaseSequence:
    """Keeps install/reset outside an individual prepare -> recover interval."""
    def __init__(self, adb, session):
        self.adb, self.session = adb, session
        self.seq = 0
        self.active = None
        self.barrier = False
        self.prepared_execution_digest = None
        self.journal_file_before = None
        self.ready = False
        self.terminated = False
        self.notification_before = None
        self.notification_killed = None

    def prepare(self, case, variant):
        require(self.active is None, 'previous case not finished')
        cmd = command(self.session, case, variant, 'prepare', self.seq + 1)
        self.adb.reset_case()
        self.seq += 1
        self.adb.start_phase(cmd)
        self.active = cmd
        self.barrier = False
        self.ready = False
        self.terminated = False
        self.notification_before = None
        self.notification_killed = None
        self.prepared_execution_digest = None
        self.journal_file_before = None
        return cmd

    def accepted_ready(self, event):
        require(self.active is not None and not self.ready, 'no pending ready')
        validate_event(event, self.active, 'ready')
        self.adb.ack(self.active, 'ready')
        self.ready = True

    def accepted_barrier(self, event, execution_digest=None, file_digest_before=None):
        require(self.active is not None and self.active['phase'] == 'prepare' and self.ready,
                'prepare ready acknowledgment required before barrier')
        validate_event(event, self.active, 'barrier')
        require((execution_digest is None) == (file_digest_before is None),
                'execution and journal file digests must be supplied together')
        for value in (execution_digest, file_digest_before):
            require(value is None or isinstance(value, str) and SHA256.fullmatch(value), 'invalid digest')
        self.adb.ack(self.active, 'barrier')
        self.barrier = True
        self.prepared_execution_digest = execution_digest
        self.journal_file_before = file_digest_before

    def notification_baseline(self):
        require(self.active is not None and self.active['variant'] == 'notification_restart' and self.barrier, 'notification baseline requires V7 barrier')
        ids = notification_ids(self.adb.text('shell', 'dumpsys', 'notification'), self.adb.package)
        require(any(6200 <= i <= 6299 for i in ids) and any(6300 <= i <= 6399 for i in ids), 'notification baseline incomplete')
        self.notification_before = ids

    def terminate(self, kind):
        require(self.active is not None and self.barrier, 'termination requires prepare barrier')
        require(kind in ('recents_swipe', 'task_manager_stop', 'settings_force_stop', 'notification_restart')
                and self.active['variant'] == kind and self.active['case'] in ('V7', 'V9'), 'termination variant mismatch')
        if kind == 'task_manager_stop':
            self.adb.mutation('shell', 'cmd', 'activity', 'stop-app', self.adb.package)
        elif kind == 'settings_force_stop':
            self.adb.mutation('shell', 'am', 'force-stop', self.adb.package)
        elif kind == 'notification_restart':
            require(self.notification_before is not None, 'notification baseline missing')
            self.adb.mutation('shell', 'am', 'kill', self.adb.package)
        # Recents swipe is manual: no command is substituted for the gesture.
        require(self.adb.process_gone() and service_gone(self.adb), 'termination not independently observed')
        if kind == 'notification_restart':
            self.notification_killed = notification_ids(self.adb.text('shell', 'dumpsys', 'notification'), self.adb.package)
            approvals = {i for i in self.notification_before if 6200 <= i <= 6299}
            results = {i for i in self.notification_before if 6300 <= i <= 6399}
            require(approvals <= self.notification_killed and results <= self.notification_killed, 'notifications did not survive termination')
        self.terminated = True

    def recover(self):
        require(self.active is not None and self.active['phase'] == 'prepare' and self.barrier and self.terminated,
                'recover needs prepare barrier and observed termination')
        require(self.adb.process_gone() and service_gone(self.adb), 'process/service not stopped')
        self.seq += 1
        cmd = command(self.session, self.active['case'], self.active['variant'], 'recover', self.seq)
        self.adb.start_phase(cmd)
        self.active = cmd
        self.ready = False
        return cmd

    def check_journal(self, execution_digest, file_digest_after):
        require(self.active is not None and self.active['phase'] == 'recover' and self.ready, 'recover ready required for journal check')
        require(self.prepared_execution_digest is not None and execution_digest == self.prepared_execution_digest,
                'prepare/recover execution identity not established')
        require(isinstance(file_digest_after, str) and SHA256.fullmatch(file_digest_after), 'invalid recovered journal file digest')
        require(file_digest_after != self.journal_file_before, 'recovered journal file did not change')
        return {'execution_digest': execution_digest, 'file_digest_before': self.journal_file_before,
                'file_digest_after': file_digest_after}

    def finish(self):
        require(self.active is not None, 'no active case')
        self.active = None
        self.barrier = False
        self.prepared_execution_digest = None
        self.journal_file_before = None


def remote_single_apk(adb):
    listing = adb.text('shell', 'pm', 'list', 'packages', adb.package)
    entries = listing.splitlines()
    require(all(line == 'package:' + adb.package for line in entries), 'unrecognized installed package listing')
    require(len(entries) <= 1, 'ambiguous installed package')
    if not entries:
        return None
    lines = adb.text('shell', 'pm', 'path', adb.package).splitlines()
    require(len(lines) == 1 and lines[0].startswith('package:/') and lines[0].endswith('/base.apk'),
            'installed package must have exactly one base APK and no splits')
    return lines[0][len('package:'):]


def pull_verified(adb, remote, destination):
    require(re.fullmatch(r'/data/app/[A-Za-z0-9_@./+=~-]+/base\.apk', remote) is not None, 'invalid APK path')
    remote_hash = adb.text('shell', 'sha256sum', remote).split()
    require(len(remote_hash) == 2 and SHA256.fullmatch(remote_hash[0]) and remote_hash[1] == remote,
            'installed APK digest unavailable')
    destination = Path(destination)
    require(not destination.exists(), 'refusing to overwrite saved APK')
    adb.call('pull', remote, str(destination))
    require(destination.is_file() and destination.stat().st_size > 0 and digest(destination) == remote_hash[0],
            'saved APK digest mismatch')
    return remote_hash[0]


def validate_metadata(data, package):
    require(isinstance(data, dict) and data.get('package') == package, 'APK package mismatch')
    require(type(data.get('version_code')) is int and data['version_code'] > 0, 'APK versionCode missing')
    require(isinstance(data.get('version_name'), str) and data['version_name'], 'APK versionName missing')
    require(isinstance(data.get('signer_sha256'), str) and SHA256.fullmatch(data['signer_sha256']), 'APK signer missing')


class InstallSession:
    """Receipted QA install/restore. inspect_apk must read and verify actual bytes."""
    def __init__(self, adb, directory, inspect_apk):
        self.adb, self.directory, self.inspect_apk = adb, Path(directory).resolve(), inspect_apk
        self.receipt = self.directory / 'restore.json'
        self.data = None

    def prepare(self, candidate, fixed_absent_version=None):
        require(self.adb.sandbox_verified, 'sandbox must be verified before APK capture')
        require(not self.receipt.exists(), 'existing restoration receipt must be recovered first')
        self.directory.mkdir(parents=True, exist_ok=True)
        candidate = Path(candidate).resolve()
        require(candidate.is_file(), 'QA candidate missing')
        qa = self.inspect_apk(candidate)
        validate_metadata(qa, self.adb.package)
        require(qa.get('debuggable') is True, 'QA candidate is not debuggable')
        qa['sha256'] = digest(candidate)
        original_remote = remote_single_apk(self.adb)
        if original_remote:
            original = self.directory / 'original.apk'
            original_hash = pull_verified(self.adb, original_remote, original)
            old = self.inspect_apk(original)
            validate_metadata(old, self.adb.package)
            require(old['version_code'] == qa['version_code'], 'QA and original versionCode must match')
            require(old['signer_sha256'] == qa['signer_sha256'], 'QA and original signer must match')
            old.update({'sha256': original_hash, 'path': str(original.resolve())})
        else:
            require(type(fixed_absent_version) is int and fixed_absent_version == qa['version_code'],
                    'absent package requires fixed QA versionCode')
            require(self.adb.avd != 'Pixel_9' and self.adb.proof_kind == 'dedicated_avd_creation' and
                    self.adb.qa_package_may_remain, 'absent package requires dedicated AVD and retain permission')
            old = None
        self.data = {'schema': 1, 'identity': {'serial': self.adb.serial, 'avd': self.adb.avd,
                     'api': self.adb.api, 'flavor': self.adb.flavor, 'package': self.adb.package},
                     'sandbox_receipt_sha256': self.adb.sandbox_digest,
                     'original': old, 'qa': qa, 'state': 'prepared', 'restore_pending': False}
        write_json(self.receipt, self.data)
        return self.data

    def install(self, candidate):
        require(self.data is not None and self.data['state'] == 'prepared', 'QA already installed or unprepared')
        require(digest(candidate) == self.data['qa']['sha256'], 'QA candidate changed')
        current = remote_single_apk(self.adb)
        original = self.data['original']
        require((current is None) == (original is None), 'installed package presence changed since prepare')
        if original is not None:
            before_install = self.directory / 'installed-before-install.apk'
            require(pull_verified(self.adb, current, before_install) == original['sha256'],
                    'installed APK changed since prepare')
        self.data.update(state='install_started', restore_pending=True)
        write_json(self.receipt, self.data)
        self.adb.mutation('install', '-r', str(candidate))
        installed_remote = remote_single_apk(self.adb)
        require(installed_remote is not None, 'installed QA APK missing')
        installed_file = self.directory / 'installed-qa.apk'
        require(pull_verified(self.adb, installed_remote, installed_file) == self.data['qa']['sha256'],
                'installed QA APK digest mismatch')
        installed_meta = self.inspect_apk(installed_file)
        require(installed_meta.get('package') == self.adb.package and
                installed_meta.get('signer_sha256') == self.data['qa']['signer_sha256'] and
                installed_meta.get('version_code') == self.data['qa']['version_code'] and
                installed_meta.get('debuggable') is True, 'installed QA APK metadata mismatch')
        self.data['state'] = 'qa_installed'
        write_json(self.receipt, self.data)

    def run(self, candidate, operation):
        try:
            self.install(candidate)
            return operation()
        finally:
            if self.data and self.data.get('restore_pending'):
                self.restore()

    def restore(self):
        require(self.adb.sandbox_verified and self.data and self.data['restore_pending'], 'no verified pending restoration')
        require(self.data['identity'] == {'serial': self.adb.serial, 'avd': self.adb.avd,
                'api': self.adb.api, 'flavor': self.adb.flavor, 'package': self.adb.package}, 'restore identity mismatch')
        require(self.data['sandbox_receipt_sha256'] == self.adb.sandbox_digest, 'restore sandbox receipt mismatch')
        original = self.data['original']
        if original is None:
            current = remote_single_apk(self.adb)
            require(current is not None, 'installed QA APK missing during restore')
            remote_hash = self.adb.text('shell', 'sha256sum', current).split()
            require(len(remote_hash) == 2 and remote_hash[0] == self.data['qa']['sha256'] and
                    remote_hash[1] == current, 'installed APK is not the QA candidate')
            saved_current = self.directory / 'installed-before-restore.apk'
            if saved_current.exists():
                require(digest(saved_current) == self.data['qa']['sha256'], 'previous scratch APK is unexpected')
                saved_current.unlink()
            require(pull_verified(self.adb, current, saved_current) == self.data['qa']['sha256'],
                    'installed APK is not the QA candidate')
            meta = self.inspect_apk(saved_current)
            validate_metadata(meta, self.adb.package)
            require(meta.get('version_code') == self.data['qa']['version_code'] and
                    meta.get('version_name') == self.data['qa']['version_name'] and
                    meta.get('signer_sha256') == self.data['qa']['signer_sha256'] and
                    meta.get('debuggable') is True, 'installed QA APK metadata mismatch')
            self.adb.mutation('shell', 'am', 'force-stop', self.adb.package)
            require(self.adb.process_gone(), 'QA process still alive')
            require(self.adb.avd != 'Pixel_9' and self.adb.proof_kind == 'dedicated_avd_creation' and
                    self.adb.qa_package_may_remain, 'cannot close a non-dedicated AVD')
            self.adb.mutation('emu', 'kill')
            self.data.update(state='qa_retained_dedicated_avd_closed', restore_pending=False)
            write_json(self.receipt, self.data)
            return
        original_path = Path(original['path'])
        require(original_path.parent == self.directory and original_path.name == 'original.apk', 'original path mismatch')
        require(original_path.is_file() and digest(original_path) == original['sha256'], 'saved original APK mismatch')
        meta = self.inspect_apk(original_path)
        validate_metadata(meta, self.adb.package)
        require(meta['version_code'] == original['version_code'] and meta['signer_sha256'] == original['signer_sha256'],
                'saved original APK metadata mismatch')
        current = remote_single_apk(self.adb)
        require(current is not None, 'installed APK missing during restore')
        saved_current = self.directory / 'installed-before-restore.apk'
        if saved_current.exists():
            require(digest(saved_current) in (original['sha256'], self.data['qa']['sha256']), 'previous scratch APK is unexpected')
            saved_current.unlink()
        current_digest = pull_verified(self.adb, current, saved_current)
        require(current_digest in (original['sha256'], self.data['qa']['sha256']), 'installed APK is neither saved original nor QA candidate')
        if current_digest != original['sha256']:
            self.adb.mutation('shell', 'am', 'force-stop', self.adb.package)
            require(self.adb.process_gone(), 'QA process still alive')
            self.adb.mutation('install', '-r', str(original_path))
            current = remote_single_apk(self.adb)
            require(current is not None, 'restored APK missing')
            readback_path = self.directory / 'installed-after-restore.apk'
            if readback_path.exists():
                require(digest(readback_path) == original['sha256'], 'previous restore readback is unexpected')
                readback_path.unlink()
            readback = pull_verified(self.adb, current, readback_path)
            require(readback == original['sha256'], 'restored APK digest mismatch')
            meta = self.inspect_apk(readback_path)
            require(meta.get('version_code') == original['version_code'] and
                    meta.get('signer_sha256') == original['signer_sha256'] and
                    meta.get('package') == self.adb.package, 'restored APK metadata mismatch')
        self.data.update(state='restored', restore_pending=False)
        write_json(self.receipt, self.data)


class TimeoutSettings:
    """Save exact settings first; compat_reader must distinguish enabled/disabled/default."""
    def __init__(self, adb, receipt, compat_reader):
        self.adb, self.receipt, self.compat_reader = adb, Path(receipt), compat_reader
        self.data = None

    def values(self):
        mode = self.adb.text('shell', 'device_config', 'get_sync_disabled_for_tests')
        timeout = self.adb.text('shell', 'device_config', 'get', 'activity_manager', 'data_sync_fgs_timeout_duration')
        raw_compat = self.compat_reader()
        require(isinstance(raw_compat, dict) and raw_compat.get('exact') is True and
                raw_compat.get('scope') == 'package' and raw_compat.get('package') == self.adb.package and
                raw_compat.get('change') == 'FGS_INTRODUCE_TIME_LIMITS' and
                raw_compat.get('version_scoped') is False, 'exact unscoped compat override unavailable')
        compat = raw_compat.get('state')
        require(mode in ('none', 'until_reboot', 'persistent'), 'exact device_config sync mode unavailable')
        require(timeout == 'null' or re.fullmatch(r'[0-9]+', timeout), 'invalid original timeout')
        require(compat in ('enabled', 'disabled', 'absent'), 'exact per-package compat override unavailable')
        return {'sync_mode': mode, 'timeout': timeout, 'compat': compat}

    def begin(self):
        require(self.adb.sandbox_verified and self.adb.api in (35, 36), 'timeout test requires verified API 35/36 sandbox')
        require(not self.receipt.exists(), 'settings receipt already exists')
        original = self.values()
        require(original['compat'] == 'absent', 'only an absent original compat override is safely restorable')
        self.data = {'identity': {'serial': self.adb.serial, 'avd': self.adb.avd, 'api': self.adb.api,
                                 'flavor': self.adb.flavor, 'package': self.adb.package},
                     'original': original, 'restore_pending': True}
        write_json(self.receipt, self.data)
        try:
            self.adb.mutation('shell', 'am', 'compat', 'enable', 'FGS_INTRODUCE_TIME_LIMITS', self.adb.package)
            require(self.values()['compat'] == 'enabled', 'compat enable readback failed')
            self.adb.mutation('shell', 'device_config', 'set_sync_disabled_for_tests', 'until_reboot')
            require(self.adb.text('shell', 'device_config', 'get_sync_disabled_for_tests') == 'until_reboot', 'sync mode readback failed')
            self.adb.mutation('shell', 'device_config', 'put', 'activity_manager', 'data_sync_fgs_timeout_duration', '10000')
            require(self.adb.text('shell', 'device_config', 'get', 'activity_manager', 'data_sync_fgs_timeout_duration') == '10000', 'timeout readback failed')
        except BaseException:
            self.restore()
            raise

    def run(self, operation):
        self.begin()
        try:
            return operation()
        finally:
            if self.data and self.data.get('restore_pending'):
                self.restore()

    def restore(self):
        require(self.adb.sandbox_verified and self.data and self.data.get('restore_pending'), 'settings restore not prepared')
        expected_identity = {'serial': self.adb.serial, 'avd': self.adb.avd, 'api': self.adb.api,
                             'flavor': self.adb.flavor, 'package': self.adb.package}
        require(self.data['identity'] == expected_identity, 'settings restore identity mismatch')
        original = self.data['original']
        failures = []
        actions = [
            ('timeout', ('shell', 'device_config', 'delete', 'activity_manager', 'data_sync_fgs_timeout_duration')
             if original['timeout'] == 'null' else
             ('shell', 'device_config', 'put', 'activity_manager', 'data_sync_fgs_timeout_duration', original['timeout'])),
            ('sync', ('shell', 'device_config', 'set_sync_disabled_for_tests', original['sync_mode'])),
            ('compat', ('shell', 'am', 'compat', {'enabled': 'enable', 'disabled': 'disable', 'absent': 'reset'}[original['compat']],
                        'FGS_INTRODUCE_TIME_LIMITS', self.adb.package)),
        ]
        for name, action in actions:
            try:
                self.adb.mutation(*action)
            except Exception:
                failures.append(name)
        try:
            if self.values() != original:
                failures.append('readback')
        except Exception:
            failures.append('readback')
        if failures:
            self.data['restore_errors'] = failures
            write_json(self.receipt, self.data)
            raise CheckError('settings restoration pending: ' + ','.join(failures))
        self.data['restore_pending'] = False
        write_json(self.receipt, self.data)


class DozeSettings:
    """Only supports a freshly observed non-overridden battery and non-forced idle."""
    def __init__(self, adb, receipt, state_reader):
        self.adb, self.receipt, self.state_reader = adb, Path(receipt), state_reader
        self.data = None

    def begin(self):
        require(self.adb.sandbox_verified and not self.receipt.exists(), 'doze sandbox/receipt invalid')
        state = self.state_reader()
        require(isinstance(state, dict) and set(state) == {'battery_updates_stopped', 'force_idle'} and
                state['battery_updates_stopped'] is False and state['force_idle'] is False,
                'cannot preserve pre-existing battery or idle simulation')
        self.data = {'identity': {'serial': self.adb.serial, 'avd': self.adb.avd, 'api': self.adb.api,
                                 'flavor': self.adb.flavor, 'package': self.adb.package},
                     'original': state, 'restore_pending': True}
        write_json(self.receipt, self.data)
        try:
            self.adb.mutation('shell', 'dumpsys', 'battery', 'unplug')
            self.adb.mutation('shell', 'dumpsys', 'deviceidle', 'force-idle')
            text = self.adb.text('shell', 'dumpsys', 'deviceidle')
            require(re.search(r'\bmState=IDLE\b', text) is not None, 'device did not enter idle')
        except BaseException:
            self.restore()
            raise

    def run(self, operation):
        self.begin()
        try:
            return operation()
        finally:
            if self.data and self.data.get('restore_pending'):
                self.restore()

    def restore(self):
        require(self.adb.sandbox_verified and self.data and self.data.get('restore_pending'), 'doze restore not prepared')
        identity = {'serial': self.adb.serial, 'avd': self.adb.avd, 'api': self.adb.api,
                    'flavor': self.adb.flavor, 'package': self.adb.package}
        require(self.data['identity'] == identity, 'doze restore identity mismatch')
        failures = []
        for name, args in [('idle', ('shell', 'dumpsys', 'deviceidle', 'unforce')),
                           ('battery', ('shell', 'dumpsys', 'battery', 'reset'))]:
            try:
                self.adb.mutation(*args)
            except Exception:
                failures.append(name)
        try:
            if self.state_reader() != self.data['original']:
                failures.append('readback')
        except Exception:
            failures.append('readback')
        if failures:
            self.data['restore_errors'] = failures
            write_json(self.receipt, self.data)
            raise CheckError('doze restoration pending: ' + ','.join(failures))
        self.data['restore_pending'] = False
        write_json(self.receipt, self.data)


def validate_v1(evidence):
    """Validate full-window host/device series; each uses its own monotonic origin."""
    require(isinstance(evidence, dict), 'incomplete V1 socket evidence')
    require(evidence.get('mode') in ('screen_off', 'doze'), 'V1 mode missing')
    require(evidence.get('service_alive') is True and evidence.get('dart_alive') is True and
            evidence.get('socket_tls_verified') is True, 'V1 service, Dart, or restricted TLS not proved')
    if evidence['mode'] == 'doze':
        require(evidence.get('verified_device_idle') is True, 'V1 force-idle not proved')
    durations = {}
    for side in ('host', 'device'):
        duration = evidence.get(side + '_duration_seconds')
        require(type(duration) in (int, float) and math.isfinite(duration) and duration >= 720,
                f'{side} V1 observation must cover at least 12 minutes')
        durations[side] = duration
    summaries = {}
    for side in ('host', 'device'):
        for stream, maximum in (('sse', 15), ('gitlab', 60)):
            key = side + '_' + stream + '_times_seconds'
            values = evidence.get(key)
            require(isinstance(values, list) and len(values) >= 2, f'{key} requires timestamp series')
            require(all(type(value) in (int, float) and math.isfinite(value) and 0 <= value <= durations[side]
                        for value in values), f'{key} has invalid timestamps')
            require(all(left < right for left, right in zip(values, values[1:])), f'{key} is not strictly increasing')
            times = [0, *values, durations[side]]
            gap = max(right - left for left, right in zip(times, times[1:]))
            require(gap <= maximum, f'{key} has a gap exceeding {maximum} seconds')
            summaries[key] = {'n': len(values), 'max_gap_seconds': gap}
    require(summaries['device_sse_times_seconds']['n'] <= summaries['host_sse_times_seconds']['n'] and
            summaries['device_gitlab_times_seconds']['n'] <= summaries['host_gitlab_times_seconds']['n'],
            'device received count exceeds host-side events')
    return {'network': 'PASS', 'observation_seconds': durations, 'series': summaries}


def metric_summary(samples, *, channel=False):
    require(isinstance(samples, list) and len(samples) >= 100, 'V3 needs at least 100 attempts per metric')
    elapsed, expired, timeout, rollback_attempt, rollback_ok, rollback_fail = [], 0, 0, 0, 0, 0
    reasons, rejection_latency, within = {}, [], 0
    for sample in samples:
        require(isinstance(sample, dict) and set(sample) == {'elapsed_ms', 'outcome', 'flushed', 'rollback', 'reason'}, 'invalid V3 sample')
        value = sample['elapsed_ms']
        require(type(value) in (int, float) and math.isfinite(value) and value >= 0, 'invalid V3 elapsed')
        require(sample['outcome'] in ('consumed', 'expired', 'rejected', 'timeout') and type(sample['flushed']) is bool,
                'invalid V3 outcome')
        require(sample['rollback'] in ('none', 'success', 'failure'), 'invalid V3 rollback')
        require(sample['reason'] in ('none', 'ttl', 'timeout', 'guard', 'unavailable', 'late_reply'), 'invalid V3 rejection reason')
        require((sample['outcome'] == 'consumed') == (sample['reason'] == 'none'), 'V3 outcome/reason mismatch')
        require(sample['outcome'] != 'expired' or sample['reason'] == 'ttl', 'expiry reason mismatch')
        require(sample['outcome'] != 'timeout' or sample['reason'] == 'timeout', 'timeout reason mismatch')
        if sample['outcome'] != 'consumed':
            reasons[sample['reason']] = reasons.get(sample['reason'], 0) + 1
            rejection_latency.append(value)
        elif value <= 1000 if channel else value < 1000:
            within += 1
        if not channel and sample['outcome'] == 'consumed':
            require(value < 1000, 'expired native ticket was consumed')
        if sample['outcome'] == 'expired':
            expired += 1
            require(value >= 1000, 'expiry time before TTL')
            if sample['flushed']:
                require(sample['rollback'] in ('success', 'failure'), 'flushed TTL rejection missing rollback')
        if sample['outcome'] == 'timeout':
            timeout += 1
        if sample['rollback'] != 'none':
            require(sample['flushed'] and sample['outcome'] in ('expired', 'rejected'), 'invalid rollback accounting')
            rollback_attempt += 1
            rollback_ok += sample['rollback'] == 'success'
            rollback_fail += sample['rollback'] == 'failure'
        elapsed.append(value)
    elapsed.sort()
    def pct(fraction):
        return elapsed[math.ceil(len(elapsed) * fraction) - 1]
    return {'n': len(elapsed), 'denominator': len(samples), 'p50_ms': pct(.5), 'p95_ms': pct(.95),
            'max_ms': elapsed[-1], 'within_limit_count': within, 'within_limit_ratio': within / len(samples),
            'ttl_expired': expired, 'timeouts': timeout, 'rollback_attempts': rollback_attempt,
            'rollback_success': rollback_ok, 'rollback_failure': rollback_fail,
            'rejection_reason_counts': reasons, 'rejection_latency_ms': rejection_latency}


def validate_v3(metrics):
    require(isinstance(metrics, dict) and set(metrics) == {'channel', 'model', 'rest', 'graph'}, 'V3 needs all independent metrics')
    return {name: metric_summary(samples, channel=(name == 'channel')) for name, samples in metrics.items()}


def inspect_public_apk(path, flavor, tools):
    """Read a single signed APK, including an older installed SDK version."""
    import mr6c_artifacts as artifacts
    path = Path(path)
    require(path.is_file(), 'APK missing')
    try:
        badging = artifacts.run([tools['aapt2'], 'dump', 'badging', path])
        header = next((line for line in badging.splitlines() if line.startswith('package: ')), '')
        fields = dict(re.findall(r"(\w+)='([^']*)'", header))
        signed = artifacts.run([tools['apksigner'], 'verify', '--verbose', '--print-certs', path])
        fingerprints = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F:]+)\s*$', signed, re.M)
        fingerprints = [value.replace(':', '').lower() for value in fingerprints]
        require(len(fingerprints) == 1 and SHA256.fullmatch(fingerprints[0]), 'APK requires one signer')
        require(re.search(r'^Verified using v\d+ scheme[^:]*: true\s*$', signed, re.M), 'APK signature not verified')
        require(fields.get('versionCode', '').isdigit(), 'APK version code missing')
        data = {'package': fields.get('name'), 'version_name': fields.get('versionName'),
                'version_code': int(fields['versionCode']), 'signer_sha256': fingerprints[0],
                'debuggable': bool(re.search(r'^application-debuggable$', badging, re.M))}
        validate_metadata(data, PACKAGES[flavor])
        return data
    except artifacts.EvidenceError as exc:
        raise CheckError('APK SDK inspection failed') from exc


def check_provenance(candidate, provenance_path, provenance_hash, source_path, flavor):
    """Bind operator-attested build provenance and source metadata to APK bytes."""
    require(SHA256.fullmatch(provenance_hash or '') is not None, 'provenance SHA-256 required')
    require(digest(provenance_path) == provenance_hash, 'provenance digest mismatch')
    provenance = json.loads(Path(provenance_path).read_text(encoding='utf-8'))
    require(isinstance(provenance, dict) and provenance.get('schema') == 1 and
            provenance.get('flavor') == flavor and provenance.get('variant') == 'debug' and
            provenance.get('qa_enabled') is True, 'invalid QA provenance')
    apk_hash, source_hash = digest(candidate), digest(source_path)
    require(provenance.get('apk_sha256') == apk_hash and provenance.get('source_metadata_sha256') == source_hash,
            'QA APK or source metadata provenance mismatch')
    require(Path(candidate).stat().st_size > 0 and Path(source_path).stat().st_size > 0, 'empty input')
    return {'apk_sha256': apk_hash, 'provenance_sha256': provenance_hash,
            'source_metadata_sha256': source_hash, 'provenance': 'OPERATOR_ATTESTED'}


def wait_phase_result(adb, cmd, *, clock=time.monotonic, sleep=time.sleep, timeout=1800):
    deadline = clock() + timeout
    while clock() < deadline:
        event = adb.event()
        if event and event.get('event') in ('barrier', 'done', 'error'):
            if any(event.get(key) != value for key, value in cmd.items()):
                sleep(.25)
                continue
            kind = event['event']
            validate_event(event, cmd, kind)
            if kind == 'error':
                raise CheckError('QA fixture reported an error')
            return event
        sleep(.25)
    raise CheckError('phase deadline exceeded')


def run_cases(adb, ids, report, output, *, session=None, attempt=None):
    """Drive the available V9 task-manager fixture; other variants stay NOT_RUN."""
    sequence = CaseSequence(adb, session or secrets.token_hex(16))
    drivers = {('V9', 'task_manager_stop')}
    for case in ids:
        for variant in CASES[case]:
            if (case, variant) not in drivers:
                continue
            if attempt is not None:
                attempt.update(phase='case', active=(case, variant))
                report['attempt'] = {'phase': 'case', 'case': case, 'variant': variant}
                write_json(output, report)
            cmd = sequence.prepare(case, variant)
            sequence.accepted_ready(wait_event(adb, cmd, 'ready'))
            event = wait_phase_result(adb, cmd)
            if event['event'] == 'done':
                sequence.finish()
                if attempt is not None:
                    attempt['active'] = None
                continue
            evidence = event['evidence']
            require(not adb.process_gone() and not service_gone(adb), 'V9 prepare process/service not active')
            sequence.accepted_barrier(event, evidence['execution_digest'], evidence['file_digest'])
            sequence.terminate(variant)
            recover = sequence.recover()
            sequence.accepted_ready(wait_event(adb, recover, 'ready'))
            done = wait_phase_result(adb, recover)
            require(done['event'] == 'done', 'unexpected recover barrier')
            require(done['outcome'] == 'PASS', 'V9 recovery unavailable after termination')
            if done['outcome'] == 'PASS':
                result = done['evidence']
                require(service_gone(adb), 'V9 service still present after recovery')
                identity = sequence.check_journal(result['execution_digest'], result['file_digest'])
                report['cases'][case][variant] = 'NOT_VERIFIED'
                report['device_os'] = 'PARTIAL'
                report['status'] = 'PARTIAL'
                report.setdefault('case_evidence', {})[variant] = {
                    **identity, 'recovery_subcheck': 'PASS', 'prepare_model_calls': evidence['model_calls'],
                    'prepare_mutation_calls': evidence['mutation_calls'],
                    'recovery_model_calls': result['model_calls'], 'recovery_mutation_calls': result['mutation_calls'],
                    'uncertain': True, 'isolated': True, 'permit_absent': True,
                    'persistent_accounts_verified': True, 'termination': variant}
            sequence.finish()
            if attempt is not None:
                attempt['active'] = None
            write_json(output, report)
    return report


def verify_recovery_receipt(path, expected_hash, args):
    path = Path(path).resolve()
    require(isinstance(expected_hash, str) and SHA256.fullmatch(expected_hash) and digest(path) == expected_hash,
            'restore receipt digest mismatch')
    data = json.loads(path.read_text(encoding='utf-8'))
    identity = {'serial': args.serial, 'avd': args.avd, 'api': args.api, 'flavor': args.flavor,
                'package': PACKAGES[args.flavor]}
    require(data.get('schema') == 1 and data.get('identity') == identity and data.get('restore_pending') is True,
            'restore receipt identity or state mismatch')
    original = data.get('original')
    if original is not None:
        require(isinstance(original, dict) and Path(original.get('path', '')).resolve() == path.parent / 'original.apk',
                'restore original path mismatch')
        original_path = Path(original['path'])
        require(original_path.is_file() and digest(original_path) == original.get('sha256'), 'restore original digest mismatch')
    return data


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', help='explicit emulator serial, never auto-select')
    parser.add_argument('--avd', choices=sorted(AVDS), required=True)
    parser.add_argument('--api', type=int, choices=(34, 35, 36), required=True)
    parser.add_argument('--flavor', choices=sorted(PACKAGES), default='gitlab')
    parser.add_argument('--cases', default='all', help='all or comma-separated case IDs')
    parser.add_argument('--output', type=Path, required=True, help='evidence JSON path or directory')
    parser.add_argument('--plan', action='store_true', help='offline matrix, no device operations')
    parser.add_argument('--recover', action='store_true', help='restore from a hash-verified pending APK receipt')
    parser.add_argument('--restore-receipt', type=Path)
    parser.add_argument('--restore-receipt-sha256')
    parser.add_argument('--sandbox-receipt', type=Path)
    parser.add_argument('--sandbox-receipt-sha256')
    parser.add_argument('--qa-apk', type=Path, help='prebuilt debug QA APK; no build is performed')
    parser.add_argument('--qa-provenance', type=Path, help='operator-attested QA build provenance JSON')
    parser.add_argument('--qa-provenance-sha256')
    parser.add_argument('--source-metadata', type=Path, help='source metadata bound by QA provenance')
    parser.add_argument('--work-dir', type=Path, help='session directory for saved APK and receipt')
    parser.add_argument('--absent-version-code', type=int, help='fixed version if package is absent on dedicated AVD')
    args = parser.parse_args(argv)
    output = args.output / 'mr6c-evidence.json' if args.output.suffix.lower() != '.json' else args.output
    report = None
    operation = None
    attempt = {'started': False, 'phase': 'preflight', 'active': None, 'restoration_failed': False}
    if output.exists() or output.with_name(output.name + '.tmp').exists():
        print('NOT_RUN: output already exists', file=sys.stderr)
        return 2
    try:
        if args.avd != 'Pixel_9':
            require(args.avd == f'Pixel_9_MR6c_API{args.api}', 'AVD/API mismatch')
        ids = selected_cases(args.cases)
        report = plan(args.flavor, args.api, ids)
        report['avd'] = args.avd
        if args.plan:
            require(not args.recover, '--plan and --recover are mutually exclusive')
            write_json(output, report)
            print(json.dumps(report, sort_keys=True, indent=2))
            return 0
        require(args.serial and re.fullmatch(r'emulator-[0-9]+', args.serial), 'explicit emulator serial required')
        require(args.sandbox_receipt and SHA256.fullmatch(args.sandbox_receipt_sha256 or ''), 'sandbox receipt and digest required')
        require(digest(args.sandbox_receipt) == args.sandbox_receipt_sha256, 'sandbox receipt digest mismatch')
        if args.recover:
            require(args.restore_receipt and args.restore_receipt_sha256, 'restore receipt and digest required')
            saved = verify_recovery_receipt(args.restore_receipt, args.restore_receipt_sha256, args)
            require(saved.get('sandbox_receipt_sha256') == args.sandbox_receipt_sha256, 'restore sandbox receipt mismatch')
        else:
            require('V9' in ids, 'selected cases have no implemented device driver')
            require(args.qa_apk and args.qa_provenance and args.source_metadata and args.work_dir,
                    'QA APK, provenance, source metadata and work directory required')
            require(not (args.work_dir / 'restore.json').exists(), 'existing restoration receipt must be recovered first')
            report['inputs'] = check_provenance(args.qa_apk, args.qa_provenance, args.qa_provenance_sha256,
                                                args.source_metadata, args.flavor)
        import mr6c_artifacts as artifacts
        try:
            sdk = artifacts.sdk_tools(Path.cwd())
        except artifacts.EvidenceError as exc:
            raise CheckError('Android SDK tools unavailable') from exc
        inspector = lambda path: inspect_public_apk(path, args.flavor, sdk)
        if not args.recover:
            candidate_meta = inspector(args.qa_apk)
            require(candidate_meta['debuggable'], 'QA candidate is not debuggable')
            try:
                report['qa_apk'] = artifacts.apk_info(
                    args.qa_apk, args.flavor, 'debug', sdk)
            except artifacts.EvidenceError as exc:
                raise CheckError('QA candidate artifact validation failed') from exc
        adb = Adb(args.serial, args.avd, args.api, args.flavor)
        adb.verify_identity()
        adb.verify_sandbox(args.sandbox_receipt)
        if args.recover:
            operation = InstallSession(adb, args.restore_receipt.resolve().parent, inspector)
            operation.data = saved
            attempt.update(started=True, phase='restore')
            operation.restore()
            report['reason'] = 'restoration_completed_cases_not_run'
            report['restoration'] = operation.data['state']
        else:
            adb.require_empty_sandbox()
            operation = InstallSession(adb, args.work_dir, inspector)
            operation.prepare(args.qa_apk, args.absent_version_code)
            report['restore_receipt'] = str(operation.receipt)
            write_json(output, report)
            try:
                adb.require_empty_sandbox()
            except BaseException:
                operation.data.update(state='prepared_no_install', restore_pending=False,
                                      reason='live_sandbox_refused')
                write_json(operation.receipt, operation.data)
                raise
            try:
                attempt.update(started=True, phase='install')
                report['device_os'] = 'ATTEMPTED'
                operation.install(args.qa_apk)
                attempt['phase'] = 'mailbox_preflight'
                adb.require_empty_mailbox()
                run_cases(adb, ids, report, output, attempt=attempt)
            finally:
                if operation.data and operation.data.get('restore_pending'):
                    previous_phase = attempt['phase']
                    attempt['phase'] = 'restore'
                    try:
                        operation.restore()
                    except BaseException:
                        attempt['restoration_failed'] = True
                        raise
                    else:
                        attempt['phase'] = previous_phase
            report['reason'] = 'partial_case_evidence' if report.get('case_evidence') else 'case_specific_evidence_unavailable'
            report['restoration'] = operation.data['state']
        report.pop('attempt', None)
        report['restoration_pending'] = False
        write_json(output, report)
        print(json.dumps(report, sort_keys=True, indent=2))
        return 2  # The case matrix remains NOT_RUN even after a successful restore.
    except (CheckError, OSError, ValueError, TypeError, KeyboardInterrupt):
        if report is not None:
            started = attempt['started']
            report['status'] = 'FAIL' if started else 'NOT_RUN'
            report['reason'] = ('restoration_failed' if attempt['restoration_failed'] or
                                (started and attempt['phase'] == 'restore') else
                                'attempt_failed' if started else 'preflight_unavailable')
            report['failure_phase'] = attempt['phase']
            if attempt['active']:
                case, variant = attempt['active']
                report['cases'][case][variant] = 'FAIL'
            report['restoration_pending'] = (bool(operation.data.get('restore_pending'))
                                             if operation and operation.data else None)
            try:
                write_json(output, report)
            except OSError:
                pass
        print(('FAIL' if attempt['started'] else 'NOT_RUN') + ': ' +
              (report['reason'] if report else 'preflight_unavailable'), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
