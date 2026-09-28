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


OAUTH_SCHEME = 'io.gitlabmobile.app'
OAUTH_HOST = 'oauth'
OAUTH_PATH = '/callback'


def _android_attr(name: str) -> str:
    return f'{{{ANDROID}}}{name}'


def register_oauth_android(root: ET.Element) -> None:
    application = root.find('application')
    if application is None:
        raise RuntimeError('Unknown Android template: application missing.')
    activity = None
    for candidate in application.findall('activity'):
        for intent in candidate.findall('intent-filter'):
            actions = [node.get(_android_attr('name')) for node in intent.findall('action')]
            if 'android.intent.action.MAIN' in actions:
                activity = candidate
                break
        if activity is not None:
            break
    if activity is None:
        return
    for intent in activity.findall('intent-filter'):
        for data in intent.findall('data'):
            if data.get(_android_attr('scheme')) == OAUTH_SCHEME:
                return
    callback = ET.SubElement(activity, 'intent-filter')
    ET.SubElement(callback, 'action', {_android_attr('name'): 'android.intent.action.VIEW'})
    ET.SubElement(callback, 'category', {_android_attr('name'): 'android.intent.category.DEFAULT'})
    ET.SubElement(callback, 'category', {_android_attr('name'): 'android.intent.category.BROWSABLE'})
    ET.SubElement(callback, 'data', {
        _android_attr('scheme'): OAUTH_SCHEME,
        _android_attr('host'): OAUTH_HOST,
        _android_attr('pathPrefix'): OAUTH_PATH,
    })


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
                       'dataExtractionRules': '@xml/data_extraction_rules',
                       'enableOnBackInvokedCallback': 'true',
                       'label': 'GitLab Mobile'}.items():
        application.set(f'{{{ANDROID}}}{key}', value)
    for activity in application.findall('activity'):
        if f'{{{ANDROID}}}label' in activity.attrib:
            activity.set(f'{{{ANDROID}}}label', 'GitLab Mobile')
    register_oauth_android(root)
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
    _transparent_system_bars(folder)


# Edge-to-edge (Android 15) draws behind the system bars. Opaque bar colours in
# the launch/normal themes would put a solid scrim back, so force them transparent.
_SYSTEM_BAR_ITEMS = (
    ('android:statusBarColor', '@android:color/transparent'),
    ('android:navigationBarColor', '@android:color/transparent'),
    ('android:windowDrawsSystemBarBackgrounds', 'true'),
    ('android:enforceStatusBarContrast', 'false'),
    ('android:enforceNavigationBarContrast', 'false'),
)


def _transparent_system_bars(folder: Path) -> None:
    res = folder / 'app/src/main/res'
    if not res.is_dir():
        return
    for path in sorted(res.glob('**/styles.xml')):
        _patch_style_bars(path)


def _patch_style_bars(path: Path) -> None:
    tree = ET.parse(path)
    root = tree.getroot()
    for style in root.findall('style'):
        if style.get('name') not in {'LaunchTheme', 'NormalTheme'}:
            continue
        items = {item.get('name'): item for item in style.findall('item')}
        for name, value in _SYSTEM_BAR_ITEMS:
            item = items.get(name)
            if item is None:
                item = ET.SubElement(style, 'item', {'name': name})
            item.text = value
    ET.indent(tree, space='    ')
    tree.write(path, encoding='utf-8', xml_declaration=True)


def apply_launcher_icons(flutter: str) -> None:
    subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=ROOT, check=True, timeout=180)
    dart = str(Path(flutter).resolve().parent / 'dart')
    subprocess.run([dart, 'run', 'flutter_launcher_icons'], cwd=ROOT, check=True, timeout=120)


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
    register_oauth_ios(folder)
    register_photo_library_ios(folder)
    configure_ios_app_name(folder)


