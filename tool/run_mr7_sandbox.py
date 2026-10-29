#!/usr/bin/env python3
"""Run MR7's synthetic host sandbox. No credentials or live transport are used."""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
import getpass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
SAFE_ENV = (
    'PATH', 'HOME', 'TMPDIR', 'PUB_CACHE', 'FLUTTER_ROOT', 'FVM_CACHE_PATH',
    'LANG', 'LC_ALL', 'TERM', 'CI', 'SYSTEMROOT', 'WINDIR',
)
SHA = re.compile(r'^[0-9a-f]{40}$')
ENV_NAME = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
IDENTIFIER = re.compile(r'^[A-Za-z0-9_.:/-]{1,256}$')
CLOSED_VARIANT_CODE = re.compile(r'^[A-Za-z][A-Za-z0-9]{0,63}$')
CLOSED_VARIANT_CAUSES = frozenset({
    'releasePolicy', 'fixtureUnavailable', 'unsupportedServer',
    'ownershipUnproven', 'observerUnavailable', 'scopeExcluded',
})
WRITE_TIERS = frozenset({'T1', 'T2', 'T3', 'T4', 'hardLine'})
GATE_DECISIONS = frozenset({'deny', 'requireApproval', 'execute'})
FIXED_CONFIRM_REASONS = frozenset({
    'markAllTodosDone', 'foreignDraftsInPublish', 'massMention',
    'externalMediaInRenderedMarkdown', 'foreignClosingOrCrossProject',
    'duplicateOfSettledWrite', 'duplicateUpload', 'wholeFieldDropsHiddenSpans',
    'headMovedSincePreview', 'confirmMarkAfterManualRelease',
    'journalResetWindow', 'confidentialOrVisibilityMix', 'targetUnbound',
    'targetNamedNotMarked', 'intentNotUnique',
})
SOURCE_FILES = (
    'tool/run_mr7_sandbox.py', 'tool/mr7_sandbox.dart',
    'tool/mr7/sandbox_contract.dart', 'tool/tests/test_mr7_sandbox_runner.py',
    'test/ai/mr7_sandbox_contract_test.dart',
    'test/ai/mr7_sandbox_wave2_contract_test.dart',
    'test/ai/mr7_sandbox_wave2_runner_test.dart',
    'test/ai/mr7_sandbox_wave3_test.dart', 'docs/MR7_SANDBOX.md',
    'pubspec.lock',
)
DEPENDENCY_FILES = (
    'tool/mr7/candidate_release_policy.dart', 'pubspec.yaml', '.fvmrc',
    'analysis_options.yaml', '.dart_tool/package_config.json',
)


class SafeParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # argparse's usual error echoes unknown argv, which may contain a key.
        self.exit(2, 'Invalid arguments.\n')


def parser() -> argparse.ArgumentParser:
    p = SafeParser(description=__doc__, allow_abbrev=False)
    p.add_argument('--policy', choices=('production', 'candidate'), default='production')
    p.add_argument('--transport', choices=('synthetic', 'live'), default='synthetic')
    p.add_argument('--suite', choices=('all', 'rest', 'graphql', 'advanced'), default='all')
    p.add_argument('--expected-user-id', type=int, default=os.environ.get('MR7_EXPECTED_USER_ID', '7'))
    p.add_argument('--namespace', default=os.environ.get('MR7_OWNER_NAMESPACE', 'synthetic-owner'))
    p.add_argument('--provider-config')
    p.add_argument('--expect-release-sha')
    p.add_argument('--output', required=True)
    return p


