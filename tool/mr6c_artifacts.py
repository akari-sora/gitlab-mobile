#!/usr/bin/env python3
"""MR6c host-only APK/manifest readback and release build lockfile guard.

Release builds can capture the R8 compiler dump in a new private directory per
flavor and bind it to the resulting APK and mapping. Legacy receipts remain
operator attestations and are never promoted to captured-input evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

TOOL_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOL_ROOT))
_spec = importlib.util.spec_from_file_location('mr6c_c1_bootstrap_tests', TOOL_ROOT / 'tests/test_bootstrap.py')
_c1 = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(_c1)

PACKAGES = {'gitlab': 'io.gitlabmobile.gitlab_mobile', 'play': 'app.mergeline'}
SERVICE = 'io.gitlabmobile.gitlab_mobile.AgentRunService'
QA_ADAPTER = 'io.gitlabmobile.gitlab_mobile.AgentRunQaAdapter'
LOCAL_SIGNER = 'a15c11c804bd8b40cebf052747bfea91542568989af0b7a092efcfcb7ebff434'
QA_CLASS = re.compile(r'(?:AgentRunQa|Mr6c.*(?:Qa|Handler)|Mr6cBackground|dev\.flutter\.plugins\.integration_test\.)', re.I)
HASH = re.compile(r'^[0-9a-f]{64}$')
DUMP_PROPERTY = 'com.android.tools.r8.dumpinputtodirectory'


class EvidenceError(Exception):
    """Missing or contradictory evidence, never promoted to PASS."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def hash_input(path):
    """Hash an archive, or names and contents of all class files in a directory."""
    path = Path(path)
    require(not path.is_symlink(), f'Symlink input is not accepted: {path}')
    if path.is_file():
        return sha256_file(path)
    require(path.is_dir(), f'Missing R8 program input: {path}')
    files = sorted(path.rglob('*.class'))
    require(files, f'No class files in input directory: {path}')
    h = hashlib.sha256()
    for item in files:
        require(item.is_file() and not item.is_symlink(), f'Invalid class file: {item}')
        name = item.relative_to(path).as_posix().encode('utf-8')
        h.update(len(name).to_bytes(4, 'big'))
        h.update(name)
        h.update(bytes.fromhex(sha256_file(item)))
    return h.hexdigest()


def archive_classes(path):
    path = Path(path)
    if path.is_dir():
        names = (p.relative_to(path).as_posix() for p in path.rglob('*.class'))
        return {name[:-6].replace('/', '.') for name in names}
    require(zipfile.is_zipfile(path), f'R8 input is not a jar/zip: {path}')
    with zipfile.ZipFile(path) as zf:
        return {name[:-6].replace('/', '.') for name in zf.namelist()
                if name.endswith('.class') and not name.startswith('META-INF/')}


