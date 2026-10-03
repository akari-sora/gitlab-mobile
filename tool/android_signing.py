#!/usr/bin/env python3
"""Create and configure the stable local Android signing identity."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile


DEFAULT_PROPERTIES = Path.home() / '.config/gitlab-mobile/android-signing/signing.properties'
KEYSTORE_NAME = 'gitlab-mobile.p12'
KEY_ALIAS = 'gitlab-mobile'
BEGIN_LOADER = '// GITLAB_MOBILE_SIGNING_LOADER_BEGIN'
END_LOADER = '// GITLAB_MOBILE_SIGNING_LOADER_END'
BEGIN_CONFIG = '    // GITLAB_MOBILE_SIGNING_CONFIG_BEGIN'
END_CONFIG = '    // GITLAB_MOBILE_SIGNING_CONFIG_END'


def properties_path(explicit: str | None = None) -> Path:
    value = explicit or os.environ.get('GITLAB_MOBILE_SIGNING_PROPERTIES')
    return Path(value).expanduser().resolve() if value else DEFAULT_PROPERTIES


def _keytool_run(keytool: str, args: list[str], password: str,
                 *, capture: bool = False) -> subprocess.CompletedProcess[bytes]:
    environment = os.environ.copy()
    environment['GITLAB_MOBILE_KEYSTORE_PASSWORD'] = password
    return subprocess.run(
        [keytool, *args], check=True, env=environment,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def _certificate_sha256(keytool: str, keystore: Path, alias: str,
                        store_type: str, password: str) -> str:
    result = _keytool_run(keytool, [
        '-exportcert', '-keystore', str(keystore), '-alias', alias,
        '-storetype', store_type, '-storepass:env', 'GITLAB_MOBILE_KEYSTORE_PASSWORD',
    ], password, capture=True)
    return hashlib.sha256(result.stdout).hexdigest().upper()


def _write_properties(path: Path, keystore: Path, password: str, alias: str,
                      fingerprint: str, allowed_build_types: str) -> None:
    content = (
        f'storeFile={keystore.resolve()}\n'
        f'storePassword={password}\n'
        f'keyPassword={password}\n'
        f'keyAlias={alias}\n'
        'storeType=PKCS12\n'
        f'certificateSha256={fingerprint}\n'
        f'allowedBuildTypes={allowed_build_types}\n'
    )
    path.write_text(content, encoding='utf-8')
    path.chmod(0o600)


def init_identity(destination: Path, *, keytool: str = 'keytool') -> None:
    destination = destination.expanduser().resolve()
    if destination.exists():
        raise RuntimeError(
            f'{destination} already exists; refusing to replace or repair a signing identity.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock = destination.parent / f'.{destination.name}.init-lock'
    acquired_lock = False
    try:
        try:
            lock.mkdir(mode=0o700)
            acquired_lock = True
        except FileExistsError as exc:
            raise RuntimeError(
                f'{destination} initialization is already running; refusing to race it.') from exc
        if destination.exists():
            raise RuntimeError(
                f'{destination} was created concurrently; refusing to replace it.')
        temporary = Path(tempfile.mkdtemp(prefix='.android-signing-', dir=destination.parent))
        temporary.chmod(0o700)
        password = secrets.token_urlsafe(36)
        try:
            keystore = temporary / KEYSTORE_NAME
            _keytool_run(keytool, [
                '-genkeypair', '-keystore', str(keystore), '-storetype', 'PKCS12',
                '-storepass:env', 'GITLAB_MOBILE_KEYSTORE_PASSWORD',
                '-keypass:env', 'GITLAB_MOBILE_KEYSTORE_PASSWORD',
                '-alias', KEY_ALIAS, '-keyalg', 'RSA', '-keysize', '4096',
                '-validity', '36500', '-dname', 'CN=GitLab Mobile Local Signing',
            ], password)
            if not keystore.is_file():
                raise RuntimeError('keytool did not create the requested PKCS12 keystore.')
            keystore.chmod(0o600)
            fingerprint = _certificate_sha256(
                keytool, keystore, KEY_ALIAS, 'PKCS12', password)
            _write_properties(
                temporary / 'signing.properties', destination / KEYSTORE_NAME,
                password, KEY_ALIAS,
                fingerprint, 'debug,profile,release')
            try:
                destination.mkdir(mode=0o700)
            except FileExistsError as exc:
                raise RuntimeError(
                    f'{destination} was created concurrently; refusing to replace it.') from exc
            destination.chmod(0o700)
            # The destination is ours only after the exclusive mkdir. A crash
            # during these two publications leaves an identity that init will
            # refuse to repair, rather than silently rotating its key.
            (temporary / KEYSTORE_NAME).replace(destination / KEYSTORE_NAME)
            (temporary / 'signing.properties').replace(destination / 'signing.properties')
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    finally:
        if acquired_lock and lock.exists():
            lock.rmdir()


def _load_properties(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith(('#', '!')):
            continue
        key, separator, value = line.partition('=')
        if not separator:
            raise RuntimeError(f'Invalid signing property in {path}.')
        values[key.strip()] = value.strip()
    required = {
        'storeFile', 'storePassword', 'keyPassword', 'keyAlias', 'storeType',
        'certificateSha256', 'allowedBuildTypes',
    }
    missing = sorted(required - values.keys())
    if missing:
        raise RuntimeError(f'Incomplete signing properties: missing {", ".join(missing)}.')
    return values


def verify_identity(path: Path, *, keytool: str = 'keytool') -> dict[str, str]:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise RuntimeError(f'Signing properties not found: {path}')
    values = _load_properties(path)
    if values['storeType'] != 'PKCS12':
        raise RuntimeError('Signing storeType must be PKCS12.')
    allowed = {value.strip() for value in values['allowedBuildTypes'].split(',') if value.strip()}
    if allowed not in ({'debug', 'profile', 'release'}, {'debug'}):
        raise RuntimeError('Invalid allowedBuildTypes in signing properties.')
    if allowed == {'debug'} and (
            os.environ.get('CI', '').lower() != 'true' or
            os.environ.get('GITLAB_MOBILE_ALLOW_DEBUG_ONLY_SIGNING') != '1'):
        raise RuntimeError('Debug-only signing properties are restricted to the explicit CI path.')
    keystore = Path(values['storeFile']).expanduser()
    if not keystore.is_absolute():
        keystore = path.parent / keystore
    if not keystore.is_file():
        raise RuntimeError('Configured signing keystore does not exist.')
    actual = _certificate_sha256(
        keytool, keystore.resolve(), values['keyAlias'], values['storeType'],
        values['storePassword'])
    expected = values['certificateSha256'].replace(':', '').upper()
    if actual != expected:
        raise RuntimeError('Signing certificate SHA-256 does not match the configured identity.')
    return values


def write_ci_properties(path: Path, keystore: Path, mode: str,
                        *, keytool: str = 'keytool') -> None:
    if os.environ.get('CI', '').lower() != 'true':
        raise RuntimeError('CI signing properties may only be created when CI=true.')
    if mode not in {'stable-legacy-debug', 'ephemeral-debug'}:
        raise RuntimeError('Unknown CI signing mode.')
    password = os.environ.get('GITLAB_MOBILE_CI_KEYSTORE_PASSWORD')
    if not password:
        raise RuntimeError('CI keystore password environment is missing.')
    fingerprint = _certificate_sha256(
        keytool, keystore.resolve(), 'androiddebugkey', 'PKCS12', password)
    path.parent.mkdir(parents=True, exist_ok=True)
    _write_properties(
        path, keystore, password, 'androiddebugkey', fingerprint, 'debug')


LOADER = f'''{BEGIN_LOADER}
val gitLabMobileSigningPropertiesFile = java.io.File(
    System.getenv("GITLAB_MOBILE_SIGNING_PROPERTIES")
        ?: "${{System.getProperty("user.home")}}/.config/gitlab-mobile/android-signing/signing.properties"
)
if (!gitLabMobileSigningPropertiesFile.isFile) {{
    throw GradleException("Stable Android signing properties are missing: $gitLabMobileSigningPropertiesFile")
}}
val gitLabMobileSigningProperties = java.util.Properties().apply {{
    gitLabMobileSigningPropertiesFile.reader(Charsets.UTF_8).use {{ load(it) }}
}}
val gitLabMobileRequiredSigningKeys = setOf(
    "storeFile", "storePassword", "keyPassword", "keyAlias", "storeType",
    "certificateSha256", "allowedBuildTypes"
)
val gitLabMobileMissingSigningKeys = gitLabMobileRequiredSigningKeys.filter {{
    gitLabMobileSigningProperties.getProperty(it).isNullOrBlank()
}}
if (gitLabMobileMissingSigningKeys.isNotEmpty()) {{
    throw GradleException("Incomplete stable Android signing properties: $gitLabMobileMissingSigningKeys")
}}
if (gitLabMobileSigningProperties.getProperty("storeType") != "PKCS12") {{
    throw GradleException("Stable Android signing storeType must be PKCS12")
}}
val gitLabMobileSigningStore = java.io.File(gitLabMobileSigningProperties.getProperty("storeFile"))
if (!gitLabMobileSigningStore.isFile) {{
    throw GradleException("Stable Android signing keystore is missing")
}}
val gitLabMobileSigningStorePassword = gitLabMobileSigningProperties.getProperty("storePassword")
val gitLabMobileSigningAlias = gitLabMobileSigningProperties.getProperty("keyAlias")
val gitLabMobileKeyStore = java.security.KeyStore.getInstance("PKCS12").apply {{
    gitLabMobileSigningStore.inputStream().use {{ load(it, gitLabMobileSigningStorePassword.toCharArray()) }}
}}
val gitLabMobileCertificate = gitLabMobileKeyStore.getCertificate(gitLabMobileSigningAlias)
    ?: throw GradleException("Stable Android signing alias is missing")
val gitLabMobileActualCertificateSha256 = java.security.MessageDigest.getInstance("SHA-256")
    .digest(gitLabMobileCertificate.encoded).joinToString("") {{ "%02X".format(it) }}
val gitLabMobileExpectedCertificateSha256 = gitLabMobileSigningProperties
    .getProperty("certificateSha256").replace(":", "").uppercase()
if (gitLabMobileActualCertificateSha256 != gitLabMobileExpectedCertificateSha256) {{
    throw GradleException("Stable Android signing certificate identity changed")
}}
val gitLabMobileAllowedBuildTypes = gitLabMobileSigningProperties
    .getProperty("allowedBuildTypes").split(",").map {{ it.trim() }}.filter {{ it.isNotEmpty() }}.toSet()
if (gitLabMobileAllowedBuildTypes != setOf("debug", "profile", "release") &&
    gitLabMobileAllowedBuildTypes != setOf("debug")) {{
    throw GradleException("Invalid allowedBuildTypes in stable Android signing properties")
}}
if (gitLabMobileAllowedBuildTypes == setOf("debug") &&
    (System.getenv("CI")?.lowercase() != "true" ||
        System.getenv("GITLAB_MOBILE_ALLOW_DEBUG_ONLY_SIGNING") != "1")) {{
    throw GradleException("Debug-only signing is restricted to the explicit CI path")
}}
gradle.taskGraph.whenReady {{ graph ->
    if (gitLabMobileAllowedBuildTypes == setOf("debug") && graph.allTasks.any {{ task ->
            task.project == project &&
                (task.name.contains("release", ignoreCase = true) ||
                    task.name.contains("profile", ignoreCase = true))
        }}) {{
        throw GradleException("CI debug signing cannot build release or profile variants")
    }}
}}
{END_LOADER}

'''

CONFIG = f'''{BEGIN_CONFIG}
    signingConfigs {{
        create("gitLabMobileManaged") {{
            storeFile = gitLabMobileSigningStore
            storePassword = gitLabMobileSigningStorePassword
            keyAlias = gitLabMobileSigningAlias
            keyPassword = gitLabMobileSigningProperties.getProperty("keyPassword")
            storeType = "PKCS12"
        }}
    }}
    buildTypes.configureEach {{
        signingConfig = if (name in gitLabMobileAllowedBuildTypes) {{
            signingConfigs.getByName("gitLabMobileManaged")
        }} else {{
            null
        }}
    }}
{END_CONFIG}
'''


def configure_gradle(path: Path) -> bool:
    if not path.is_file():
        raise RuntimeError(f'Android Gradle template not found: {path}')
    text = path.read_text(encoding='utf-8')
    begin_counts = (text.count(BEGIN_LOADER), text.count(BEGIN_CONFIG))
    end_counts = (text.count(END_LOADER), text.count(END_CONFIG))
    if begin_counts == (1, 1) and end_counts == (1, 1):
        loader = text[text.index(BEGIN_LOADER):text.index(END_LOADER) + len(END_LOADER)]
        config = text[text.index(BEGIN_CONFIG):text.index(END_CONFIG) + len(END_CONFIG)]
        if loader != LOADER.rstrip('\n') or config != CONFIG.rstrip('\n'):
            raise RuntimeError(
                'Stale managed Android signing configuration; review and refresh the owned blocks.')
        return False
    if begin_counts != (0, 0) or end_counts != (0, 0):
        raise RuntimeError('Incomplete Android signing markers; review the Gradle file manually.')
    android_marker = 'android {'
    if text.count(android_marker) != 1:
        raise RuntimeError('Unknown Android Gradle template: expected one android block.')
    legacy = 'signingConfig = signingConfigs.getByName("debug")'
    legacy_count = text.count(legacy)
    if legacy_count > 1:
        raise RuntimeError('Unknown Android Gradle template: multiple debug signing fallbacks.')
    text = text.replace(legacy, '// Stable signing is configured above.')
    text = text.replace(android_marker, LOADER + android_marker + '\n' + CONFIG, 1)
    path.write_text(text, encoding='utf-8')
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest='command', required=True)
    init = subparsers.add_parser('init')
    init.add_argument('--properties')
    init.add_argument('--keytool', default='keytool')
    configure = subparsers.add_parser('configure')
    configure.add_argument('gradle_file', type=Path)
    verify = subparsers.add_parser('verify')
    verify.add_argument('--properties')
    verify.add_argument('--keytool', default='keytool')
    ci = subparsers.add_parser('write-ci-properties')
    ci.add_argument('--properties', required=True, type=Path)
    ci.add_argument('--keystore', required=True, type=Path)
    ci.add_argument('--mode', required=True,
                    choices=('stable-legacy-debug', 'ephemeral-debug'))
    ci.add_argument('--keytool', default='keytool')
    args = parser.parse_args()
    try:
        if args.command == 'init':
            target = properties_path(args.properties).parent
            init_identity(target, keytool=args.keytool)
            print(f'Stable Android signing identity created at {target}.')
        elif args.command == 'configure':
            changed = configure_gradle(args.gradle_file)
            print('Android Gradle signing configuration updated.' if changed else
                  'Android Gradle signing configuration already current.')
        elif args.command == 'verify':
            verify_identity(properties_path(args.properties), keytool=args.keytool)
            print('Stable Android signing identity verified.')
        else:
            write_ci_properties(
                args.properties, args.keystore, args.mode, keytool=args.keytool)
            print(f'CI debug signing properties created for {args.mode}.')
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        parser.exit(1, f'Android signing stopped: {exc}\n')


if __name__ == '__main__':
    raise SystemExit(main())