def provider_config(path: str | None) -> dict:
    if path is None:
        return {}
    with open(path, encoding='utf-8') as stream:
        data = json.load(stream)
    allowed = {'endpoint', 'format', 'model', 'caps', 'maxCost', 'maxCalls', 'keyEnv'}
    if not isinstance(data, dict) or set(data) != allowed:
        raise ValueError('invalid provider config')
    endpoint = data['endpoint']
    if not isinstance(endpoint, str):
        raise ValueError('invalid endpoint')
    u = urlsplit(endpoint)
    if u.scheme != 'https' or not u.hostname or u.username or u.password or u.query or u.fragment:
        raise ValueError('invalid endpoint')
    if data['format'] not in ('responses', 'chat_completions', 'anthropic_messages'):
        raise ValueError('invalid format')
    if not isinstance(data['model'], str) or not IDENTIFIER.fullmatch(data['model']):
        raise ValueError('invalid model')
    if not isinstance(data['keyEnv'], str) or not ENV_NAME.fullmatch(data['keyEnv']):
        raise ValueError('invalid key environment name')
    cost, calls = data['maxCost'], data['maxCalls']
    if (isinstance(cost, bool) or not isinstance(cost, (int, float)) or
            not math.isfinite(cost) or cost <= 0 or isinstance(calls, bool) or
            not isinstance(calls, int) or calls <= 0):
        raise ValueError('invalid cap')
    caps = data['caps']
    if not isinstance(caps, dict) or not caps:
        raise ValueError('invalid capabilities')
    for name, value in caps.items():
        if (not isinstance(name, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,63}', name)
                or any(term in name.lower() for term in ('secret', 'password', 'apikey'))
                or not isinstance(value, (bool, int, float))
                or (isinstance(value, float) and not math.isfinite(value))):
            raise ValueError('invalid capabilities')
    return data


