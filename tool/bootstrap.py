#!/usr/bin/env python3
"""Generate Android+iOS runners with the pinned SDK, without overwriting app code.

This does not install SDKs, accept Android licenses, configure Apple signing,
register OAuth, build an APK, or claim device verification.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SDK = '3.47.2'
ANDROID = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('android', ANDROID)


def check_sdk(flutter: str) -> None:
    result = subprocess.run([flutter, '--version', '--machine'], capture_output=True,
                            text=True, check=True, timeout=120)
    version = json.loads(result.stdout).get('frameworkVersion')
    if version != SDK:
        raise RuntimeError(f'Expected Flutter {SDK}; found {version}. Do not silently change the SDK baseline.')


def harden_android(folder: Path) -> None:
    manifest = folder / 'app/src/main/AndroidManifest.xml'
    tree = ET.parse(manifest)
    root = tree.getroot()
    if not any(node.get(f'{{{ANDROID}}}name') == 'android.permission.INTERNET'
               for node in root.findall('uses-permission')):
        ET.SubElement(root, 'uses-permission', {f'{{{ANDROID}}}name': 'android.permission.INTERNET'})
    application = root.find('application')
    if application is None:
        raise RuntimeError('Unknown Android template: application missing.')
    for key, value in {'allowBackup': 'false', 'usesCleartextTraffic': 'false',
                       'fullBackupContent': '@xml/backup_rules',
                       'dataExtractionRules': '@xml/data_extraction_rules'}.items():
        application.set(f'{{{ANDROID}}}{key}', value)
    ET.indent(tree, space='    ')
    tree.write(manifest, encoding='utf-8', xml_declaration=True)
    resource = folder / 'app/src/main/res/xml'
    resource.mkdir(parents=True, exist_ok=True)
    excludes = ''.join(f'<exclude domain="{domain}" path="." />' for domain in
                       ('root', 'file', 'database', 'sharedpref', 'external'))
    (resource / 'backup_rules.xml').write_text(f'<full-backup-content>{excludes}</full-backup-content>\n')
    (resource / 'data_extraction_rules.xml').write_text(
        '<data-extraction-rules><cloud-backup disableIfNoEncryptionCapabilities="true">'
        f'{excludes}</cloud-backup><device-transfer>{excludes}</device-transfer></data-extraction-rules>\n')


def configure_ios(folder: Path) -> None:
    # Match ONLY Runner configurations (exclude RunnerTests). Fail on template drift.
    project = folder / 'Runner.xcodeproj/project.pbxproj'
    text = project.read_text(encoding='utf-8')
    blocks = re.compile(r'buildSettings = \{(?P<body>.*?)\n\s*\};', re.S)
    count = 0
    def patch(match: re.Match[str]) -> str:
        nonlocal count
        body = match.group('body')
        if 'INFOPLIST_FILE = Runner/Info.plist;' not in body:
            return match.group(0)
        count += 1
        if 'CODE_SIGN_ENTITLEMENTS' in body:
            raise RuntimeError('Unexpected pre-existing iOS entitlements; review manually.')
        return match.group(0).replace('buildSettings = {',
            'buildSettings = {\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;', 1)
    changed = blocks.sub(patch, text)
    if count != 3:
        raise RuntimeError(f'Expected 3 iOS Runner configurations, found {count}; template review required.')
    project.write_text(changed, encoding='utf-8')
    (folder / 'Runner/Runner.entitlements').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>keychain-access-groups</key><array/></dict></plist>
''', encoding='utf-8')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default='flutter', help='Path to pinned Flutter executable.')
    parser.add_argument('--check-sdk', action='store_true')
    args = parser.parse_args()
    flutter = shutil.which(args.flutter)
    if flutter is None:
        parser.exit(1, f'Flutter {SDK} is not installed/on PATH. No files changed.\n')
    try:
        check_sdk(flutter)
        if args.check_sdk:
            print(f'SDK baseline verified: Flutter {SDK}')
            return 0
        for name in ('android', 'ios', '.metadata'):
            if (ROOT / name).exists():
                raise RuntimeError(f'{name} already exists. Refusing to overwrite native work.')
        with tempfile.TemporaryDirectory(prefix='gitlab-mobile-') as temporary:
            template = Path(temporary) / 'gitlab_mobile'
            subprocess.run([flutter, 'create', '--platforms=android,ios', '--org=io.gitlabmobile',
                            '--project-name=gitlab_mobile', '--no-pub', str(template)], check=True)
            harden_android(template / 'android')
            configure_ios(template / 'ios')
            for name in ('android', 'ios'):
                shutil.copytree(template / name, ROOT / name)
            shutil.copy2(template / '.metadata', ROOT / '.metadata')
        print('Native runners generated. Apple team/signing and device checks remain unconfigured.')
        print('Next: flutter pub get; dart format lib test; flutter analyze; flutter test')
        return 0
    except (RuntimeError, subprocess.SubprocessError, OSError, ValueError) as exc:
        parser.exit(1, f'Bootstrap stopped: {exc}\n')


if __name__ == '__main__':
    raise SystemExit(main())