def inspect_r8_dump(path):
    """Read every program/feature jar from an R8 dump without extracting it."""
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'R8 dump is missing or a symlink')
    with zipfile.ZipFile(path) as dump:
        names = dump.namelist()
        require(len(names) == len(set(names)), 'R8 dump contains duplicate entries')
        require('build.properties' in names, 'R8 dump has no build.properties')
        info = dump.getinfo('build.properties')
        require(info.file_size <= 1024 * 1024, 'R8 build properties too large')
        raw_properties = dump.read(info)
        properties = {}
        for line in raw_properties.decode('utf-8').splitlines():
            line = line.strip()
            if not line or line.startswith(('#', '!')):
                continue
            key, separator, value = line.partition('=')
            key = key.strip()
            require(separator and key and key not in properties, 'Malformed R8 build properties')
            properties[key] = value.strip()
        require(properties.get('tool', '').lower() == 'r8', 'Dump is not an R8 compilation')
        require(properties.get('mode', '').lower() == 'release', 'R8 dump is not a release compilation')
        require('program.jar' in names, 'R8 dump lacks program.jar')
        features = [name for name in names if name.startswith('feature-') and name.endswith('.jar')]
        require(all(re.fullmatch(r'feature-[1-9][0-9]*\.jar', name) for name in features),
                'Unknown R8 feature input name')
        inputs, classes = [], set()
        for name in ['program.jar', *sorted(features)]:
            info = dump.getinfo(name)
            require(not info.is_dir() and not (info.flag_bits & 1), 'Invalid R8 program input')
            h = hashlib.sha256()
            with dump.open(info) as source:
                for block in iter(lambda: source.read(1024 * 1024), b''):
                    h.update(block)
            with dump.open(info) as source, zipfile.ZipFile(source) as jar:
                members = jar.namelist()
                require(len(members) == len(set(members)), 'Duplicate R8 program jar entries')
                require(not any(member.endswith('.dup') for member in members),
                        'Duplicate program classes in R8 dump require review')
                require(not any(member.endswith('.dex') for member in members),
                        'DEX input cannot be inspected as pre-R8 classes')
                found = {member[:-6].replace('/', '.') for member in members
                         if member.endswith('.class') and not member.startswith('META-INF/')}
            classes.update(found)
            inputs.append({'name': name, 'sha256': h.hexdigest(), 'class_count': len(found)})
        require(SERVICE in classes, 'R8 inputs do not contain the production AgentRunService')
        matches = sorted(name for name in classes if QA_CLASS.search(name))
        require(not matches, f'QA classes present in release R8 inputs: {matches}')
        inventory_hash = hashlib.sha256(('\n'.join(sorted(classes)) + '\n').encode()).hexdigest()
        return {'dump_sha256': sha256_file(path), 'inputs': inputs, 'class_count': len(classes),
                'class_inventory_sha256': inventory_hash,
                'build_properties_sha256': hashlib.sha256(raw_properties).hexdigest(),
                'tool': 'r8', 'mode': 'release'}


def select_r8_dump(directory, *, receipt_name=None):
    """Select exactly one R8 dump from a newly created per-invocation directory."""
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), 'R8 dump directory is missing')
    candidates = []
    for path in sorted(directory.iterdir()):
        if receipt_name is not None and path.name == receipt_name:
            require(path.is_file() and not path.is_symlink(), 'Invalid capture receipt')
            continue
        require(path.is_file() and not path.is_symlink() and re.fullmatch(r'dump[0-9]+\.zip', path.name),
                'Unexpected entry in R8 dump directory')
        with zipfile.ZipFile(path) as dump:
            names = dump.namelist()
            require(len(names) == len(set(names)) and 'build.properties' in names,
                    'Compiler dump has missing or duplicate metadata')
            info = dump.getinfo('build.properties')
            require(info.file_size <= 1024 * 1024, 'Compiler build properties too large')
            text = dump.read(info).decode('utf-8')
            tools = re.findall(r'^\s*tool\s*=\s*([^\s]+)\s*$', text, re.M | re.I)
            require(len(tools) == 1, 'Compiler dump has ambiguous tool metadata')
            if tools[0].lower() == 'r8':
                candidates.append(path)
    require(len(candidates) == 1, 'Expected exactly one unambiguous R8 compiler dump')
    return candidates[0], inspect_r8_dump(candidates[0])