def validate_receipt(receipt: object, *, final: bool = False, policy: str | None = None,
                     release_sha: str | None = None) -> bool:
    if not isinstance(receipt, dict):
        return False
    actual_policy = receipt.get('policy')
    evidence = 'CANDIDATE_ONLY' if actual_policy == 'candidate' else 'SYNTHETIC'
    if (type(receipt.get('schema')) is not int or receipt['schema'] != 1 or
            receipt.get('status') not in ('PASS', 'FAIL') or
            receipt.get('transport') != 'synthetic' or
            actual_policy not in ('production', 'candidate') or
            receipt.get('evidenceClass') != evidence or
            receipt.get('finalEligible') is not False or
            receipt.get('live') != 'NOT_RUN' or
            not isinstance(receipt.get('releaseSha'), str) or
            not SHA.fullmatch(receipt['releaseSha']) or
            (policy is not None and actual_policy != policy) or
            (release_sha is not None and receipt['releaseSha'] != release_sha)):
        return False
    scenarios = receipt.get('scenarios', [])
    if not isinstance(scenarios, list):
        return False
    # A closed row cannot share its identity with a runnable or another closed
    # row. Ordinary schema-1 rows remain backwards compatible.
    ids = Counter(row['id'] for row in scenarios
                  if isinstance(row, dict) and isinstance(row.get('id'), str))
    for row in scenarios:
        if not isinstance(row, dict):
            return False
        refusal = row.get('refusal')
        if row.get('classification') == 'closedVariant' or refusal is not None:
            if (row.get('classification') != 'closedVariant' or
                    not isinstance(row.get('id'), str) or
                    not IDENTIFIER.fullmatch(row['id']) or ids[row['id']] != 1 or
                    any(not isinstance(row.get(field), str) or not row[field].strip()
                        for field in ('suite', 'operation', 'variant', 'tier')) or
                    row.get('releaseSha') != receipt['releaseSha'] or
                    row.get('live') != 'NOT_RUN' or
                    row.get('status') != 'NOT_RUN' or row.get('readback') != 'NOT_RUN' or
                    type(row.get('mutationCount')) is not int or row['mutationCount'] != 0 or
                    type(row.get('providerCalls')) is not int or row['providerCalls'] != 0 or
                    'responseStatus' in row or
                    any(field in row and row[field] != 'notExecuted'
                        for field in ('outcome', 'coreOutcome')) or
                    not isinstance(refusal, dict) or set(refusal) != {'type', 'cause', 'code'} or
                    refusal.get('type') != 'closedVariant' or
                    not isinstance(refusal.get('cause'), str) or
                    refusal['cause'] not in CLOSED_VARIANT_CAUSES or
                    not isinstance(refusal.get('code'), str) or
                    not CLOSED_VARIANT_CODE.fullmatch(refusal['code']) or
                    row.get('reason') != refusal['code'] or
                    ('observerRequests' in row and
                     (type(row['observerRequests']) is not int or row['observerRequests'] != 0)) or
                    ('provider' in row and
                     (not isinstance(row['provider'], dict) or
                      type(row['provider'].get('calls')) is not int or
                      row['provider']['calls'] != 0))):
                return False
        projection_fields = {'declaredTier', 'decisionProjection', 'decision',
                             'confirmationReasons', 'decisionUnavailable'}
        if projection_fields.intersection(row):
            declared = row.get('declaredTier')
            observed = row.get('tier')
            decision = row.get('decision')
            reasons = row.get('confirmationReasons')
            projection = row.get('decisionProjection')
            if (not {'declaredTier', 'tier', 'decision', 'confirmationReasons',
                     'decisionProjection'}.issubset(row) or
                    not isinstance(declared, str) or not declared.strip() or
                    not isinstance(reasons, list) or
                    any(not isinstance(reason, str) or reason not in FIXED_CONFIRM_REASONS
                        for reason in reasons) or len(reasons) != len(set(reasons))):
                return False
            if projection == 'observed':
                if (not isinstance(observed, str) or observed not in WRITE_TIERS or
                        not isinstance(decision, str) or decision not in GATE_DECISIONS or
                        'decisionUnavailable' in row):
                    return False
                if (declared != observed and
                        (row.get('status') != 'FAIL' or row.get('reason') != 'tierMismatch' or
                         type(row.get('mutationCount')) is not int or row['mutationCount'] != 0)):
                    return False
                if declared == observed and row.get('reason') == 'tierMismatch':
                    return False
            elif projection == 'unavailable':
                if (observed is not None or decision is not None or reasons or
                        row.get('decisionUnavailable') != 'proposalUnavailable' or
                        type(row.get('mutationCount')) is not int or row['mutationCount'] != 0 or
                        row.get('coreOutcome') == 'succeeded'):
                    return False
            else:
                return False
        count = row.get('mutationCount')
        zero_dispatch = type(count) is int and count == 0
        no_op_claim = (
            ((row.get('outcome') == 'noChange' or row.get('coreNoChange') is True)
             and (not zero_dispatch or row.get('status') == 'PASS')) or
            row.get('responseStatus') in (304, 409) or 'parentStateVerified' in row
        )
        if (no_op_claim and (row.get('status') == 'PASS' or receipt['status'] == 'PASS') and
                row.get('classification') != 'verifiedNoOp'):
            return False
        if row.get('classification') == 'verifiedNoOp':
            status = row.get('responseStatus')
            if (type(row.get('mutationCount')) is not int or row['mutationCount'] not in (0, 1) or
                    type(row.get('observerRequests')) is not int or row['observerRequests'] < 1 or
                    row.get('parentStateVerified') is not True or row.get('readback') != 'PASS' or
                    row.get('status') != 'PASS' or row.get('outcome') != 'noChange' or
                    row.get('coreOutcome') != 'succeeded' or
                    type(row.get('coreNoChange')) is not bool):
                return False
            if zero_dispatch:
                if (row.get('coreNoChange') is not True or 'responseStatus' in row or
                        row.get('operation') not in ('setStar', 'setSubscribed', 'cancelAutoMerge')):
                    return False
            elif (type(status) is not int or status not in (304, 409) or
                  (status == 304 and row.get('operation') not in ('setStar', 'setSubscribed')) or
                  (status == 409 and (row.get('coreNoChange') is not True or
                                      row.get('operation') != 'cancelAutoMerge'))):
                return False
    # This implementation has no live transport; no synthetic receipt can be final.
    return not final


