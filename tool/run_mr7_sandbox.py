#!/usr/bin/env python3
"""Run MR7 synthetic or configured live-candidate checks, or read-only reconciliation."""
from __future__ import annotations

import argparse
import base64
from collections import Counter
from contextlib import contextmanager, nullcontext
from datetime import datetime, timedelta, timezone
import getpass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import secrets as random_secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import warnings
from urllib.parse import quote, urlsplit
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

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
    'tool/tests/test_mr7_sandbox_live.py',
    'tool/tests/test_mr7_fix1_recovery.py', 'test/ai/mr7_fix1_cli_fixture.dart',
    'test/ai/mr7_sandbox_live_test.dart', 'test/ai/mr7_live_provider_cases.dart',
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
    p.add_argument('--suite', choices=('all', 'rest', 'graphql', 'advanced'))
    p.add_argument('--expected-user-id', type=int, default=os.environ.get('MR7_EXPECTED_USER_ID', '7'))
    p.add_argument('--namespace', default=os.environ.get('MR7_OWNER_NAMESPACE', 'synthetic-owner'))
    p.add_argument('--provider-config')
    p.add_argument('--only')
    p.add_argument('--pat-env')
    p.add_argument('--expect-release-sha')
    p.add_argument('--output')
    p.add_argument('--reconcile', metavar='STATE_DIRECTORY',
                   help='Read encrypted write metadata without changing quarantine state.')
    p.add_argument('--lookup-project', action='store_true',
                   help='With --reconcile, verify /user and GET only the exact saved project path.')
    return p


def provider_config(path: str | None, *, live: bool = False) -> dict:
    if path is None:
        return {}
    with open(path, encoding='utf-8') as stream:
        data = json.load(stream)
    allowed = {'endpoint', 'format', 'model', 'caps', 'maxCost', 'maxCalls', 'keyEnv'}
    required = allowed | ({'priceInputPerMTok', 'priceOutputPerMTok'} if live else set())
    optional = {'preset'} if live else set()
    if not isinstance(data, dict) or not required <= set(data) or set(data) - required - optional:
        raise ValueError('invalid provider config')
    endpoint = data['endpoint']
    if not isinstance(endpoint, str):
        raise ValueError('invalid endpoint')
    u = urlsplit(endpoint)
    if u.scheme != 'https' or not u.hostname or u.username or u.password or u.query or u.fragment:
        raise ValueError('invalid endpoint')
    if data['format'] not in ('responses', 'chat_completions', 'anthropic_messages'):
        raise ValueError('invalid format')
    if live and (data['format'] not in ('chat_completions', 'anthropic_messages') or
                 data.get('preset', 'custom') not in ('custom', 'opencode-go') or
                 (data.get('preset') == 'opencode-go' and data['format'] != 'chat_completions')):
        raise ValueError('invalid live format or preset')
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
    if live:
        if (set(caps) != {'tools', 'maxTokens'} or caps.get('tools') is not True or
                type(caps.get('maxTokens')) is not int or
                not 512 <= caps['maxTokens'] <= 1_000_000):
            raise ValueError('invalid live capabilities')
        for field in ('priceInputPerMTok', 'priceOutputPerMTok'):
            price = data[field]
            if (isinstance(price, bool) or not isinstance(price, (int, float)) or
                    not math.isfinite(price) or price <= 0):
                raise ValueError('invalid price')
    return data