def read_captured_r8(receipt_path, receipt, apk_digest):
    """Verify same-invocation capture contents and bind it to this exact APK."""
    require(receipt.get('kind') == 'same_invocation_r8_dump' and receipt.get('schema') == 2,
            'Unknown R8 capture receipt')
    require(receipt.get('apk_sha256') == apk_digest, 'R8 input receipt is bound to a different APK')
    require(receipt.get('flavor') in PACKAGES and isinstance(receipt.get('source_head'), str)
            and re.fullmatch(r'[0-9a-f]{40}', receipt['source_head']),
            'Invalid R8 capture identity')
    build = receipt.get('build')
    expected_task = ':app:minify' + receipt['flavor'].capitalize() + 'ReleaseWithR8'
    require(isinstance(build, dict) and build.get('task') == expected_task and build.get('task_status') == 'EXECUTED'
            and build.get('exit_code') == 0 and build.get('lock_before') == build.get('lock_after')
            and isinstance(build.get('lock_before'), str) and HASH.fullmatch(build['lock_before']),
            'R8 capture lacks successful fresh task and unchanged lock evidence')
    dump_name = receipt.get('dump_name')
    require(isinstance(dump_name, str) and re.fullmatch(r'dump[0-9]+\.zip', dump_name), 'Invalid R8 dump name')
    # Receipt and compiler outputs share a private directory. No user-selected subset.
    directory = Path(receipt_path).parent
    dump_path, info = select_r8_dump(directory, receipt_name=Path(receipt_path).name)
    require(dump_path.name == dump_name, 'R8 selected dump does not match capture receipt')
    require(info == receipt.get('dump'), 'R8 dump metadata or digest mismatch')
    return {'receipt_sha256': sha256_file(receipt_path), **info, 'dump_path': str(dump_path.resolve()),
            'completeness': 'SAME_INVOCATION_CAPTURE', 'mapping_sha256': receipt.get('mapping_sha256'),
            'source_head': receipt['source_head'], 'flavor': receipt['flavor']}


def read_r8_inputs(receipt_path, apk_digest):
    receipt_path = Path(receipt_path)
    receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
    require(isinstance(receipt, dict), 'R8 input receipt must be an object')
    if receipt.get('schema') == 2:
        return read_captured_r8(receipt_path, receipt, apk_digest)
    require(receipt.get('apk_sha256') == apk_digest, 'R8 input receipt is bound to a different APK')
    require(receipt.get('complete_program_inputs') is True,
            'R8 program input completeness must be explicitly attested')
    inputs = receipt.get('inputs')
    require(isinstance(inputs, list) and inputs, 'R8 program inputs are missing')
    classes, evidence, seen = set(), [], set()
    for entry in inputs:
        require(isinstance(entry, dict) and set(entry) == {'path', 'sha256'}, 'Invalid R8 input entry')
        require(isinstance(entry['path'], str) and isinstance(entry['sha256'], str)
                and HASH.fullmatch(entry['sha256']), 'Invalid R8 input path or SHA-256')
        path = (receipt_path.parent / entry['path']).absolute()
        require(path not in seen, 'Duplicate R8 program input')
        seen.add(path)
        digest = hash_input(path)
        require(digest == entry['sha256'], f'R8 input digest mismatch: {path}')
        names = archive_classes(path)
        require(names, f'R8 input contains no classes: {path}')
        classes.update(names)
        evidence.append({'path': str(path), 'sha256': digest, 'class_count': len(names)})
    require(SERVICE in classes, 'R8 inputs do not contain the production AgentRunService')
    matches = sorted(name for name in classes if QA_CLASS.search(name))
    require(not matches, f'QA classes present in release R8 inputs: {matches}')
    inventory_hash = hashlib.sha256(('\n'.join(sorted(classes)) + '\n').encode()).hexdigest()
    return {'receipt_sha256': sha256_file(receipt_path), 'inputs': evidence,
            'class_count': len(classes), 'class_inventory_sha256': inventory_hash,
            'completeness': 'OPERATOR_ATTESTED', 'mapping_sha256': receipt.get('mapping_sha256')}