def _private_file(path: Path, text: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        stream.write(text)


@contextmanager
def credential_files(*, pat_env: str | None = None, key_env: str | None = None):
    """Future live adapter helper; this synthetic runner never invokes it."""
    for name in (pat_env, key_env):
        if name is not None and not ENV_NAME.fullmatch(name):
            raise ValueError('invalid credential environment name')
    pat = os.environ.get(pat_env) if pat_env else getpass.getpass('GitLab PAT: ')
    key = os.environ.get(key_env) if key_env else getpass.getpass('Provider key: ')
    if any(not value or any(c.isspace() for c in value) for value in (pat, key)):
        raise ValueError('invalid credential')
    with tempfile.TemporaryDirectory(prefix='mr7-credentials-') as directory:
        pat_path, key_path = Path(directory) / 'pat', Path(directory) / 'key'
        _private_file(pat_path, pat)
        _private_file(key_path, key)
        yield pat_path, key_path


def _encoded(receipt: dict) -> bytes:
    return (json.dumps(receipt, sort_keys=True, separators=(',', ':')) + '\n').encode()


def _sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _reserve_output(path: Path, receipt: dict) -> tuple[os.stat_result, bytes]:
    """Persist an exclusive quarantine before the child can run."""
    contents = _encoded(receipt)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(contents)
        stream.flush()
        os.fsync(stream.fileno())
        identity = os.fstat(stream.fileno())
    _sync_directory(path.parent)
    return identity, contents


def _finalize_output(path: Path, identity: os.stat_result, original: bytes, receipt: dict) -> None:
    """Replace only our unchanged provisional file; never replace another file."""
    fd, temp_name = tempfile.mkstemp(prefix='.mr7-receipt-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(_encoded(receipt))
            stream.flush()
            os.fsync(stream.fileno())
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        original_fd = os.open(path, flags)
        try:
            current = os.fstat(original_fd)
            if (not stat.S_ISREG(current.st_mode) or
                    (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino) or
                    stat.S_IMODE(current.st_mode) != 0o600):
                raise FileExistsError('output changed')
            with os.fdopen(original_fd, 'rb', closefd=False) as stream:
                if stream.read(len(original) + 1) != original:
                    raise FileExistsError('output changed')
            current_path = os.lstat(path)
            if (current_path.st_dev, current_path.st_ino) != (identity.st_dev, identity.st_ino):
                raise FileExistsError('output changed')
            os.replace(temp_name, path)
            _sync_directory(path.parent)
        finally:
            os.close(original_fd)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def _source_provenance() -> dict:
    """Hash the production Dart tree, host sources, and dependency configuration."""
    env = {name: os.environ[name] for name in SAFE_ENV if name in os.environ}
    env['GIT_OPTIONAL_LOCKS'] = '0'
    result = subprocess.run(
        ['git', 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--',
         'lib', *SOURCE_FILES, *DEPENDENCY_FILES],
        cwd=ROOT, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    records = iter(result.stdout.split('\0'))
    statuses = {}
    for record in records:
        if not record:
            continue
        name = record[3:]
        if name in SOURCE_FILES or name in DEPENDENCY_FILES or (
                name.startswith('lib/') and name.endswith('.dart')):
            statuses[name] = record[:2]
        # A rename/copy has a second NUL-delimited source path.
        if 'R' in record[:2] or 'C' in record[:2]:
            next(records, None)
    dart_files = {
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / 'lib').rglob('*.dart') if path.is_file()
    }
    reported_dart = {name for name in statuses if name.startswith('lib/') and name.endswith('.dart')}
    names = sorted(set(SOURCE_FILES) | set(DEPENDENCY_FILES) | dart_files | reported_dart)
    files = {}
    for name in names:
        source = ROOT / name
        files[name] = {
            'sha256': hashlib.sha256(source.read_bytes()).hexdigest() if source.is_file() else None,
            'gitStatus': statuses.get(name, '  '),
        }
    return {'dirty': bool(statuses), 'files': files}


class _RunInterrupted(Exception):
    pass


def _term_handler(signum: int, frame: object) -> None:
    raise _RunInterrupted()


def _stop_child(child: subprocess.Popen) -> None:
    # The session leader can exit while a descendant ignores TERM. Wait only
    # briefly for the leader, then kill the group even if the leader has exited.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait(timeout=3)


def _quarantine(config: dict, reason: str) -> dict:
    return {
        'schema': 1, 'status': 'FAIL', 'transport': 'synthetic',
        'policy': config['policy'],
        'evidenceClass': 'CANDIDATE_ONLY' if config['policy'] == 'candidate' else 'SYNTHETIC',
        'finalEligible': False, 'releaseSha': config['releaseSha'], 'live': 'NOT_RUN',
        'reason': reason, 'cleanup': 'NOT_RUN', 'sandbox': 'quarantined',
        'remaining': 'NOT_RUN',
    }


def _contains_environment_secret(content: str, key_env: str | None = None) -> bool:
    for name, value in os.environ.items():
        if (len(value) >= 8 and (name == key_env or re.search(r'(?:TOKEN|SECRET|PASSWORD|API_KEY|PAT)$', name, re.I))
                and value in content):
            return True
    return False


def _head_sha() -> str:
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True).stdout.strip()


def run(args: argparse.Namespace) -> int:
    if args.transport != 'synthetic':
        print('Live transport is NOT_RUN and unavailable.', file=sys.stderr)
        return 2
    try:
        if args.expected_user_id <= 0 or not IDENTIFIER.fullmatch(args.namespace):
            raise ValueError('invalid identity')
        sha = _head_sha()
        if not SHA.fullmatch(sha) or (args.expect_release_sha is not None and
                                      args.expect_release_sha != sha):
            raise ValueError('invalid or mismatched SHA')
        config = {'expectedUserId': args.expected_user_id, 'namespace': args.namespace,
                  'releaseSha': sha, 'policy': args.policy, 'suite': args.suite,
                  'provider': provider_config(args.provider_config)}
        provenance = {'head': sha, **_source_provenance()}
        output = Path(args.output).absolute()
        provisional = _quarantine(config, 'in_progress')
        provisional['sourceProvenance'] = provenance
        identity, original = _reserve_output(output, provisional)
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        print('Sandbox setup failed.', file=sys.stderr)
        return 2

    child = None
    outcome = _quarantine(config, 'invalid_or_missing_receipt')
    exit_code = 1
    previous_handler = signal.signal(signal.SIGTERM, _term_handler)
    try:
        with tempfile.TemporaryDirectory(prefix='mr7-sandbox-') as directory:
            config_path = Path(directory) / 'config.json'
            receipt_path = Path(directory) / 'receipt.json'
            _private_file(config_path, json.dumps(config))
            _private_file(receipt_path, '')
            env = {name: os.environ[name] for name in SAFE_ENV if name in os.environ}
            env['MR7_SANDBOX_CONFIG_FILE'] = str(config_path)
            env['MR7_SANDBOX_RECEIPT_FILE'] = str(receipt_path)
            child = subprocess.Popen(
                ['fvm', 'flutter', 'test', '--no-pub', '--reporter', 'expanded',
                 'tool/mr7_sandbox.dart'], cwd=ROOT, env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            child_exit = child.wait()
            head_after = _head_sha()
            provenance_after = {'head': head_after, **_source_provenance()}
            receipt_text = receipt_path.read_text(encoding='utf-8')
            if (len(receipt_text) > 2_000_000 or
                    _contains_environment_secret(receipt_text, config['provider'].get('keyEnv'))):
                raise ValueError('unsafe receipt')
            receipt = json.loads(receipt_text)
            if _contains_environment_secret(json.dumps(receipt, ensure_ascii=False),
                                            config['provider'].get('keyEnv')):
                raise ValueError('unsafe receipt')
            if not validate_receipt(receipt, policy=args.policy, release_sha=sha):
                raise ValueError('invalid receipt')
            if head_after != sha or provenance_after != provenance:
                outcome = _quarantine(config, 'source_drift')
            elif child_exit != 0 and receipt['status'] == 'PASS':
                outcome = _quarantine(config, 'child_failed')
            else:
                outcome = receipt
                if child_exit == 0 and receipt['status'] == 'PASS':
                    exit_code = 0
    except (KeyboardInterrupt, _RunInterrupted, EOFError):
        if child is not None:
            _stop_child(child)
        outcome = _quarantine(config, 'interrupted')
        exit_code = 130
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        if child is not None:
            _stop_child(child)
        outcome = _quarantine(config, 'invalid_or_missing_receipt')
    finally:
        signal.signal(signal.SIGTERM, previous_handler)

    outcome['sourceProvenance'] = provenance
    try:
        _finalize_output(output, identity, original, outcome)
    except OSError:
        print('Receipt output changed or could not be finalized.', file=sys.stderr)
        return 1
    if exit_code == 0:
        print('Synthetic sandbox receipt written; live NOT_RUN.')
    elif exit_code == 130:
        print('Synthetic sandbox interrupted; quarantine receipt written.', file=sys.stderr)
    else:
        print('Synthetic sandbox failed; receipt written.', file=sys.stderr)
    return exit_code


def main(argv: list[str] | None = None) -> int:
    return run(parser().parse_args(argv))


if __name__ == '__main__':
    raise SystemExit(main())