def configure_ios_app_name(folder: Path) -> None:
    path = folder / 'Runner/Info.plist'
    if not path.is_file():
        return
    tree = ET.parse(path)
    plist = tree.getroot().find('dict')
    if plist is None:
        raise RuntimeError('Unknown iOS template: Info.plist dict missing.')
    children = list(plist)
    keys = {node.text: children[i + 1] for i, node in enumerate(children[:-1]) if node.tag == 'key'}
    if 'CFBundleDisplayName' in keys:
        keys['CFBundleDisplayName'].text = 'GitLab Mobile'
    else:
        plist.append(_plist_key('CFBundleDisplayName'))
        ET.SubElement(plist, 'string').text = 'GitLab Mobile'
    if 'CFBundleName' in keys:
        keys['CFBundleName'].text = 'GitLab Mobile'
    else:
        plist.append(_plist_key('CFBundleName'))
        ET.SubElement(plist, 'string').text = 'GitLab Mobile'
    ET.indent(tree, space='\t')
    tree.write(path, encoding='utf-8', xml_declaration=True)


def register_oauth_ios(folder: Path) -> None:
    path = folder / 'Runner/Info.plist'
    if not path.is_file():
        return
    tree = ET.parse(path)
    plist = tree.getroot().find('dict')
    if plist is None:
        raise RuntimeError('Unknown iOS template: Info.plist dict missing.')
    children = list(plist)
    existing = None
    for index, node in enumerate(children):
        if node.tag == 'key' and node.text == 'CFBundleURLTypes' and index + 1 < len(children):
            existing = children[index + 1]
            break
    if existing is not None:
        if OAUTH_SCHEME in ET.tostring(existing, encoding='unicode'):
            return
        _append_oauth_url_type(existing)
    else:
        plist.append(_plist_key('CFBundleURLTypes'))
        _append_oauth_url_type(ET.SubElement(plist, 'array'))
    ET.indent(tree, space='\t')
    tree.write(path, encoding='utf-8', xml_declaration=True)


def _append_oauth_url_type(url_types: ET.Element) -> None:
    item = ET.SubElement(url_types, 'dict')
    item.append(_plist_key('CFBundleTypeRole'))
    ET.SubElement(item, 'string').text = 'Editor'
    item.append(_plist_key('CFBundleURLName'))
    ET.SubElement(item, 'string').text = f'{OAUTH_SCHEME}.oauth'
    item.append(_plist_key('CFBundleURLSchemes'))
    schemes = ET.SubElement(item, 'array')
    ET.SubElement(schemes, 'string').text = OAUTH_SCHEME


def register_photo_library_ios(folder: Path) -> None:
    """Gallery-only image_picker still needs this key for App Store review.

    Runtime photo permission is not requested (`requestFullMetadata: false`).
    Camera and microphone keys are intentionally absent.
    """
    path = folder / 'Runner/Info.plist'
    if not path.is_file():
        return
    tree = ET.parse(path)
    plist = tree.getroot().find('dict')
    if plist is None:
        raise RuntimeError('Unknown iOS template: Info.plist dict missing.')
    for node in list(plist):
        if node.tag == 'key' and node.text == 'NSPhotoLibraryUsageDescription':
            return
    plist.append(_plist_key('NSPhotoLibraryUsageDescription'))
    ET.SubElement(plist, 'string').text = '從相簿選擇圖片，附加到議題、合併請求或留言。'
    ET.indent(tree, space='\t')
    tree.write(path, encoding='utf-8', xml_declaration=True)


def _plist_key(name: str) -> ET.Element:
    key = ET.Element('key')
    key.text = name
    return key


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
        apply_launcher_icons(flutter)
        print('Native runners generated. Apple team/signing and device checks remain unconfigured.')
        print('Next: flutter pub get; dart format lib test; flutter analyze; flutter test')
        return 0
    except (RuntimeError, subprocess.SubprocessError, OSError, ValueError) as exc:
        parser.exit(1, f'Bootstrap stopped: {exc}\n')


if __name__ == '__main__':
    raise SystemExit(main())