def read_mapping(path):
    """Return original-to-obfuscated class and service method mappings."""
    if path is None:
        return {}, {}, None
    path = Path(path)
    require(path.is_file(), f'Missing R8 mapping: {path}')
    classes, methods = {}, {}
    current = None
    for line in path.read_text(encoding='utf-8').splitlines():
        header = re.fullmatch(r'([^\s]+) -> ([^\s]+):', line)
        if header:
            original, renamed = header.groups()
            require(original not in classes, f'Duplicate mapping for {original}')
            classes[original] = renamed
            current = original
            continue
        if current == SERVICE:
            method = re.fullmatch(r'\s*(?:\d+:\d+:)?void (onTimeout|onDestroy)\(([^)]*)\)(?::\d+(?::\d+)?)? -> (\S+)', line)
            if method:
                name, args, mapped = method.groups()
                descriptor = '(II)V' if name == 'onTimeout' and args.replace(' ', '') == 'int,int' else '()V' if name == 'onDestroy' and not args else None
                if descriptor:
                    require((name, descriptor) not in methods or methods[(name, descriptor)] == mapped,
                            'Conflicting service method mappings')
                    methods[(name, descriptor)] = mapped
    require(classes, 'R8 mapping is empty or malformed')
    return classes, methods, sha256_file(path)


def defined_classes(output):
    # apkanalyzer dex packages --defined-only prints C rows; the last column is the class.
    result = set()
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 6 and parts[0] == 'C' and parts[1] == 'd':
            name = parts[-1]
            require(re.fullmatch(r'[A-Za-z0-9_.$-]+', name) is not None,
                    'Unrecognized class name in apkanalyzer output')
            result.add(name)
    require(result, 'No defined DEX classes found; APK analyzer output is incomplete')
    return result


def run(argv, *, cwd=None):
    try:
        completed = subprocess.run([str(a) for a in argv], cwd=cwd, capture_output=True,
                                   text=True, timeout=180, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EvidenceError(f'Could not execute {Path(str(argv[0])).name}: {type(exc).__name__}') from exc
    require(completed.returncode == 0, f'{Path(str(argv[0])).name} exited {completed.returncode}')
    return completed.stdout


def sdk_tools(root):
    sdk = _c1._android_sdk(root)
    suffix = '.exe' if os.name == 'nt' else ''
    aapt = sorted((sdk / 'build-tools').glob('*/aapt2' + suffix))
    signer = sorted((sdk / 'build-tools').glob('*/apksigner' + ('.bat' if os.name == 'nt' else '')))
    analyzer = sorted((sdk / 'cmdline-tools').glob('*/bin/apkanalyzer' + ('.bat' if os.name == 'nt' else '')))
    require(aapt and signer and analyzer, 'Android SDK aapt2, apksigner and apkanalyzer are all required')
    return {'aapt2': aapt[-1], 'apksigner': signer[-1], 'apkanalyzer': analyzer[-1]}


def apk_info(apk, flavor, variant, tools, expected_signer=LOCAL_SIGNER):
    """Read and validate public APK metadata; no keys or devices are touched."""
    apk = Path(apk)
    require(apk.is_file(), f'Missing APK: {apk}')
    require(flavor in PACKAGES and variant in ('debug', 'release'), 'Invalid flavor or variant')
    badging = run([tools['aapt2'], 'dump', 'badging', apk])
    header = next((line for line in badging.splitlines() if line.startswith('package: ')), '')
    values = dict(re.findall(r"(\w+)='([^']*)'", header))
    require(values.get('name') == PACKAGES[flavor], f'{apk}: unexpected package')
    require(values.get('compileSdkVersion') == '36', f'{apk}: unexpected compile SDK')
    require(values.get('versionCode', '').isdigit() and int(values['versionCode']) > 0,
            f'{apk}: invalid versionCode')
    require(values.get('versionName'), f'{apk}: missing versionName')
    min_sdk = re.findall(r"^(?:minSdkVersion|sdkVersion):'([^']*)'$", badging, re.M)
    target_sdk = re.findall(r"^targetSdkVersion:'([^']*)'$", badging, re.M)
    require(min_sdk == ['24'], f'{apk}: minSdk must be 24')
    require(target_sdk == ['36'], f'{apk}: targetSdk must be 36')
    debuggable = bool(re.search(r'^application-debuggable$', badging, re.M))
    require(debuggable == (variant == 'debug'), f'{apk}: unexpected debuggable flag')
    signing = run([tools['apksigner'], 'verify', '--verbose', '--print-certs', apk])
    fingerprints = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F:]+)\s*$', signing, re.M)
    fingerprints = [v.replace(':', '').lower() for v in fingerprints]
    require(len(fingerprints) == 1 and HASH.fullmatch(fingerprints[0]), f'{apk}: expected exactly one certificate')
    require(fingerprints[0] == expected_signer, f'{apk}: signing certificate mismatch')
    schemes = dict(re.findall(r'^Verified using (v\d+) scheme[^:]*: (true|false)\s*$', signing, re.M))
    require(any(value == 'true' for value in schemes.values()), f'{apk}: no verified signing scheme')
    return {'path': str(apk.resolve()), 'sha256': sha256_file(apk), 'size': apk.stat().st_size,
            'package': values['name'], 'version_name': values['versionName'],
            'version_code': int(values['versionCode']), 'compile_sdk': 36, 'min_sdk': 24,
            'target_sdk': 36, 'debuggable': debuggable, 'signer_sha256': fingerprints[0],
            'verified_schemes': schemes}