def validate_receipt(receipt: object, *, final: bool = False, policy: str | None = None,
                     release_sha: str | None = None, transport: str = 'synthetic') -> bool:
    if not isinstance(receipt, dict):
        return False
    actual_policy = receipt.get('policy')
    live = transport == 'live'
    evidence = 'live-candidate' if live else ('CANDIDATE_ONLY' if actual_policy == 'candidate' else 'SYNTHETIC')
    if (type(receipt.get('schema')) is not int or receipt['schema'] != 1 or
            receipt.get('status') not in ('PASS', 'FAIL') or
            receipt.get('transport') != transport or transport not in ('synthetic', 'live') or
            actual_policy not in ('production', 'candidate') or
            receipt.get('evidenceClass') != evidence or
            receipt.get('finalEligible') is not False or
            receipt.get('live') != (('PASS' if receipt.get('status') == 'PASS' else 'FAIL') if live else 'NOT_RUN') or
            not isinstance(receipt.get('releaseSha'), str) or
            not SHA.fullmatch(receipt['releaseSha']) or
            (policy is not None and actual_policy != policy) or
            (release_sha is not None and receipt['releaseSha'] != release_sha)):
        return False
    if 'rateLimit' in receipt and not _rate_limit_valid(receipt):
        return False
    scenarios = receipt.get('scenarios', [])
    if not isinstance(scenarios, list):
        return False
    if live and receipt['status'] == 'PASS' and not _live_pass_evidence(receipt, scenarios):
        return False
    # A closed row cannot share its identity with a runnable or another closed
    # row. Ordinary schema-1 rows remain backwards compatible.
    ids = Counter(row['id'] for row in scenarios
                  if isinstance(row, dict) and isinstance(row.get('id'), str))
    for row in scenarios:
        if not isinstance(row, dict):
            return False
        if receipt['status'] == 'PASS' and any(
                row.get(field) in ('FAIL', 'NOT_VERIFIED', 'writeUncertain')
                for field in ('status', 'readback', 'outcome', 'coreOutcome')):
            return False
        if live and row.get('live') != ('PASS' if row.get('status') == 'PASS' else
                                        'FAIL' if row.get('status') == 'FAIL' else 'NOT_VERIFIED'):
            return False
        refusal = row.get('refusal')
        if row.get('classification') == 'closedVariant' or refusal is not None:
            if (row.get('classification') != 'closedVariant' or
                    not isinstance(row.get('id'), str) or
                    not IDENTIFIER.fullmatch(row['id']) or ids[row['id']] != 1 or
                    any(not isinstance(row.get(field), str) or not row[field].strip()
                        for field in ('suite', 'operation', 'variant', 'tier')) or
                    row.get('releaseSha') != receipt['releaseSha'] or
                    row.get('live') != ('NOT_VERIFIED' if live else 'NOT_RUN') or
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
                if (decision == 'deny' and
                        (type(row.get('mutationCount')) is not int or row['mutationCount'] != 0 or
                         'responseStatus' in row or row.get('status') == 'PASS' or
                         row.get('outcome') == 'succeeded' or row.get('coreOutcome') == 'succeeded')):
                    return False
                if decision == 'deny':
                    ledger = receipt.get('requestLedger', [])
                    if not isinstance(ledger, list):
                        return False
                    for entry in ledger:
                        if (not isinstance(entry, dict) or
                                not isinstance(entry.get('operation'), str) or
                                not entry['operation']):
                            return False
                        if 'scenarioId' not in entry:
                            if entry['operation'] == row.get('operation'):
                                return False
                            continue
                        scenario_id = entry['scenarioId']
                        if (not isinstance(scenario_id, str) or not scenario_id or
                                scenario_id == row.get('id') or ids[scenario_id] != 1):
                            return False
                        owner = next(s for s in scenarios
                                     if isinstance(s, dict) and s.get('id') == scenario_id)
                        if owner.get('operation') != entry['operation']:
                            return False
                        if (entry['operation'] == row.get('operation') and
                                (not isinstance(row.get('id'), str) or ids[row['id']] != 1)):
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


RATE_LIMIT_FIELDS = {'status', 'retryAfter', 'limit', 'observed', 'remaining', 'reset'}


def _rate_limit_valid(receipt: dict) -> bool:
    """Numeric GitLab rate-limit headers, only on a failed rateLimited stop."""
    rate_limit = receipt['rateLimit']
    return (isinstance(rate_limit, dict) and set(rate_limit) <= RATE_LIMIT_FIELDS and
            rate_limit.get('status') == 429 and
            all(type(value) is int and 0 <= value <= 999_999_999_999_999
                for value in rate_limit.values()) and
            receipt.get('status') == 'FAIL' and receipt.get('stopReason') == 'rateLimited')


def _cleanup_terminal(cleanup: dict) -> bool:
    """Verified deletion (404) or GitLab.com's verified 30-day scheduled deletion."""
    if cleanup.get('status') == 'PASS':
        return cleanup.get('deletionVerified') is True and 'markedForDeletionOn' not in cleanup
    if cleanup.get('status') != 'scheduledForDeletion' or cleanup.get('deletionVerified') is not False:
        return False
    date = cleanup.get('markedForDeletionOn')
    if not isinstance(date, str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', date):
        return False
    try:
        datetime.strptime(date, '%Y-%m-%d')
    except ValueError:
        return False
    return True


def _live_pass_evidence(receipt: dict, scenarios: list) -> bool:
    identity = receipt.get('identity')
    if (not isinstance(identity, dict) or
            any(type(identity.get(key)) is not int or identity[key] <= 0
                for key in ('projectId', 'ownerId', 'namespaceId')) or
            identity['projectId'] == 86648389 or
            any(not isinstance(identity.get(key), str) or
                not re.fullmatch(r'[0-9a-f]{64}', identity[key])
                for key in ('pathDigest', 'instanceDigest', 'nonceDigest'))):
        return False
    events, cleanup = receipt.get('events'), receipt.get('cleanup')
    if (not isinstance(events, dict) or events.get('status') != 'PASS' or
            events.get('complete') is not True or events.get('passes') != 2 or
            type(events.get('pages')) is not int or events['pages'] < 2 or
            not isinstance(events.get('start'), str) or not isinstance(events.get('end'), str) or
            not isinstance(events.get('items'), list) or
            not isinstance(cleanup, dict) or not _cleanup_terminal(cleanup) or
            cleanup.get('accepted') is not True or
            cleanup.get('parentChecked') is not True or cleanup.get('identityChecked') is not True or
            receipt.get('quarantined') is not False or receipt.get('secretLeakScan') != 'PASS'):
        return False
    try:
        start = datetime.fromisoformat(events['start'].replace('Z', '+00:00'))
        end = datetime.fromisoformat(events['end'].replace('Z', '+00:00'))
        if start.tzinfo is None or end.tzinfo is None or start > end:
            return False
        ids = set()
        for item in events['items']:
            if (not isinstance(item, dict) or type(item.get('id')) is not int or item['id'] <= 0 or
                    item['id'] in ids or item.get('projectId') != identity['projectId'] or
                    not isinstance(item.get('at'), str) or not isinstance(item.get('action'), str)):
                return False
            at = datetime.fromisoformat(item['at'].replace('Z', '+00:00'))
            if at.tzinfo is None or not start <= at <= end:
                return False
            ids.add(item['id'])
    except (ValueError, TypeError, OverflowError):
        return False
    ledger = receipt.get('requestLedger')
    if (not isinstance(ledger, list) or len(ledger) < 2 or
            any(not isinstance(entry, dict) or not isinstance(entry.get('operation'), str) or
                not isinstance(entry.get('path'), str) or not isinstance(entry.get('method'), str)
                for entry in ledger) or
            not any(entry['operation'] == 'harnessSetup' for entry in ledger) or
            not any(entry['operation'] == 'harnessCleanup' and entry['method'] == 'DELETE' and
                    entry['path'] == f"projects/{identity['projectId']}" for entry in ledger)):
        return False
    provider = receipt.get('provider')
    if not isinstance(provider, dict):
        return False
    calls, usage, spend = provider.get('calls'), provider.get('usage'), provider.get('spend')
    if (type(calls) is not int or calls <= 0 or not isinstance(usage, list) or len(usage) != calls or
            isinstance(spend, bool) or not isinstance(spend, (int, float)) or
            not math.isfinite(spend) or spend < 0):
        return False
    for entry in usage:
        if (not isinstance(entry, dict) or
                set(entry) != {'inputTokens', 'outputTokens', 'spend', 'usageEstimated'} or
                type(entry.get('usageEstimated')) is not int or entry['usageEstimated'] not in (0, 1) or
                any(type(entry.get(key)) is not int or entry[key] < 0
                    for key in ('inputTokens', 'outputTokens')) or
                isinstance(entry.get('spend'), bool) or not isinstance(entry.get('spend'), (int, float)) or
                not math.isfinite(entry['spend']) or entry['spend'] < 0):
            return False
    if not math.isclose(spend, sum(item['spend'] for item in usage), rel_tol=1e-9, abs_tol=1e-12):
        return False
    passes = [row for row in scenarios if isinstance(row, dict) and row.get('status') == 'PASS']
    if not passes:
        return False
    for row in passes:
        count = row.get('mutationCount')
        if type(count) is not int or count < 0:
            return False
        if count > 0 and (row.get('confirmation') != 'explicitOwnerConfirmation' or
                          row.get('readback') != 'PASS' or
                          type(row.get('observerRequests')) is not int or row['observerRequests'] <= 0):
            return False
    return True


def _private_file(path: Path, text: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        stream.write(text)


def _publish_confirmation(path: Path, text: str) -> None:
    """Publish only a complete private response, without replacing another file."""
    fd, staging = tempfile.mkstemp(prefix='.mr7-confirm-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(staging, path)
    finally:
        os.unlink(staging)


def _hidden_input(prompt: str, *, cancelled=None, deadline: datetime | None = None) -> str:
    if cancelled is None:
        with warnings.catch_warnings():
            warnings.simplefilter('error', getpass.GetPassWarning)
            try:
                return getpass.getpass(prompt)
            except getpass.GetPassWarning:
                raise EOFError('hidden input unavailable') from None

    # Approval runs in the parent's thread so every exit unwinds terminal state.
    # Keep canonical line editing and signals, but never fall back to echoed input.
    import select
    try:
        import termios
    except ImportError:
        raise EOFError('cancellable terminal input unavailable') from None
    fd = os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY)
    try:
        saved = termios.tcgetattr(fd)
        hidden = saved[:]
        hidden[3] &= ~(termios.ECHO | termios.ECHONL)
        try:
            termios.tcsetattr(fd, termios.TCSAFLUSH, hidden)
            os.write(fd, prompt.encode('utf-8'))
            answer = bytearray()
            while True:
                if cancelled() or (deadline is not None and datetime.now(timezone.utc) >= deadline):
                    raise _ConfirmationCancelled()
                if not select.select([fd], [], [], 0.05)[0]:
                    continue
                character = os.read(fd, 1)
                if not character:
                    raise EOFError('confirmation input closed')
                if character == b'\n':
                    # Cancellation takes precedence over a simultaneously ready answer.
                    if cancelled() or (deadline is not None and datetime.now(timezone.utc) >= deadline):
                        raise _ConfirmationCancelled()
                    return answer.decode('utf-8')
                answer.extend(character)
                if len(answer) > 4096:
                    raise ValueError('confirmation input too long')
        finally:
            termios.tcsetattr(fd, termios.TCSAFLUSH, saved)
            os.write(fd, b'\n')
    finally:
        os.close(fd)


@contextmanager
def credential_files(*, pat_env: str | None = None, key_env: str | None = None,
                     directory: str | None = None):
    """Deliver credentials through separate owner-only temporary files."""
    for name in (pat_env, key_env):
        if name is not None and not ENV_NAME.fullmatch(name):
            raise ValueError('invalid credential environment name')
    pat = os.environ.get(pat_env) if pat_env else _hidden_input('GitLab PAT: ')
    key = os.environ.get(key_env) if key_env else _hidden_input('Provider key: ')
    if any(not value or any(c.isspace() for c in value) for value in (pat, key)):
        raise ValueError('invalid credential')
    if pat in key or key in pat:
        raise ValueError('credentials overlap')
    with tempfile.TemporaryDirectory(prefix='mr7-credentials-', dir=directory) as temporary:
        pat_path, key_path = Path(temporary) / 'pat', Path(temporary) / 'key'
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


def _finalize_output(path: Path, identity: os.stat_result, original: bytes,
                     receipt: dict) -> tuple[os.stat_result, bytes]:
    """Replace only our unchanged provisional file; never replace another file."""
    fd, temp_name = tempfile.mkstemp(prefix='.mr7-receipt-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        contents = _encoded(receipt)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
            new_identity = os.fstat(stream.fileno())
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
            return new_identity, contents
        finally:
            os.close(original_fd)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def _source_provenance(*, excluded: tuple[str, ...] = ()) -> dict:
    """Hash the production Dart tree, host sources, and dependency configuration."""
    env = {name: os.environ[name] for name in SAFE_ENV if name in os.environ and name not in excluded}
    env['GIT_OPTIONAL_LOCKS'] = '0'
    result = subprocess.run(
        ['git', 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--',
         'lib', 'tool/mr7', *SOURCE_FILES, *DEPENDENCY_FILES],
        cwd=ROOT, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    records = iter(result.stdout.split('\0'))
    statuses = {}
    for record in records:
        if not record:
            continue
        name = record[3:]
        if name in SOURCE_FILES or name in DEPENDENCY_FILES or (
                (name.startswith('lib/') or name.startswith('tool/mr7/')) and name.endswith('.dart')):
            statuses[name] = record[:2]
        # A rename/copy has a second NUL-delimited source path.
        if 'R' in record[:2] or 'C' in record[:2]:
            next(records, None)
    dart_files = {
        path.relative_to(ROOT).as_posix()
        for directory in ('lib', 'tool/mr7')
        for path in (ROOT / directory).rglob('*.dart') if path.is_file()
    }
    reported_dart = {name for name in statuses if (name.startswith('lib/') or name.startswith('tool/mr7/'))
                     and name.endswith('.dart')}
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


class _LiveTimedOut(Exception):
    pass


class _ConfirmationCancelled(Exception):
    pass


def _prepare_live_state(config: dict, state_directory: Path) -> dict:
    """Persist locator and encryption key before any child or network dispatch."""
    nonce = random_secrets.token_hex(16)
    journal_key = os.urandom(32)
    deadline = config.get('deadlineAt') or (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat()
    state = {'schema': 1, 'nonce': nonce,
             'projectPath': f"{config['namespace']}/mr7-{nonce}",
             'projectId': None, 'instance': 'https://gitlab.com',
             'namespace': config['namespace'], 'expectedUserId': config['expectedUserId'],
             'journalAccount': f"https://gitlab.com#{config['expectedUserId']}",
             'journalDirectory': 'journal', 'deadlineAt': deadline,
             'journalKeySha256': hashlib.sha256(journal_key).hexdigest()}
    (state_directory / 'journal').mkdir(mode=0o700)
    _reserve_output(state_directory / 'journal-key.json', {
        'account': state['journalAccount'],
        'key': base64.b64encode(journal_key).decode('ascii'),
    })
    _reserve_output(state_directory / 'run.json', state)
    _sync_directory(state_directory)
    config.update({name: state[name] for name in ('nonce', 'projectPath', 'deadlineAt')})
    return state


def _read_live_state(directory: Path) -> dict:
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError('invalid recovery permissions')
    path = directory / 'run.json'
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 16384:
            raise ValueError('invalid recovery state')
        state = json.loads(stream.read(16385))
    if (not isinstance(state, dict) or state.get('instance') != 'https://gitlab.com' or
            type(state.get('expectedUserId')) is not int or state['expectedUserId'] <= 0 or
            not isinstance(state.get('namespace'), str) or
            not re.fullmatch(r'[a-zA-Z0-9_.-]+', state['namespace']) or
            not isinstance(state.get('nonce'), str) or
            not re.fullmatch(r'[a-zA-Z0-9_-]{8,64}', state['nonce']) or
            state.get('projectPath') != f"{state['namespace']}/mr7-{state['nonce']}"):
        raise ValueError('invalid recovery state')
    return state


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _reconcile_project(state: dict, pat: str, *, origin: str = 'https://gitlab.com') -> dict:
    u = urlsplit(origin)
    if origin != 'https://gitlab.com' and not (
            u.scheme == 'http' and u.hostname == '127.0.0.1' and u.port and
            not u.path and not u.username and not u.password and not u.query and not u.fragment):
        raise ValueError('invalid reconciliation origin')
    opener = build_opener(_NoRedirect)
    def read(path):
        request = Request(f'{origin}/api/v4/{path}', method='GET',
                          headers={'PRIVATE-TOKEN': pat, 'Cache-Control': 'no-cache, no-store'})
        with opener.open(request, timeout=25) as response:
            if response.status != 200:
                raise ValueError('unverified project lookup')
            data = response.read(2_000_001)
            if len(data) > 2_000_000:
                raise ValueError('oversized project lookup')
            return json.loads(data)
    user = read('user')
    if (not isinstance(user, dict) or user.get('id') != state['expectedUserId'] or
            user.get('username') != state['namespace']):
        raise ValueError('reconciliation identity mismatch')
    try:
        project = read('projects/' + quote(state['projectPath'], safe=''))
    except HTTPError as error:
        if error.code == 404:
            return {'status': 'NOT_VISIBLE', 'projectPath': state['projectPath']}
        raise
    if (not isinstance(project, dict) or type(project.get('id')) is not int or
            project['id'] <= 0 or project['id'] == 86648389 or
            project.get('path_with_namespace') != state['projectPath'] or
            (state.get('projectId') is not None and state['projectId'] != project['id']) or
            project.get('visibility') != 'private' or
            not isinstance(project.get('owner'), dict) or project['owner'].get('id') != user['id'] or
            not isinstance(project.get('namespace'), dict) or
            project['namespace'].get('kind') != 'user' or
            project['namespace'].get('full_path') != state['namespace']):
        raise ValueError('reconciliation project mismatch')
    return {'status': 'FOUND', 'projectId': project['id'], 'projectPath': state['projectPath']}


def reconcile(args: argparse.Namespace) -> int:
    try:
        directory = Path(args.reconcile).absolute()
        state = _read_live_state(directory)
        with tempfile.TemporaryDirectory(prefix='mr7-reconcile-', dir=directory.parent) as temporary:
            config_path, report_path = Path(temporary) / 'config.json', Path(temporary) / 'report.json'
            _private_file(config_path, json.dumps({'reconcile': True, 'stateDirectory': str(directory)}))
            _private_file(report_path, '')
            env = {name: os.environ[name] for name in SAFE_ENV if name in os.environ}
            env.update(MR7_SANDBOX_CONFIG_FILE=str(config_path), MR7_SANDBOX_RECEIPT_FILE=str(report_path))
            child = subprocess.run(['fvm', 'flutter', 'test', '--no-pub', '--reporter', 'expanded',
                                    'tool/mr7_sandbox.dart'], cwd=ROOT, env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
            if report_path.stat().st_size > 2_000_000:
                raise ValueError('invalid reconciliation report')
            report = json.loads(report_path.read_text())
        if child.returncode or report.get('status') != 'PASS':
            print(json.dumps(report))
            return 1
        if args.lookup_project:
            name = args.pat_env
            if name is not None and not ENV_NAME.fullmatch(name):
                raise ValueError('invalid credential environment name')
            pat = os.environ.get(name) if name else _hidden_input('GitLab PAT for read-only lookup: ')
            if not pat or any(c.isspace() for c in pat):
                raise ValueError('invalid credential')
            report['projectLookup'] = _reconcile_project(state, pat)
            if _contains_known_secret(report, [pat]):
                raise ValueError('unsafe reconciliation report')
        if args.output:
            _reserve_output(Path(args.output).absolute(), report)
        print(json.dumps(report, sort_keys=True))
        return 0
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError, EOFError):
        print('Reconciliation failed; quarantine preserved.', file=sys.stderr)
        return 1


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
    live = config.get('transport') == 'live'
    return {
        'schema': 1, 'status': 'FAIL', 'transport': 'live' if live else 'synthetic',
        'policy': config['policy'],
        'evidenceClass': 'live-candidate' if live else ('CANDIDATE_ONLY' if config['policy'] == 'candidate' else 'SYNTHETIC'),
        'finalEligible': False, 'releaseSha': config['releaseSha'], 'live': 'FAIL' if live else 'NOT_RUN',
        'reason': reason, 'cleanup': 'NOT_RUN', 'sandbox': 'quarantined',
        'remaining': 'NOT_RUN',
        **({name: config[name] for name in ('nonce', 'projectPath', 'deadlineAt') if name in config} if live else {}),
    }


def _contains_environment_secret(content: str, key_env: str | None = None) -> bool:
    for name, value in os.environ.items():
        if (len(value) >= 8 and (name == key_env or re.search(r'(?:TOKEN|SECRET|PASSWORD|API_KEY|PAT)$', name, re.I))
                and value in content):
            return True
    return False


def _contains_known_secret(value: object, secrets: list[str]) -> bool:
    if isinstance(value, str):
        return any(secret in value for secret in secrets)
    if isinstance(value, dict):
        return any(_contains_known_secret(k, secrets) or _contains_known_secret(v, secrets)
                   for k, v in value.items())
    if isinstance(value, list):
        return any(_contains_known_secret(item, secrets) for item in value)
    return False


def _head_sha(*, excluded: tuple[str, ...] = ()) -> str:
    env = {name: os.environ[name] for name in SAFE_ENV if name in os.environ and name not in excluded}
    env['GIT_OPTIONAL_LOCKS'] = '0'
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True, env=env).stdout.strip()


def _confirm_request(path: Path, response: Path, secrets: list[str], *,
                     cancelled=None, deadline: datetime | None = None) -> None:
    """Prompt only for a validated bounded proposal; malformed requests fail closed."""
    if not path.exists() or response.exists():
        return
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
            raise ValueError('invalid confirmation')
        proposal = json.loads(stream.read(4097))
    required = {'operation', 'tier', 'projectId', 'payloadDigest', 'preview'}
    if (not isinstance(proposal, dict) or not required <= set(proposal) or
            set(proposal) - required - {'requiredTypedName'} or
            not isinstance(proposal['operation'], str) or
            not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,63}', proposal['operation']) or
            proposal['tier'] not in WRITE_TIERS or
            type(proposal['projectId']) is not int or proposal['projectId'] <= 0 or
            not isinstance(proposal['payloadDigest'], str) or
            not re.fullmatch(r'[0-9a-f]{64}', proposal['payloadDigest']) or
            not isinstance(proposal['preview'], str) or len(proposal['preview']) > 2048 or
            any(unicodedata.category(c) in ('Cc', 'Cf') and c not in '\n\t'
                for c in proposal['preview']) or
            ('requiredTypedName' in proposal and
             (not isinstance(proposal['requiredTypedName'], str) or
              not proposal['requiredTypedName'] or len(proposal['requiredTypedName']) > 256 or
              any(unicodedata.category(c) in ('Cc', 'Cf') for c in proposal['requiredTypedName'])))):
        raise ValueError('invalid confirmation')
    prompt = (f"Approve sandbox write {proposal['operation']} tier {proposal['tier']} "
              f"project {proposal['projectId']} digest {proposal['payloadDigest']}\n"
              f"Preview: {proposal['preview']}\n")
    if 'requiredTypedName' in proposal:
        prompt += f"Typed target required: {proposal['requiredTypedName']}\n"
    prompt += 'Type yes to approve: '
    if any(secret in prompt for secret in secrets):
        raise ValueError('unsafe confirmation')
    approved = _hidden_input(prompt, cancelled=cancelled, deadline=deadline) == 'yes'
    answer = {'approved': approved}
    if 'requiredTypedName' in proposal:
        typed = (_hidden_input('Type the target name: ', cancelled=cancelled, deadline=deadline)
                 if approved else None)
        if typed is not None and (len(typed) > 256 or any(secret in typed for secret in secrets)):
            typed = None
            answer['approved'] = False
        answer['typedName'] = typed
    if ((cancelled is not None and cancelled()) or
            (deadline is not None and datetime.now(timezone.utc) >= deadline)):
        raise _ConfirmationCancelled()
    _publish_confirmation(response, json.dumps(answer))


def _wait_live_child(child: subprocess.Popen, request: Path, response: Path,
                     secrets: list[str], *, deadline: datetime | None = None) -> int:
    cancelled_request = False
    while True:
        # The child's deadline fences writes first; allow a bounded state/receipt
        # shutdown before force-stopping a child that cannot unwind.
        if deadline is not None and datetime.now(timezone.utc) >= deadline + timedelta(seconds=30):
            raise _LiveTimedOut()
        if not request.exists():
            cancelled_request = False
        elif not response.exists() and not cancelled_request:
            confirmation_end = datetime.now(timezone.utc) + timedelta(minutes=5)
            if deadline is not None:
                confirmation_end = min(confirmation_end, deadline)
            try:
                _confirm_request(request, response, secrets,
                                 cancelled=lambda: child.poll() is not None or not request.exists(),
                                 deadline=confirmation_end)
            except _ConfirmationCancelled:
                # Leave an abandoned proposal unanswered while the child unwinds.
                cancelled_request = True
        try:
            return child.wait(timeout=0.1)
        except subprocess.TimeoutExpired:
            continue


def run(args: argparse.Namespace) -> int:
    live = args.transport == 'live'
    state_directory = None
    try:
        if args.output is None or args.lookup_project:
            raise ValueError('output required for a run')
        if live:
            if (args.provider_config is None or args.suite is None or
                    'MR7_EXPECTED_USER_ID' not in os.environ or
                    'MR7_OWNER_NAMESPACE' not in os.environ or
                    str(args.expected_user_id) != os.environ['MR7_EXPECTED_USER_ID'] or
                    args.namespace != os.environ['MR7_OWNER_NAMESPACE']):
                print('Live transport is NOT_RUN: missing explicit configuration.', file=sys.stderr)
                return 2
        elif args.only is not None or args.pat_env is not None:
            raise ValueError('live-only argument')
        if args.expected_user_id <= 0 or not IDENTIFIER.fullmatch(args.namespace):
            raise ValueError('invalid identity')
        if args.pat_env is not None and not ENV_NAME.fullmatch(args.pat_env):
            raise ValueError('invalid credential environment name')
        only = None
        if args.only is not None:
            only = args.only.split(',')
            if (not only or any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', item)
                                for item in only) or len(only) != len(set(only))):
                raise ValueError('invalid scenario selection')
        provider = provider_config(args.provider_config, live=live)
        excluded = tuple(name for name in (args.pat_env, provider.get('keyEnv')) if name) if live else ()
        sha = _head_sha(excluded=excluded) if live else _head_sha()
        if not SHA.fullmatch(sha) or (args.expect_release_sha is not None and
                                      args.expect_release_sha != sha):
            raise ValueError('invalid or mismatched SHA')
        config = {'expectedUserId': args.expected_user_id, 'namespace': args.namespace,
                  'releaseSha': sha, 'policy': args.policy, 'suite': args.suite or 'all',
                  'provider': provider}
        if live:
            config['transport'] = 'live'
            if only is not None:
                config['only'] = only
        provenance = {'head': sha, **(_source_provenance(excluded=excluded) if live else _source_provenance())}
        output = Path(args.output).absolute()
        provisional = _quarantine(config, 'in_progress')
        provisional['sourceProvenance'] = provenance
        identity, original = _reserve_output(output, provisional)
        if live:
            state_directory = Path(tempfile.mkdtemp(prefix='mr7-live-state-', dir=output.parent))
            os.chmod(state_directory, 0o700)
            config['stateDirectory'] = str(state_directory)
            _prepare_live_state(config, state_directory)
            provisional['stateDirectory'] = str(state_directory)
            provisional.update({name: config[name] for name in ('nonce', 'projectPath', 'deadlineAt')})
            identity, original = _finalize_output(output, identity, original, provisional)
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        print('Sandbox setup failed.', file=sys.stderr)
        return 2

    child = None
    outcome = _quarantine(config, 'invalid_or_missing_receipt')
    exit_code = 1
    previous_handler = signal.signal(signal.SIGTERM, _term_handler)
    try:
        with tempfile.TemporaryDirectory(prefix='mr7-sandbox-',
                                         dir=output.parent if live else None) as directory:
            config_path = Path(directory) / 'config.json'
            receipt_path = Path(directory) / 'receipt.json'
            _private_file(config_path, json.dumps(config))
            _private_file(receipt_path, '')
            env = {name: os.environ[name] for name in SAFE_ENV if name in os.environ}
            if live:
                env.pop(args.pat_env, None)
                env.pop(config['provider']['keyEnv'], None)
            env['MR7_SANDBOX_CONFIG_FILE'] = str(config_path)
            env['MR7_SANDBOX_RECEIPT_FILE'] = str(receipt_path)
            key_env = config['provider'].get('keyEnv')
            credentials = (credential_files(pat_env=args.pat_env,
                                            key_env=key_env if key_env in os.environ else None,
                                            directory=directory) if live else nullcontext(None))
            with credentials as paths:
                secrets = []
                if live:
                    pat_path, key_path = paths
                    secrets = [pat_path.read_text(encoding='utf-8'), key_path.read_text(encoding='utf-8')]
                    env['MR7_GITLAB_PAT_FILE'] = str(pat_path)
                    env['MR7_PROVIDER_KEY_FILE'] = str(key_path)
                    request_path = Path(directory) / 'confirmation-request.json'
                    response_path = Path(directory) / 'confirmation-response.json'
                    env['MR7_CONFIRM_REQUEST_FILE'] = str(request_path)
                    env['MR7_CONFIRM_RESPONSE_FILE'] = str(response_path)
                    if (_contains_known_secret(config, secrets) or
                            _contains_known_secret(env, secrets)):
                        raise ValueError('unsafe child configuration')
                child = subprocess.Popen(
                    ['fvm', 'flutter', 'test', '--no-pub', '--reporter', 'expanded',
                     'tool/mr7_sandbox.dart'], cwd=ROOT, env=env,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                if live:
                    try:
                        child_exit = _wait_live_child(child, request_path, response_path, secrets,
                                                     deadline=datetime.fromisoformat(config['deadlineAt']))
                    except BaseException:
                        # Stop the whole child group before the private credential files
                        # and the confirmation channel are removed.
                        _stop_child(child)
                        child = None
                        raise
                else:
                    child_exit = child.wait()
                head_after = _head_sha(excluded=excluded) if live else _head_sha()
                provenance_after = {'head': head_after, **(_source_provenance(excluded=excluded)
                                                            if live else _source_provenance())}
                receipt_text = receipt_path.read_text(encoding='utf-8')
                if (len(receipt_text) > 2_000_000 or
                        any(secret in receipt_text for secret in secrets) or
                        _contains_environment_secret(receipt_text, config['provider'].get('keyEnv'))):
                    raise ValueError('unsafe receipt')
                receipt = json.loads(receipt_text)
                encoded = json.dumps(receipt, ensure_ascii=False)
                if (_contains_known_secret(receipt, secrets) or
                        _contains_environment_secret(encoded, config['provider'].get('keyEnv'))):
                    raise ValueError('unsafe receipt')
                if not validate_receipt(receipt, policy=args.policy, release_sha=sha,
                                        transport=args.transport):
                    raise ValueError('invalid receipt')
                if head_after != sha or provenance_after != provenance:
                    outcome = _quarantine(config, 'source_drift')
                elif child_exit != 0 and receipt['status'] == 'PASS':
                    outcome = _quarantine(config, 'child_failed')
                else:
                    outcome = receipt
                    if child_exit == 0 and receipt['status'] == 'PASS':
                        exit_code = 0
    except _LiveTimedOut:
        if child is not None:
            _stop_child(child)
        outcome = _quarantine(config, 'liveTimeout')
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
    if state_directory is not None:
        outcome['stateDirectory'] = str(state_directory)
        if exit_code != 0:
            try:
                saved = _read_live_state(state_directory)
                saved.setdefault('stopReason', outcome.get('reason', 'runUnverified'))
                saved['stoppedAt'] = datetime.now(timezone.utc).isoformat()
                state_path = state_directory / 'run.json'
                contents = state_path.read_bytes()
                _finalize_output(state_path, state_path.stat(), contents, saved)
            except (OSError, ValueError):
                # Retain the last durable state even if a stop update fails.
                pass
    try:
        _finalize_output(output, identity, original, outcome)
    except OSError:
        print('Receipt output changed or could not be finalized.', file=sys.stderr)
        return 1
    if state_directory is not None and exit_code == 0:
        try:
            # Remove recovery material only after successful receipt validation,
            # proven cleanup, source checks and final publication all succeeded.
            shutil.rmtree(state_directory)
        except OSError:
            pass
    if exit_code == 0:
        print('Live candidate receipt written.' if live else 'Synthetic sandbox receipt written; live NOT_RUN.')
    elif exit_code == 130:
        print(f"{'Live' if live else 'Synthetic'} sandbox interrupted; quarantine receipt written.", file=sys.stderr)
    else:
        print(f"{'Live' if live else 'Synthetic'} sandbox failed; receipt written.", file=sys.stderr)
    return exit_code


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    return reconcile(args) if args.reconcile else run(args)


if __name__ == '__main__':
    raise SystemExit(main())