def verify_dex(apk, variant, tools, mapping=None, flavor='gitlab'):
    require(flavor in PACKAGES, 'Invalid flavor')
    names = defined_classes(run([tools['apkanalyzer'], 'dex', 'packages', '--defined-only', apk]))
    classes, methods, mapping_hash = read_mapping(mapping)
    if variant == 'debug':
        require(QA_ADAPTER in names, 'Debug APK does not define AgentRunQaAdapter')
    else:
        require(not any(QA_CLASS.search(name) for name in classes), 'QA class present in release R8 mapping')
        # The input inventory is checked separately: raw class-name absence alone
        # cannot prove release isolation after obfuscation or removal by R8.
        mapped_qa = {new for old, new in classes.items() if QA_CLASS.search(old)}
        require(not (mapped_qa & names), 'Mapped QA class present in release DEX')
        require(not any(QA_CLASS.search(name) for name in names), 'Unmapped QA class present in release DEX')
    checked = []
    if flavor == 'gitlab':
        service = classes.get(SERVICE, SERVICE)
        require(service in names, 'Compiled service missing from defined DEX classes')
        for original, descriptor in (('onTimeout', '(II)V'), ('onDestroy', '()V')):
            method = methods.get((original, descriptor), original) + descriptor
            code = run([tools['apkanalyzer'], 'dex', 'code', '--class', service, '--method', method, apk])
            require(re.search(r'^\.method\s+[^\n]*\b' + re.escape(method) + r'\s*$', code, re.M)
                    and '.registers ' in code and '.end method' in code,
                    f'{apk}: missing compiled {SERVICE}.{original}')
            checked.append({'original': original + descriptor, 'dex': service + '.' + method})
    return {'defined_class_count': len(names), 'service_methods': checked,
            'mapping_sha256': mapping_hash, 'qa_adapter_defined': QA_ADAPTER in names}


def manifests(root, flavor, variant):
    base = Path(root) / 'build/app/intermediates'
    paths = sorted(path for directory in base.glob('merged_manifest*')
                   for path in directory.rglob('AndroidManifest.xml')
                   if flavor + variant in str(path.relative_to(directory)).lower())
    require(paths, f'No actual {flavor}{variant} merged manifest under {base}')
    for path in paths:
        _c1.verify_merged_manifest(path, flavor)
    return [{'path': str(path.resolve()), 'sha256': sha256_file(path)} for path in paths]


def source_head(root, supplied=None):
    value = supplied if supplied is not None else run(['git', 'rev-parse', 'HEAD'], cwd=root).strip()
    require(re.fullmatch(r'[0-9a-f]{40}', value), 'Cannot establish source HEAD')
    return value


def write_json(path, document):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(json.dumps(document, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    os.replace(tmp, path)


def r8_build_environment(directory):
    """Set dump flags on this invocation only; reject conflicting inherited flags."""
    directory = str(Path(directory).resolve())
    require(not any(char in directory for char in ('"', "'", '\n', '\r')),
            'R8 dump path contains an unsupported quote or newline')
    env = os.environ.copy()
    java = env.get('JAVA_TOOL_OPTIONS', '')
    gradle = env.get('GRADLE_OPTS', '')
    for inherited in (java, gradle, env.get('JDK_JAVA_OPTIONS', ''), env.get('_JAVA_OPTIONS', '')):
        require(not re.search(r'com\.android\.tools\.r8\.dumpinputto(?:directory|file)|'
                              r'org\.gradle\.(?:daemon|caching)\s*=', inherited),
                'Conflicting inherited Gradle or R8 dump options')
    option = f'"-D{DUMP_PROPERTY}={directory}"'
    env['JAVA_TOOL_OPTIONS'] = (java + ' ' + option).strip()
    env['GRADLE_OPTS'] = (gradle + ' -Dorg.gradle.daemon=false -Dorg.gradle.caching=false').strip()
    return env


def executed_r8_task(log, flavor):
    """Require one fresh execution in Gradle --info, not console progress headers."""
    task = ':app:minify' + flavor.capitalize() + 'ReleaseWithR8'
    started = re.compile(re.escape(task) + r' \(Thread\[.*\]\) started\.$')
    pattern = re.compile(r'> Task ' + re.escape(task) + r'(?:\s+(.*?))?\s*$')
    log.seek(0)
    starts, fresh, states = 0, 0, []
    for line in log:
        line = re.sub(r'\x1b\[[0-9;]*m', '', line.rstrip('\n\r'))
        line = re.sub(r'^\[[^\]]*\]\s*', '', line).strip()
        starts += bool(started.fullmatch(line))
        fresh += line == f"Task '{task}' is not up-to-date because:"
        match = pattern.fullmatch(line)
        if match:
            states.append(match.group(1) or '')
        require(not line.startswith((f"Skipping task '{task}'", f"Loaded cache entry for task '{task}'")),
                f'{flavor}: R8 Gradle task was skipped or cached')
    require(starts == fresh == 1 and all(state == '' for state in states),
            f'{flavor}: fresh R8 Gradle task not observed or ambiguous')
    return task


def release_builds(root, expected_lock, output, *, runner=subprocess.run, head=None):
    root = Path(root).resolve()
    require(HASH.fullmatch(expected_lock) is not None, 'Expected lock SHA-256 must be lowercase hexadecimal')
    report = {'source_head': source_head(root) if head is None else source_head(root, head), 'expected_lock_sha256': expected_lock,
              'release_builds': {}, 'status': 'FAIL'}
    lock = root / 'pubspec.lock'
    try:
        for flavor in PACKAGES:
            before = sha256_file(lock)
            entry = {'lock_before': before, 'lock_after': None, 'exit_code': None, 'status': 'FAIL',
                     'command': ['fvm', 'flutter', '--verbose', 'build', 'apk', '--no-android-gradle-daemon',
                                 '--release', '--flavor', flavor]}
            report['release_builds'][flavor] = entry
            write_json(output, report)
            require(before == expected_lock, f'{flavor}: lock differs from the approved hash before build')
            dump_dir = Path(output).absolute().parent / (Path(output).stem + '-r8-' + flavor)
            # mkdir(exist_ok=False) prevents reuse of stale or operator-supplied inputs.
            dump_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
            env = r8_build_environment(dump_dir)
            # Retain private verbose evidence, including failed builds; never print it.
            log_path = dump_dir.with_name(dump_dir.name + '-gradle.log')
            entry['gradle_log'] = str(log_path)
            with os.fdopen(os.open(log_path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600),
                           'w+', encoding='utf-8') as log:
                try:
                    result = runner(entry['command'], cwd=root, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, text=True, check=False)
                    entry['exit_code'] = result.returncode
                finally:
                    log.flush()
                    entry['gradle_log_sha256'] = sha256_file(log_path)
                    entry['lock_after'] = sha256_file(lock) if lock.is_file() else None
                    write_json(output, report)
                require(entry['exit_code'] == 0, f'{flavor}: release build failed')
                require(entry['lock_after'] == before == expected_lock, f'{flavor}: pubspec.lock changed during build')
                entry['r8_task'] = executed_r8_task(log, flavor)
            apk = root / f'build/app/outputs/flutter-apk/app-{flavor}-release.apk'
            mapping = root / f'build/app/outputs/mapping/{flavor}Release/mapping.txt'
            require(apk.is_file() and not apk.is_symlink(), f'{flavor}: release APK missing')
            require(not mapping.is_symlink(), f'{flavor}: mapping is a symlink')
            dump_path, dump = select_r8_dump(dump_dir)
            receipt = {'schema': 2, 'kind': 'same_invocation_r8_dump', 'source_head': report['source_head'],
                       'flavor': flavor, 'apk_sha256': sha256_file(apk),
                       'mapping_sha256': sha256_file(mapping) if mapping.is_file() else None,
                       'dump_name': dump_path.name, 'dump': dump,
                       'build': {'command': entry['command'], 'task': entry['r8_task'],
                                 'task_status': 'EXECUTED', 'exit_code': entry['exit_code'],
                                 'lock_before': before, 'lock_after': entry['lock_after']}}
            receipt_path = dump_dir / 'receipt.json'
            write_json(receipt_path, receipt)
            entry['r8_receipt'] = str(receipt_path)
            entry['r8_receipt_sha256'] = sha256_file(receipt_path)
            entry['r8_dump_sha256'] = dump['dump_sha256']
            entry['apk_sha256'] = receipt['apk_sha256']
            entry['mapping_sha256'] = receipt['mapping_sha256']
            entry['status'] = 'PASS'
            write_json(output, report)
        report['status'] = 'PASS'
    except (EvidenceError, OSError, ValueError, UnicodeError, zipfile.BadZipFile) as exc:
        report['error'] = str(exc)
    finally:
        write_json(output, report)
    return report


def readback(root, receipt_paths, *, head=None):
    root = Path(root).resolve()
    report = {'source_head': source_head(root) if head is None else source_head(root, head), 'generated_config': 'NOT_RUN',
              'artifacts': {}, 'device_os': 'NOT_RUN', 'status': 'FAIL',
              'r8_input_completeness': 'same-invocation capture required; review build provenance independently',
              'dart_aot_qa_handler': 'NOT_VERIFIED',
              'scope': 'generated config, manifests, APK metadata and native DEX; Dart AOT QA handler isolation requires separate evidence'}
    try:
        _c1.verify_android_build_config(root)
        report['generated_config'] = 'PASS'
        tools = sdk_tools(root)
        for flavor in PACKAGES:
            for variant in ('debug', 'release'):
                key = flavor + '_' + variant
                item = {'status': 'FAIL'}
                report['artifacts'][key] = item
                item['merged_manifests'] = manifests(root, flavor, variant)
                apk = root / f'build/app/outputs/flutter-apk/app-{flavor}-{variant}.apk'
                item['apk'] = apk_info(apk, flavor, variant, tools)
                if variant == 'release':
                    require(flavor in receipt_paths, f'{flavor}: missing R8 input receipt')
                    item['r8_inputs'] = read_r8_inputs(receipt_paths[flavor], item['apk']['sha256'])
                    if item['r8_inputs'].get('completeness') == 'SAME_INVOCATION_CAPTURE':
                        require(item['r8_inputs'].get('source_head') == report['source_head'] and
                                item['r8_inputs'].get('flavor') == flavor,
                                f'{flavor}: R8 capture source or flavor mismatch')
                    map_path = root / f'build/app/outputs/mapping/{flavor}Release/mapping.txt'
                    mapping = map_path if map_path.is_file() else None
                    recorded_mapping = item['r8_inputs']['mapping_sha256']
                    if mapping is not None:
                        require(recorded_mapping == sha256_file(mapping),
                                f'{flavor}: R8 mapping is not bound to the APK input receipt')
                    else:
                        require(recorded_mapping is None, f'{flavor}: R8 mapping recorded but missing')
                else:
                    mapping = None
                item['dex'] = verify_dex(apk, variant, tools, mapping, flavor=flavor)
                item['status'] = ('NATIVE_CHECKS_UNVERIFIED' if variant == 'release' and
                                  item['r8_inputs'].get('completeness') != 'SAME_INVOCATION_CAPTURE'
                                  else 'NATIVE_CHECKS_PASS')
        report['status'] = 'NOT_VERIFIED'  # Native checks passed; Dart AOT is a separate open gate.
    except (OSError, ValueError, AssertionError, EvidenceError, json.JSONDecodeError, zipfile.BadZipFile) as exc:
        report['error'] = str(exc)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--root', type=Path, default=Path.cwd(), help='generated project root')
    common.add_argument('--output', type=Path, required=True, help='small JSON evidence file')
    common.add_argument('--source-head', help='full source commit for a git-less generation scratch copy')
    builds = sub.add_parser('build-release', parents=[common], help='build both release flavors with lockfile fences')
    builds.add_argument('--expected-lock-sha256', required=True, help='approved pubspec.lock SHA-256')
    check = sub.add_parser('readback', parents=[common], help='verify built artifacts and both R8 input receipts')
    check.add_argument('--gitlab-r8-inputs', type=Path, required=True, help='gitlab release R8 program input receipt JSON')
    check.add_argument('--play-r8-inputs', type=Path, required=True, help='play release R8 program input receipt JSON')
    record = sub.add_parser('record-r8-inputs', help='record operator-attested complete R8 inputs for one existing APK')
    record.add_argument('--apk', type=Path, required=True)
    record.add_argument('--input', type=Path, action='append', required=True, help='R8 program input jar, zip, or class directory; repeat for every input')
    record.add_argument('--mapping', type=Path, help='mapping.txt from the same build if present')
    record.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == 'record-r8-inputs':
        try:
            require(args.apk.is_file(), 'Missing APK for R8 receipt')
            if args.mapping is not None:
                require(args.mapping.is_file(), 'Missing R8 mapping')
            receipt = {'apk_sha256': sha256_file(args.apk), 'complete_program_inputs': True,
                       'inputs': [{'path': str(path.absolute()), 'sha256': hash_input(path)} for path in args.input],
                       'mapping_sha256': sha256_file(args.mapping) if args.mapping else None}
            write_json(args.output, receipt)
            print(json.dumps(receipt, indent=2, sort_keys=True))
            return 0
        except (EvidenceError, OSError) as exc:
            print(str(exc), file=sys.stderr)
            return 1
    if args.command == 'build-release':
        try:
            report = release_builds(args.root, args.expected_lock_sha256, args.output, head=args.source_head)
        except (EvidenceError, OSError) as exc:
            report = {'status': 'FAIL', 'error': str(exc)}
            write_json(args.output, report)
    else:
        try:
            report = readback(args.root, {'gitlab': args.gitlab_r8_inputs, 'play': args.play_r8_inputs}, head=args.source_head)
        except (EvidenceError, OSError) as exc:
            report = {'status': 'FAIL', 'error': str(exc), 'device_os': 'NOT_RUN'}
        write_json(args.output, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
