from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstrap
import android_signing


# Kept here so C8 can reuse the same fail-closed check on actual Gradle output.
# These are baseline plugin permissions, not new bootstrap capabilities.
MERGED_COMMON_PERMISSIONS = {
    'android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.WAKE_LOCK', 'android.permission.USE_BIOMETRIC',
    'android.permission.USE_FINGERPRINT', 'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_DATA_SYNC', 'android.permission.POST_NOTIFICATIONS',
}


def verify_merged_manifest(path, flavor):
    root = ET.parse(path).getroot()
    a = '{http://schemas.android.com/apk/res/android}'
    package = {'gitlab': 'io.gitlabmobile.gitlab_mobile', 'play': 'app.mergeline'}[flavor]
    assert root.get('package') == package, f'{path}: wrong application ID'
    permissions = [node.get(a + 'name') for node in root.findall('uses-permission')]
    expected = MERGED_COMMON_PERMISSIONS | {package + '.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'}
    if flavor == 'gitlab':
        expected |= {'android.permission.REQUEST_INSTALL_PACKAGES'}
    assert len(permissions) == len(set(permissions)), f'{path}: duplicate permissions'
    assert set(permissions) == expected, f'{path}: permission difference {set(permissions) ^ expected}'
    assert not root.findall('uses-permission-sdk-23'), f'{path}: unexpected conditional permissions'
    for node in root.findall('uses-permission'):
        assert node.attrib == {a + 'name': node.get(a + 'name')}, f'{path}: conditional permission'
    app = root.find('application')
    assert app is not None, f'{path}: missing application'
    for name, value in {
        'allowBackup': 'false', 'usesCleartextTraffic': 'false',
        'fullBackupContent': '@xml/backup_rules', 'dataExtractionRules': '@xml/data_extraction_rules',
        'enableOnBackInvokedCallback': 'true',
    }.items():
        assert app.get(a + name) == value, f'{path}: {name}'
    services = app.findall('service')
    namespace = 'io.gitlabmobile.gitlab_mobile'
    agents = [node for node in services if node.get(a + 'name', '').split('.')[-1] == 'AgentRunService']
    assert len(agents) == 1, f'{path}: AgentRunService must be unique'
    service = agents[0]
    assert service.attrib == {a + name: value for name, value in {
        'name': namespace + '.AgentRunService', 'exported': 'false',
        'stopWithTask': 'true', 'foregroundServiceType': 'dataSync',
    }.items()}, f'{path}: service attributes'
    assert not list(service), f'{path}: unexpected service children'
    # image_picker_android 0.8.13+23 contributes this disabled metadata service.
    plugin_services = [node for node in services if node not in agents]
    assert len(plugin_services) == 1, f'{path}: unexpected plugin services'
    plugin = plugin_services[0]
    assert plugin.get(a + 'name') == 'com.google.android.gms.metadata.ModuleDependencies'
    assert plugin.get(a + 'enabled') == 'false' and plugin.get(a + 'exported') == 'false'
    assert [node.get(a + 'name') for node in plugin.findall('intent-filter/action')] == [
        'com.google.android.gms.metadata.MODULE_DEPENDENCIES']
    assert [(node.get(a + 'name'), node.get(a + 'value')) for node in plugin.findall('meta-data')] == [
        ('photopicker_activity:0:required', '')]
    for action in app.findall('.//receiver/intent-filter/action'):
        assert action.get(a + 'name') not in {
            'android.intent.action.BOOT_COMPLETED', 'android.intent.action.LOCKED_BOOT_COMPLETED',
        }, f'{path}: boot receiver'
    def activity(name):
        matches = [node for node in app.findall('activity') if node.get(a + 'name', '').split('.')[-1] == name]
        assert len(matches) == 1, f'{path}: {name} must be unique'
        assert matches[0].get(a + 'name') == namespace + '.' + name, f'{path}: {name} class'
        return matches[0]
    main = activity('MainActivity')
    assert main.get(a + 'exported') == 'true', f'{path}: launcher export'
    assert main.get(a + 'launchMode') == 'singleTop', f'{path}: launcher mode'
    assert [node.get(a + 'value') for node in main.findall('meta-data')
            if node.get(a + 'name') == 'flutter_deeplinking_enabled'] == ['false']
    launcher = [node for node in main.findall('intent-filter')
                if any(action.get(a + 'name') == 'android.intent.action.MAIN' for action in node.findall('action'))]
    assert len(launcher) == 1, f'{path}: launcher intent'
    assert [node.get(a + 'name') for node in launcher[0].findall('category')] == ['android.intent.category.LAUNCHER']
    link = activity('LinkActivity')
    for name, value in {'exported': 'true', 'noHistory': 'true', 'taskAffinity': '', 'excludeFromRecents': 'true'}.items():
        assert link.get(a + name) == value, f'{path}: link {name}'
    assert len(link.findall('intent-filter')) == 2, f'{path}: link intent filters'
    view, share = link.findall('intent-filter')
    assert [node.get(a + 'name') for node in view.findall('action')] == ['android.intent.action.VIEW']
    assert {node.get(a + 'name') for node in view.findall('category')} == {
        'android.intent.category.DEFAULT', 'android.intent.category.BROWSABLE'}
    assert [node.attrib for node in view.findall('data')] == [
        {a + 'scheme': 'https'}, {a + 'host': 'gitlab.com'}]
    assert [node.get(a + 'name') for node in share.findall('action')] == ['android.intent.action.SEND']
    assert [node.get(a + 'name') for node in share.findall('category')] == ['android.intent.category.DEFAULT']
    assert [node.attrib for node in share.findall('data')] == [{a + 'mimeType': 'text/plain'}]
    assert len(main.findall('intent-filter')) == 2, f'{path}: launcher / OAuth filters'
    oauth = [node for node in main.findall('intent-filter')
             if any(action.get(a + 'name') == 'android.intent.action.VIEW' for action in node.findall('action'))]
    assert len(oauth) == 1
    assert [node.attrib for node in oauth[0].findall('data')] == [{
        a + 'scheme': 'io.gitlabmobile.app', a + 'host': 'oauth', a + 'pathPrefix': '/callback'}]
    assert {node.get(a + 'name') for node in oauth[0].findall('category')} == {
        'android.intent.category.DEFAULT', 'android.intent.category.BROWSABLE'}
    sdk = root.find('uses-sdk')
    assert sdk is not None and sdk.get(a + 'minSdkVersion') == '24', f'{path}: min SDK'
    assert sdk.get(a + 'targetSdkVersion') == '36', f'{path}: target SDK'


def verify_generated_root(root):
    root = Path(root)
    intermediates = root / 'build/app/intermediates'
    manifests = {}
    for flavor in ('gitlab', 'play'):
        candidates = [path for directory in intermediates.glob('merged_manifest*')
                      for path in directory.rglob('AndroidManifest.xml')
                      if flavor + 'debug' in str(path.relative_to(directory)).lower()]
        assert candidates, f'No actual {flavor}Debug merged manifest under {intermediates}'
        for path in candidates:
            verify_merged_manifest(path, flavor)
        manifests[flavor] = candidates
    return manifests


def verify_generated_apks(root):
    """compileSdk is written by AAPT into the APK, not Gradle's text manifests."""
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    assert sdk, 'ANDROID_HOME or ANDROID_SDK_ROOT is required for the APK check'
    executable = 'aapt2.exe' if os.name == 'nt' else 'aapt2'
    tools = sorted((Path(sdk) / 'build-tools').glob('*/' + executable))
    assert tools, f'No installed {executable} under {sdk}'
    apks = {}
    for flavor, package in (('gitlab', 'io.gitlabmobile.gitlab_mobile'), ('play', 'app.mergeline')):
        apk = Path(root) / f'build/app/outputs/flutter-apk/app-{flavor}-debug.apk'
        assert apk.is_file(), f'Missing actual {flavor}Debug APK: {apk}'
        result = subprocess.run([str(tools[-1]), 'dump', 'badging', str(apk)],
                                capture_output=True, text=True, check=True, timeout=120)
        header = next((line for line in result.stdout.splitlines() if line.startswith('package: ')), '')
        attributes = dict(re.findall(r"(\w+)='([^']*)'", header))
        assert attributes.get('name') == package, f'{apk}: packaged application ID'
        assert attributes.get('compileSdkVersion') == '36', f'{apk}: packaged compile SDK'
        apks[flavor] = apk
    return apks


class BootstrapTests(unittest.TestCase):
    FRESH_MANIFEST = (
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application>'
        '<activity android:name=".MainActivity" android:exported="true" android:launchMode="singleTop" '
        'android:taskAffinity="" android:theme="@style/LaunchTheme" '
        'android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode" '
        'android:hardwareAccelerated="true" android:windowSoftInputMode="adjustResize">'
        '<meta-data android:name="io.flutter.embedding.android.NormalTheme" android:resource="@style/NormalTheme" />'
        '<intent-filter><action android:name="android.intent.action.MAIN" />'
        '<category android:name="android.intent.category.LAUNCHER" /></intent-filter>'
        '</activity></application></manifest>'
    )
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_android_adds_internet_but_disables_cleartext_and_backup(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest><application/></manifest>')
        bootstrap.harden_android(self.root)
        manifest = ET.parse(source / 'AndroidManifest.xml').getroot()
        attribute = '{' + bootstrap.ANDROID + '}'
        app = manifest.find('application')
        self.assertEqual(app.get(attribute + 'label'), bootstrap.APP_NAME)
        self.assertEqual(app.get(attribute + 'allowBackup'), 'false')
        self.assertEqual(app.get(attribute + 'usesCleartextTraffic'), 'false')
        self.assertEqual(manifest.find('uses-permission').get(attribute + 'name'), 'android.permission.INTERNET')
        backup = ET.parse(source / 'res/xml/data_extraction_rules.xml').getroot()
        self.assertEqual(len(backup.find('device-transfer').findall('exclude')), 5)

    def test_android_declares_every_app_language(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest><application/></manifest>')
        bootstrap.harden_android(self.root)
        attribute = '{' + bootstrap.ANDROID + '}'
        app = ET.parse(source / 'AndroidManifest.xml').getroot().find('application')
        self.assertEqual(app.get(attribute + 'localeConfig'), '@xml/locales_config')
        config = ET.parse(source / 'res/xml/locales_config.xml').getroot()
        self.assertEqual(config.tag, 'locale-config')
        names = [node.get(attribute + 'name') for node in config.findall('locale')]
        self.assertEqual(names, [tag for tag, *_ in bootstrap.l10n.LANGUAGES])
        self.assertIn('zh-TW', names)

    def test_ios_lists_the_app_languages_once(self):
        (self.root / 'Runner').mkdir()
        path = self.root / 'Runner/Info.plist'
        path.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict></dict></plist>\n')
        bootstrap.register_localizations_ios(self.root)
        bootstrap.register_localizations_ios(self.root)
        plist = ET.parse(path).getroot().find('dict')
        keys = [node.text for node in plist if node.tag == 'key']
        self.assertEqual(keys.count('CFBundleLocalizations'), 1)
        names = [node.text for node in plist.find('array')]
        self.assertEqual(names[:3], ['zh-Hant', 'zh-Hans', 'en'])
        self.assertEqual(len(names), len(bootstrap.l10n.LANGUAGES))

    def test_android_registers_oauth_callback_on_launcher_activity(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
            '<application><activity>'
            '<intent-filter><action android:name="android.intent.action.MAIN" /></intent-filter>'
            '</activity></application></manifest>'
        )
        bootstrap.harden_android(self.root)
        bootstrap.harden_android(self.root)
        xml = (source / 'AndroidManifest.xml').read_text()
        self.assertEqual(xml.count('io.gitlabmobile.app'), 1)
        self.assertIn('android.intent.action.VIEW', xml)
        self.assertIn('android.intent.category.BROWSABLE', xml)
        self.assertIn('/callback', xml)

    def test_android_routes_links_from_other_apps_through_a_trampoline(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
            '<application><activity android:name=".MainActivity">'
            '<meta-data android:name="flutter_deeplinking_enabled" android:value="true" />'
            '<intent-filter><action android:name="android.intent.action.MAIN" /></intent-filter>'
            '</activity></application></manifest>'
        )
        bootstrap.harden_android(self.root)
        bootstrap.harden_android(self.root)
        a = '{' + bootstrap.ANDROID + '}'
        application = ET.parse(source / 'AndroidManifest.xml').getroot().find('application')
        activities = {node.get(a + 'name'): node for node in application.findall('activity')}
        self.assertEqual(len(application.findall('activity')), 2, 'idempotent')
        self.assertEqual(set(activities), {'.MainActivity', '.LinkActivity'})
        main = activities['.MainActivity']
        deep_linking = [node.get(a + 'value') for node in main.findall('meta-data')
                        if node.get(a + 'name') == 'flutter_deeplinking_enabled']
        self.assertEqual(deep_linking, ['false'], "Flutter's route deep linking stays off")
        self.assertEqual(len(main.findall('intent-filter')), 2, 'only the launcher and the OAuth callback')
        link = activities['.LinkActivity']
        self.assertEqual(link.get(a + 'exported'), 'true')
        self.assertEqual(link.get(a + 'taskAffinity'), '')
        self.assertEqual(link.get(a + 'noHistory'), 'true')
        view, share = link.findall('intent-filter')
        self.assertEqual(view.find('action').get(a + 'name'), 'android.intent.action.VIEW')
        self.assertIn('android.intent.category.BROWSABLE',
                      [node.get(a + 'name') for node in view.findall('category')])
        data = [(node.get(a + 'scheme'), node.get(a + 'host')) for node in view.findall('data')]
        self.assertEqual(data, [('https', None), (None, 'gitlab.com')])
        self.assertEqual(share.find('action').get(a + 'name'), 'android.intent.action.SEND')
        self.assertEqual(share.find('data').get(a + 'mimeType'), 'text/plain')

    def test_ios_registers_oauth_url_type(self):
        (self.root / 'Runner').mkdir()
        path = self.root / 'Runner/Info.plist'
        path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict>'
            '<key>CFBundleIdentifier</key><string>io.gitlabmobile.gitlabMobile</string>'
            '</dict></plist>\n'
        )
        bootstrap.register_oauth_ios(self.root)
        bootstrap.register_oauth_ios(self.root)
        text = path.read_text()
        self.assertEqual(text.count('<string>io.gitlabmobile.app</string>'), 1)
        self.assertIn('CFBundleURLTypes', text)

    def test_ios_configures_display_name_and_bundle_name(self):
        (self.root / 'Runner').mkdir()
        path = self.root / 'Runner/Info.plist'
        path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict>'
            '<key>CFBundleName</key><string>gitlab_mobile</string>'
            '</dict></plist>\n'
        )
        bootstrap.configure_ios_app_name(self.root)
        bootstrap.configure_ios_app_name(self.root)
        text = path.read_text()
        self.assertIn('<key>CFBundleDisplayName</key>\n\t\t<string>' + bootstrap.APP_NAME + '</string>', text)
        self.assertIn('<key>CFBundleName</key>\n\t\t<string>' + bootstrap.APP_NAME + '</string>', text)
        self.assertNotIn('gitlab_mobile', text)

    def test_ios_adds_display_name_and_bundle_name_when_absent(self):
        folder = self.root / 'RunnerNoName'
        folder.mkdir(parents=True)
        path = folder / 'Runner/Info.plist'
        path.parent.mkdir()
        path.write_text('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict></dict></plist>')
        bootstrap.configure_ios_app_name(folder)
        text = path.read_text()
        self.assertIn('<key>CFBundleDisplayName</key>\n\t\t<string>' + bootstrap.APP_NAME + '</string>', text)
        self.assertIn('<key>CFBundleName</key>\n\t\t<string>' + bootstrap.APP_NAME + '</string>', text)

    def test_android_updates_activity_label_if_present(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True, exist_ok=True)
        (source / 'AndroidManifest.xml').write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
            '<application><activity android:label="gitlab_mobile" /></application></manifest>'
        )
        bootstrap.harden_android(self.root)
        manifest = ET.parse(source / 'AndroidManifest.xml').getroot()
        attribute = '{' + bootstrap.ANDROID + '}'
        self.assertEqual(manifest.find('application').get(attribute + 'label'), bootstrap.APP_NAME)
        self.assertEqual(manifest.find('application/activity').get(attribute + 'label'), bootstrap.APP_NAME)

    def test_android_enables_predictive_back(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest><application/></manifest>')
        bootstrap.harden_android(self.root)
        bootstrap.harden_android(self.root)
        manifest = ET.parse(source / 'AndroidManifest.xml').getroot()
        attribute = '{' + bootstrap.ANDROID + '}'
        app = manifest.find('application')
        self.assertEqual(app.get(attribute + 'enableOnBackInvokedCallback'), 'true')
        xml = (source / 'AndroidManifest.xml').read_text()
        self.assertEqual(xml.count('enableOnBackInvokedCallback'), 1)

    def test_android_launch_themes_do_not_force_opaque_system_bars(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest><application/></manifest>')
        styles = source / 'res/values/styles.xml'
        styles.parent.mkdir(parents=True)
        styles.write_text(
            '<resources>'
            '<style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">'
            '<item name="android:windowBackground">@drawable/launch_background</item>'
            '<item name="android:statusBarColor">#FF000000</item>'
            '</style>'
            '<style name="NormalTheme" parent="@android:style/Theme.Light.NoTitleBar">'
            '<item name="android:windowBackground">?android:colorBackground</item>'
            '</style>'
            '<style name="Other"><item name="android:statusBarColor">#FF112233</item></style>'
            '</resources>'
        )
        night = source / 'res/values-night/styles.xml'
        night.parent.mkdir(parents=True)
        night.write_text(
            '<resources><style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">'
            '<item name="android:windowBackground">@drawable/launch_background</item>'
            '</style></resources>'
        )
        bootstrap.harden_android(self.root)
        bootstrap.harden_android(self.root)
        for path in (styles, night):
            root = ET.parse(path).getroot()
            for style in root.findall('style'):
                if style.get('name') not in {'LaunchTheme', 'NormalTheme'}:
                    continue
                items = {item.get('name'): item.text for item in style.findall('item')}
                self.assertEqual(items.get('android:statusBarColor'), '@android:color/transparent')
                self.assertEqual(items.get('android:navigationBarColor'), '@android:color/transparent')
                self.assertEqual(items.get('android:windowDrawsSystemBarBackgrounds'), 'true')
                self.assertEqual(items.get('android:enforceNavigationBarContrast'), 'false')
                self.assertEqual(sum(1 for item in style.findall('item')
                                     if item.get('name') == 'android:statusBarColor'), 1)
                self.assertEqual(style.get('parent'), bootstrap.APP_THEME_PARENT,
                                 'the app lock prompt needs an AppCompat theme on Android 8 and below')
        other = {item.get('name'): item.text
                 for item in ET.parse(styles).getroot().find('style[@name="Other"]').findall('item')}
        self.assertEqual(other.get('android:statusBarColor'), '#FF112233')

    def test_android_patch_is_idempotent(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest><application/></manifest>')
        bootstrap.harden_android(self.root)
        bootstrap.harden_android(self.root)
        self.assertEqual(len(ET.parse(source / 'AndroidManifest.xml').getroot().findall('uses-permission')), 4)

    def test_unknown_android_template_fails(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest/>')
        with self.assertRaises(RuntimeError):
            bootstrap.harden_android(self.root)

    def test_configure_android_embeds_stable_signing_loader(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text(self.FRESH_MANIFEST)
        activity = source / 'kotlin' / bootstrap.KOTLIN_PACKAGE / 'MainActivity.kt'
        activity.parent.mkdir(parents=True)
        activity.write_text(bootstrap.TEMPLATE_MAIN_ACTIVITY)
        gradle = self.root / 'app/build.gradle.kts'
        gradle.write_text(
            'plugins { id("com.android.application") }\n'
            'android { buildTypes { release { '
            'signingConfig = signingConfigs.getByName("debug") } } }\n')
        bootstrap.configure_android(self.root)
        bootstrap.configure_android(self.root)
        text = gradle.read_text()
        self.assertEqual(text.count(android_signing.BEGIN_IMPORTS), 1)
        self.assertEqual(text.count(android_signing.BEGIN_LOADER), 1)
        self.assertEqual(text.count(android_signing.BEGIN_CONFIG), 1)
        self.assertEqual(text.count(bootstrap.FLAVORS_BEGIN), 1)
        self.assertEqual(text.count(bootstrap.UPDATE_DEPENDENCIES_BEGIN), 1)
        self.assertNotIn('signingConfigs.getByName("debug")', text)
        self.assertEqual(activity.read_text(), bootstrap.MAIN_ACTIVITY)

    def prepare_ios(self, count):
        (self.root / 'Runner.xcodeproj').mkdir()
        (self.root / 'Runner').mkdir()
        path = self.root / 'Runner.xcodeproj/project.pbxproj'
        path.write_text(('buildSettings = {\nINFOPLIST_FILE = Runner/Info.plist;\n};\n') * count)
        return path

    def test_ios_patches_three_runner_configs_and_creates_entitlements(self):
        path = self.prepare_ios(3)
        bootstrap.configure_ios(self.root)
        self.assertEqual(path.read_text().count('CODE_SIGN_ENTITLEMENTS'), 3)
        self.assertTrue((self.root / 'Runner/Runner.entitlements').is_file())

    def test_ios_template_drift_does_not_silently_patch(self):
        path = self.prepare_ios(2)
        original = path.read_bytes()
        with self.assertRaises(RuntimeError):
            bootstrap.configure_ios(self.root)
        self.assertEqual(path.read_bytes(), original)

    def test_ios_photo_library_usage_is_idempotent_and_omits_camera(self):
        (self.root / 'Runner').mkdir()
        path = self.root / 'Runner/Info.plist'
        path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict>'
            '<key>CFBundleIdentifier</key><string>io.gitlabmobile.gitlabMobile</string>'
            '</dict></plist>\n'
        )
        bootstrap.register_photo_library_ios(self.root)
        bootstrap.register_photo_library_ios(self.root)
        text = path.read_text()
        self.assertEqual(text.count('NSPhotoLibraryUsageDescription'), 1)
        self.assertIn('從相簿選擇圖片', text)
        self.assertNotIn('NSCameraUsageDescription', text)
        self.assertNotIn('NSMicrophoneUsageDescription', text)

    def test_ios_face_id_usage_is_recorded_once(self):
        (self.root / 'Runner').mkdir()
        path = self.root / 'Runner/Info.plist'
        path.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict></dict></plist>\n')
        bootstrap.register_face_id_ios(self.root)
        bootstrap.register_face_id_ios(self.root)
        text = path.read_text()
        self.assertEqual(text.count('NSFaceIDUsageDescription'), 1)
        self.assertIn('App 鎖定', text)

    def test_configure_ios_records_photo_library_usage(self):
        self.prepare_ios(3)
        path = self.root / 'Runner/Info.plist'
        path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict></dict></plist>\n'
        )
        bootstrap.configure_ios(self.root)
        self.assertIn('NSPhotoLibraryUsageDescription', path.read_text())

    def test_ios_does_not_overwrite_preexisting_entitlements_setting(self):
        path = self.prepare_ios(3)
        path.write_text(path.read_text().replace('buildSettings = {', 'buildSettings = {\nCODE_SIGN_ENTITLEMENTS = Other.plist;', 1))
        with self.assertRaises(RuntimeError):
            bootstrap.configure_ios(self.root)

    GRADLE = (
        'plugins {\n    id("com.android.application")\n}\n\n'
        'android {\n    namespace = "io.gitlabmobile.gitlab_mobile"\n'
        '    buildTypes {\n        release {\n'
        '            signingConfig = signingConfigs.getByName("debug")\n        }\n    }\n}\n'
    )

    def test_flavors_follow_the_signing_block_once(self):
        gradle = self.root / 'build.gradle.kts'
        gradle.write_text(self.GRADLE)
        android_signing.configure_gradle(gradle)
        self.assertTrue(bootstrap.configure_flavors(gradle))
        text = gradle.read_text()
        self.assertEqual(text.count('productFlavors'), 1)
        self.assertIn('create("gitlab")', text)
        self.assertIn('create("play")', text)
        self.assertNotIn('applicationIdSuffix', text)
        gitlab = text[text.index('create("gitlab")'):text.index('create("play")')]
        play = text[text.index('create("play")'):text.index(bootstrap.FLAVORS_END)]
        self.assertNotIn('applicationId', gitlab, 'installed GitLab-channel previews keep updating in place')
        self.assertIn(f'applicationId = "{bootstrap.PLAY_APPLICATION_ID}"', play)
        self.assertNotIn('gitlab', bootstrap.PLAY_APPLICATION_ID, 'no trademark in the store package name')
        self.assertLess(text.index(android_signing.END_CONFIG), text.index(bootstrap.FLAVORS_BEGIN))
        self.assertLess(text.index('android {'), text.index(bootstrap.FLAVORS_BEGIN))
        self.assertFalse(bootstrap.configure_flavors(gradle))
        self.assertEqual(gradle.read_text(), text)

    def test_flavors_refuse_stale_partial_or_foreign_blocks(self):
        gradle = self.root / 'build.gradle.kts'
        gradle.write_text(self.GRADLE)
        with self.assertRaisesRegex(RuntimeError, 'signing before'):
            bootstrap.configure_flavors(gradle)
        android_signing.configure_gradle(gradle)
        bootstrap.configure_flavors(gradle)
        configured = gradle.read_text()
        gradle.write_text(configured.replace('create("play")', 'create("store")'))
        with self.assertRaisesRegex(RuntimeError, 'Stale managed Android flavors'):
            bootstrap.configure_flavors(gradle)
        gradle.write_text(configured.replace(bootstrap.FLAVORS_END, ''))
        with self.assertRaisesRegex(RuntimeError, 'Incomplete Android flavor markers'):
            bootstrap.configure_flavors(gradle)
        gradle.write_text(self.GRADLE.replace('android {\n', 'android {\n    productFlavors {}\n'))
        android_signing.configure_gradle(gradle)
        with self.assertRaisesRegex(RuntimeError, 'flavors already defined'):
            bootstrap.configure_flavors(gradle)


    def _app(self):
        app = self.root / 'app'
        activity = app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'MainActivity.kt'
        activity.parent.mkdir(parents=True)
        activity.write_text(bootstrap.TEMPLATE_MAIN_ACTIVITY)
        gradle = app / 'build.gradle.kts'
        gradle.write_text(self.GRADLE)
        android_signing.configure_gradle(gradle)
        bootstrap.configure_flavors(gradle)
        return app

    def test_update_channels_split_by_flavor(self):
        app = self._app()
        bootstrap.configure_update_channels(app)
        gitlab_manifest = (app / 'src/gitlab/AndroidManifest.xml').read_text()
        self.assertIn('android.permission.REQUEST_INSTALL_PACKAGES', gitlab_manifest)
        self.assertIn('android:exported="false"', gitlab_manifest)
        self.assertIn('${applicationId}.updates', gitlab_manifest)
        self.assertFalse((app / 'src/play/AndroidManifest.xml').exists(),
                         'the Play flavor must not request install permission')
        self.assertIn('<cache-path name="updates" path="updates/" />',
                      (app / 'src/gitlab/res/xml/update_paths.xml').read_text())
        gitlab = (app / 'src/gitlab/kotlin' / bootstrap.KOTLIN_PACKAGE / 'AppUpdateChannel.kt').read_text()
        play = (app / 'src/play/kotlin' / bootstrap.KOTLIN_PACKAGE / 'AppUpdateChannel.kt').read_text()
        for source in (gitlab, play):
            self.assertIn('object AppUpdateChannel', source)
            self.assertIn(f'"{bootstrap.UPDATE_CHANNEL}"', source)
        self.assertIn('apk.parentFile != updates', gitlab, 'only APKs in cache/updates/ are installed')
        self.assertIn('canRequestPackageInstalls', gitlab)
        self.assertNotIn('play.core', gitlab)
        self.assertIn('AppUpdateType.FLEXIBLE', play)
        self.assertNotIn('REQUEST_INSTALL_PACKAGES', play)
        self.assertNotIn('FileProvider', play)
        self.assertEqual((app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'MainActivity.kt').read_text(),
                         bootstrap.MAIN_ACTIVITY)
        self.assertIn('LinkChannel.register(flutterEngine, this)', bootstrap.MAIN_ACTIVITY)
        self.assertIn('class MainActivity : FlutterFragmentActivity()', bootstrap.MAIN_ACTIVITY,
                      'local_auth needs a FragmentActivity')
        links = (app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'LinkActivity.kt').read_text()
        self.assertIn('class LinkActivity : Activity()', links)
        self.assertIn(f'"{bootstrap.LINK_CHANNEL}"', links)
        self.assertIn('Intent.FLAG_ACTIVITY_SINGLE_TOP', links)
        self.assertIn('uri.scheme == "https"', links, 'only an https URL is forwarded')
        self.assertIn('Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS', links)
        gradle = (app / 'build.gradle.kts').read_text()
        self.assertIn('"gitlabImplementation"("androidx.core:core:', gradle)
        self.assertIn('"playImplementation"("com.google.android.play:app-update:', gradle)
        self.assertNotIn('implementation("com.google.android.play', gradle.replace('"playImplementation"', ''))
        bootstrap.configure_update_channels(app)
        self.assertEqual((app / 'build.gradle.kts').read_text(), gradle, 'idempotent')

    def test_update_channels_refuse_unknown_activity_or_stale_block(self):
        app = self._app()
        activity = app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'MainActivity.kt'
        activity.write_text(bootstrap.TEMPLATE_MAIN_ACTIVITY.replace('FlutterActivity()', 'FlutterFragmentActivity()'))
        with self.assertRaisesRegex(RuntimeError, 'Unknown MainActivity template'):
            bootstrap.configure_update_channels(app)
        for earlier in (bootstrap.UPDATE_ONLY_MAIN_ACTIVITY, bootstrap.LINKS_MAIN_ACTIVITY):
            gradle = app / 'build.gradle.kts'
            if bootstrap.UPDATE_DEPENDENCIES_BEGIN not in gradle.read_text():
                gradle.write_text(gradle.read_text() + '\n' + bootstrap.UPDATE_DEPENDENCIES)
            files = {
                f'src/gitlab/kotlin/{bootstrap.KOTLIN_PACKAGE}/AppUpdateChannel.kt': bootstrap.GITLAB_UPDATE_CHANNEL,
                'src/gitlab/AndroidManifest.xml': bootstrap.GITLAB_MANIFEST,
                'src/gitlab/res/xml/update_paths.xml': bootstrap.GITLAB_UPDATE_PATHS,
                f'src/play/kotlin/{bootstrap.KOTLIN_PACKAGE}/AppUpdateChannel.kt': bootstrap.PLAY_UPDATE_CHANNEL,
            }
            if earlier == bootstrap.LINKS_MAIN_ACTIVITY:
                files[f'src/main/kotlin/{bootstrap.KOTLIN_PACKAGE}/LinkActivity.kt'] = bootstrap.LINK_ACTIVITY
            for name, content in files.items():
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            activity.write_text(earlier)
            bootstrap.configure_update_channels(app)
            self.assertEqual(activity.read_text(), bootstrap.MAIN_ACTIVITY, 'an earlier managed activity is upgraded')
        bootstrap.configure_update_channels(app)
        gradle = app / 'build.gradle.kts'
        gradle.write_text(gradle.read_text().replace('app-update:2.1.0', 'app-update:1.0.0'))
        with self.assertRaisesRegex(RuntimeError, 'Stale managed update dependencies'):
            bootstrap.configure_update_channels(app)

    def _managed_android(self):
        app = self._app()
        manifest = app / 'src/main/AndroidManifest.xml'
        manifest.write_text(self.FRESH_MANIFEST)
        bootstrap.configure_android(self.root)
        return app

    @staticmethod
    def _body(source, signature):
        start = source.index('{', source.index(signature))
        depth = 1
        end = start + 1
        while depth:
            depth += (source[end] == '{') - (source[end] == '}')
            end += 1
        return source[start + 1:end - 1]

    def test_agent_manifest_has_exact_permissions_and_service(self):
        app = self._managed_android()
        a = '{' + bootstrap.ANDROID + '}'
        root = ET.parse(app / 'src/main/AndroidManifest.xml').getroot()
        permissions = [node.get(a + 'name') for node in root.findall('uses-permission')]
        self.assertCountEqual(permissions, [
            'android.permission.INTERNET', 'android.permission.FOREGROUND_SERVICE',
            'android.permission.FOREGROUND_SERVICE_DATA_SYNC', 'android.permission.POST_NOTIFICATIONS',
        ])
        self.assertEqual(len(permissions), len(set(permissions)))
        services = root.findall('application/service')
        self.assertEqual(len(services), 1)
        self.assertEqual(services[0].attrib, {
            a + 'name': '.AgentRunService', a + 'exported': 'false',
            a + 'foregroundServiceType': 'dataSync', a + 'stopWithTask': 'true',
        })
        self.assertFalse(root.findall('.//receiver'))
        for forbidden in ('BOOT_COMPLETED', 'SCHEDULE_EXACT_ALARM', 'USE_EXACT_ALARM',
                          'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'):
            self.assertNotIn(forbidden, ET.tostring(root, encoding='unicode'))
        self.assertFalse(list((app / 'src/gitlab').rglob('AgentRunService.kt')))
        self.assertFalse(list((app / 'src/play').rglob('AgentRunService.kt')))
        self.assertTrue((app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'AgentRunService.kt').is_file())

    def test_agent_service_promotes_before_active_and_uses_pinned_api_overloads(self):
        source = bootstrap.AGENT_RUN_SERVICE
        self.assertIn('override fun onTimeout(startId: Int, fgsType: Int)', source)
        self.assertIn('return START_NOT_STICKY', self._body(source, 'override fun onStartCommand'))
        promote = self._body(source, 'internal fun promote')
        self.assertRegex(promote, r'if \(Build.VERSION.SDK_INT >= 29\)\s*\{\s*'
                         r'startForeground\(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC\)'
                         r'\s*\} else \{\s*startForeground\(NOTIFICATION_ID, notification\)')
        start = self._body(source, 'fun serviceStarted')
        self.assertLess(start.index('instance.promote('), start.index('permit.state = State.ACTIVE'))
        self.assertLess(start.index('permit.state = State.ACTIVE'), start.index('active(it.result'))
        self.assertIn('if (permit.id != expectedId) return', start)
        self.assertIn('if (permit == null) { instance.stopNative(); return }', start)
        self.assertIn('State.STARTING', source)
        for forbidden in ('FlutterEngine(', 'SharedPreferences', 'WorkManager', 'AlarmManager',
                          'START_STICKY', 'onTaskRemoved', 'File(', 'CoroutineScope', 'WakeLock'):
            self.assertNotIn(forbidden, source)
        self.assertNotRegex(source, r'\bThread\(')
        self.assertIn('Looper.myLooper() == Looper.getMainLooper()', source)
        self.assertIn('AgentRunsChannel.serviceCreated(this)', self._body(source, 'override fun onCreate'))
        created = self._body(source, 'fun serviceCreated')
        self.assertIn('instance.permitId = permit.id', created, 'bind before first start callback / early destroy')
        self.assertIn('service = instance', created)

    def test_agent_destroy_timeout_and_stop_invalidate_before_native_stop_and_callback(self):
        source = bootstrap.AGENT_RUN_SERVICE
        for signature, reason in [('override fun onTimeout', 'timeout'), ('override fun onDestroy', 'service_destroyed')]:
            body = self._body(source, signature)
            self.assertTrue(body.lstrip().startswith(f'AgentRunsChannel.serviceEnded(this, "{reason}")'))
            self.assertNotIn('promote(', body)
            self.assertNotIn('serviceStarted(', body)
        ended = self._body(source, 'fun serviceEnded')
        self.assertLess(ended.index('invalidate(reason)'), ended.index('instance.stopNative()'))
        self.assertLess(ended.index('instance.stopNative()'), ended.index('notifyInvalidated('))
        self.assertIn('current?.id == instance.permitId', ended, 'late destroy is scoped to its permit')
        stop = self._body(source, 'private fun stop(reason:')
        self.assertLess(stop.index('invalidate(reason)'), stop.index('stopNative()'))
        self.assertLess(stop.index('stopNative()'), stop.index('notifyInvalidated('))
        invalidation = self._body(source, 'private fun invalidate')
        self.assertLess(invalidation.index('State.INVALIDATED'), invalidation.index('current = null'))
        self.assertIn('permit.nonces.clear()', invalidation)
        native = self._body(source, 'internal fun stopNative')
        self.assertIn('stopForeground(STOP_FOREGROUND_REMOVE)', native)
        self.assertIn('finally', native)
        self.assertIn('stopSelf()', native)
        main = self._body(bootstrap.MAIN_ACTIVITY, 'override fun onDestroy')
        self.assertLess(main.index('AgentRunsChannel.activityDestroyed(this)'), main.index('super.onDestroy()'))
        destroyed = self._body(source, 'fun activityDestroyed')
        self.assertLess(destroyed.index('stop("activity_destroyed")'), destroyed.index('channel = null'))

    def test_agent_ordering_request_release_and_cancel_before_start_are_generated(self):
        source = bootstrap.AGENT_RUN_SERVICE
        sequence = self._body(source, 'private fun sequence')
        self.assertIn('seq <= lastOpSeq', sequence)
        self.assertIn('"stale_operation"', sequence)
        self.assertLess(sequence.index('seq <= lastOpSeq'), sequence.index('lastOpSeq = seq'))
        self.assertIn('MAX_OP_SEQ = 9007199254740991L', source)
        self.assertIn('"opSeqFloor" to lastOpSeq', sequence, 'new engine can recover process sequence high-water')
        register = self._body(source, 'fun register(')
        self.assertIn('owner !== activity || registration !== binding', register)
        self.assertNotIn('lastOpSeq = 0', register, 'registration does not reset process ordering')
        start = self._body(source, 'private fun start(')
        self.assertLess(start.index('sequence(args, result)'), start.index('current = permit'))
        self.assertLess(start.index('visible !== activity'), start.index('current = permit'))
        self.assertIn('permit.latestStartSeq = seq', start)
        self.assertIn('active(result, permit, requestId, seq)', start)
        release = self._body(source, 'private fun release(')
        self.assertIn('byPermit == byRequest', release, 'exactly one release scope')
        self.assertLess(release.index('sequence(args, result)'), release.index('val permit = current'))
        cleanup_guard = 'if (cleanupFailed) { reject(result, "cleanup_failed"); return }'
        self.assertIn(cleanup_guard, release, 'unconfirmed cleanup must not be acknowledged as a no-op release')
        self.assertLess(release.index('sequence(args, result)'), release.index(cleanup_guard))
        self.assertLess(release.index(cleanup_guard), release.index('if (permit == null)'))
        self.assertIn('permit.createdRequestId == target && permit.latestStartSeq == permit.createdOpSeq', release)
        self.assertIn('(byPermit && permit.id != target) || (byRequest && !ownsRequest)', release)
        self.assertLess(release.index('!ownsRequest'), release.index('permit.state = State.RELEASED'))
        self.assertLess(release.index('State.RELEASED'), release.index('stopNative()'))
        self.assertIn('"didRelease" to false', release)
        self.assertIn('permit.nonces.clear()', release)
        self.assertNotIn('notifyInvalidated(', release)
        self.assertIn('cleanupFailed = true', source)
        self.assertIn('if (cleanupFailed) { reject(result, "cleanup_failed"); return }', start)

    def test_agent_tickets_are_bound_unique_and_saturation_never_evicts(self):
        source = bootstrap.AGENT_RUN_SERVICE
        self.assertIn('MAX_NONCES = 4096', source)
        self.assertIn('val nonces = HashSet<String>()', source)
        acquire = self._body(source, 'private fun acquire(')
        self.assertIn('kind !in setOf("model", "mutation")', acquire)
        self.assertIn('permit.id != permitId || permit.state != State.ACTIVE', acquire)
        self.assertIn('if (permit.nonces.size >= MAX_NONCES)', acquire)
        replay = acquire.index('nonce in permit.nonces')
        cap = acquire.index('permit.nonces.size >= MAX_NONCES')
        add = acquire.index('permit.nonces.add(nonce)')
        issued = acquire.index('result.success(reply("ticket"')
        self.assertLess(replay, cap)
        self.assertLess(cap, add)
        self.assertLess(add, issued)
        self.assertIn('reject(result, "nonce_capacity"); return', acquire)
        self.assertIn('reject(result, "nonce_replayed"); return', acquire)
        for field in ('"permitId" to permit.id', '"kind" to kind!!', '"nonce" to nonce',
                      '"ticketId" to UUID.randomUUID().toString()'):
            self.assertIn(field, acquire)
        self.assertEqual(acquire.count('result.success('), 1)
        self.assertEqual(source.count('permit.nonces.clear()'), 2, 'only released / invalidated free nonces')
        self.assertNotRegex(source, r'nonces\.(remove|removeAt|removeAll)\(')

    def test_agent_channel_preserves_fragment_activity_and_both_existing_channels(self):
        self.assertIn('class MainActivity : FlutterFragmentActivity()', bootstrap.MAIN_ACTIVITY)
        old = self._body(bootstrap.FRAGMENT_MAIN_ACTIVITY, 'override fun configureFlutterEngine')
        new = self._body(bootstrap.MAIN_ACTIVITY, 'override fun configureFlutterEngine')
        self.assertEqual(new.replace('        AgentRunsChannel.register(flutterEngine, this)\n', ''), old)
        self.assertIn('"io.gitlabmobile/agent_runs"', bootstrap.AGENT_RUN_SERVICE)
        for method in ('startRuns', 'updateProgress', 'releaseRuns', 'stopAll', 'acquireContinuation', 'moveTaskToBack'):
            self.assertIn(f'"{method}" ->', bootstrap.AGENT_RUN_SERVICE)
        self.assertIn('reply("unsupported", "reason" to "not_implemented")', bootstrap.AGENT_RUN_SERVICE)
        self.assertNotIn('activity.moveTaskToBack(', bootstrap.AGENT_RUN_SERVICE)

    def test_agent_notification_is_private_with_safe_public_resources_and_monochrome_icon(self):
        source = bootstrap.AGENT_RUN_SERVICE
        self.assertIn('NOTIFICATION_ID = 6100', source)
        self.assertIn('NOTIFICATION_CHANNEL = "ai_runs_v1"', source)
        notification = self._body(source, 'private fun notification(')
        self.assertIn('.setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(publicVersion)', notification)
        public = notification[notification.index('val publicVersion'):notification.index('return builder()')]
        self.assertNotIn('progress.', public)
        self.assertIn('R.string.ai_run_service_title', public)
        self.assertIn('R.string.ai_run_service_text', public)
        self.assertIn('progress.title ?: getString(R.string.ai_run_service_title)', notification)
        self.assertIn('progress.text ?: getString(R.string.ai_run_service_text)', notification)
        self.assertNotRegex(source, r'[\u3400-\u9fff]')
        self.assertNotRegex(notification, r'setContent(?:Title|Text)\("')
        self.assertNotIn('PendingIntent', notification, 'notification stop action belongs to C4')
        icon = ET.fromstring(bootstrap.AGENT_ICON)
        self.assertEqual(icon.tag, 'vector')
        self.assertEqual({node.get('{' + bootstrap.ANDROID + '}fillColor') for node in icon.findall('path')}, {'#FFFFFFFF'})

    @staticmethod
    def _resource_value(value):
        # Android quoted string syntax, independently decoded after XML parsing.
        assert value.startswith('"') and value.endswith('"')
        return re.sub(r'\\([\\\'"@?nrt])', lambda match: {'n': '\n', 'r': '\r', 't': '\t'}.get(
            match[1], match[1]), value[1:-1])

    def test_agent_resources_cover_all_languages_and_android_escaping_round_trips(self):
        app = self._managed_android()
        _, catalogs = bootstrap.l10n.load()
        paths = list((app / 'src/main/res').glob('values*/strings.xml'))
        self.assertEqual(len(paths), 24)
        self.assertTrue((app / 'src/main/res/values-zh-rTW/strings.xml').is_file())
        self.assertTrue((app / 'src/main/res/values-pt-rBR/strings.xml').is_file())
        for tag, _, _, language, _, country in bootstrap.l10n.LANGUAGES:
            qualifier = language + (f'-r{country}' if country else '')
            directory = 'values' if tag == 'en' else f'values-{qualifier}'
            resources = ET.parse(app / f'src/main/res/{directory}/strings.xml').getroot()
            self.assertEqual(len(resources), 3)
            for node in resources:
                self.assertEqual(node.get('formatted'), 'false')
                self.assertEqual(self._resource_value(node.text), catalogs[tag][bootstrap.AGENT_STRINGS[node.get('name')]])
        for original in ("It's a \"safe\" & <generic> \\ status", '@title', '?title', '  spaced  text\nnext\tline\r'):
            with self.subTest(original=original):
                modified = {tag: dict(messages) for tag, messages in catalogs.items()}
                modified['en']['aiRunServiceTitle'] = original
                with patch.object(bootstrap.l10n, 'load', return_value=([], modified)):
                    xml = bootstrap.agent_run_files()['src/main/res/values/strings.xml']
                value = ET.fromstring(xml).find('string[@name="ai_run_service_title"]').text
                self.assertEqual(self._resource_value(value), original)
                if '&' in original:
                    self.assertIn('&amp;', xml)
                    self.assertIn('&lt;', xml)
                if original[0] in '@?':
                    self.assertTrue(value.startswith('"\\' + original[0]))

    def test_agent_configure_is_byte_idempotent_and_upgrades_only_known_previous_activity(self):
        app = self._managed_android()
        before = {path.relative_to(app): path.read_bytes() for path in app.rglob('*') if path.is_file()}
        mtimes = {path: path.stat().st_mtime_ns for path in app.rglob('*') if path.is_file()}
        bootstrap.configure_android(self.root)
        after = {path.relative_to(app): path.read_bytes() for path in app.rglob('*') if path.is_file()}
        self.assertEqual(after, before)
        self.assertEqual({path: path.stat().st_mtime_ns for path in mtimes}, mtimes, 're-run writes nothing')
        # An exact previous managed template is accepted from the no-agent state.
        for name in bootstrap.agent_run_files():
            (app / name).unlink()
        manifest = app / 'src/main/AndroidManifest.xml'
        tree = ET.parse(manifest)
        root = tree.getroot()
        for node in list(root.findall('uses-permission')):
            if node.get('{' + bootstrap.ANDROID + '}name') != 'android.permission.INTERNET':
                root.remove(node)
        root.find('application').remove(root.find('application/service'))
        tree.write(manifest)
        activity = app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'MainActivity.kt'
        activity.write_text(bootstrap.FRAGMENT_MAIN_ACTIVITY)
        bootstrap.configure_android(self.root)
        self.assertEqual(activity.read_text(), bootstrap.MAIN_ACTIVITY)

    def test_every_agent_file_is_checked_before_any_write(self):
        app = self._managed_android()
        manifest = app / 'src/main/AndroidManifest.xml'
        gradle = app / 'build.gradle.kts'
        for name in bootstrap.agent_run_files():
            path = app / name
            original = path.read_bytes()
            with self.subTest(name=name):
                path.write_text('unknown / half managed content\n')
                before = (manifest.read_bytes(), gradle.read_bytes())
                with self.assertRaisesRegex(RuntimeError, 'Unknown managed Android content'):
                    bootstrap.configure_android(self.root)
                self.assertEqual((manifest.read_bytes(), gradle.read_bytes()), before)
                self.assertEqual(path.read_text(), 'unknown / half managed content\n')
            path.write_bytes(original)

    def test_agent_refuses_partial_conflicting_permissions_services_and_activities(self):
        app = self._managed_android()
        manifest = app / 'src/main/AndroidManifest.xml'
        original = manifest.read_text()
        for changed in (
            original.replace('android.permission.POST_NOTIFICATIONS', 'android.permission.RECEIVE_BOOT_COMPLETED'),
            original.replace('android:foregroundServiceType="dataSync"', 'android:foregroundServiceType="location"'),
            original.replace('android:stopWithTask="true"', 'android:stopWithTask="false"'),
            original.replace('<service ', '<service android:permission="foreign.permission" '),
            original.replace('</manifest>', '<uses-permission android:name="android.permission.INTERNET" /></manifest>'),
            original.replace('</manifest>', '<uses-permission android:name="android.permission.POST_NOTIFICATIONS" android:maxSdkVersion="32" /></manifest>'),
            original.replace('android:noHistory="true"', 'android:noHistory="false"'),
            original.replace('</application>', '<service android:name=".ForeignService" /></application>'),
            original.replace('android:name=".MainActivity" android:exported="true"',
                             'android:name=".MainActivity" android:exported="false"'),
            original.replace('android:host="oauth"', 'android:host="foreign"'),
            original.replace('android:name="flutter_deeplinking_enabled" android:value="false"',
                             'android:name="flutter_deeplinking_enabled" android:value="true"'),
        ):
            with self.subTest(manifest=changed[-100:]):
                manifest.write_text(changed)
                with self.assertRaises(RuntimeError):
                    bootstrap.configure_android(self.root)
                self.assertEqual(manifest.read_text(), changed)
        manifest.write_text(original)
        service = app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'AgentRunService.kt'
        content = service.read_bytes()
        service.unlink()
        with self.assertRaisesRegex(RuntimeError, 'Incomplete managed agent service'):
            bootstrap.configure_android(self.root)
        service.write_bytes(content)
        for name in (bootstrap.UPDATE_DEPENDENCIES_BEGIN, bootstrap.UPDATE_DEPENDENCIES_END):
            gradle = app / 'build.gradle.kts'
            original_gradle = gradle.read_text()
            gradle.write_text(original_gradle.replace(name, ''))
            with self.assertRaisesRegex(RuntimeError, 'Incomplete managed update dependency markers'):
                bootstrap.configure_android(self.root)
            gradle.write_text(original_gradle)
        activity = app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'MainActivity.kt'
        activity.write_text(bootstrap.MAIN_ACTIVITY.replace('AgentRunsChannel.register', 'ForeignChannel.register'))
        with self.assertRaisesRegex(RuntimeError, 'Unknown MainActivity template'):
            bootstrap.configure_android(self.root)
        activity.write_text(bootstrap.FRAGMENT_MAIN_ACTIVITY)
        with self.assertRaisesRegex(RuntimeError, 'Incomplete managed agent activity'):
            bootstrap.configure_android(self.root)

    def test_partial_update_files_and_foreign_flavor_manifests_are_refused_before_writes(self):
        app = self._managed_android()
        files = bootstrap._check_update_template(app)
        before = {path: path.read_bytes() for path in app.rglob('*') if path.is_file()}
        for name in files:
            path = app / name
            original = path.read_bytes()
            path.unlink()
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, 'Incomplete managed update/link'):
                bootstrap.configure_android(self.root)
            path.write_bytes(original)
        for content in (
            '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />',
            '<application><service android:name=".AgentRunService" android:exported="true" /></application>',
        ):
            path = app / 'src/play/AndroidManifest.xml'
            path.write_text(f'<manifest xmlns:android="{bootstrap.ANDROID}">{content}</manifest>')
            with self.assertRaisesRegex(RuntimeError, 'Unknown Android source-set manifest'):
                bootstrap.configure_android(self.root)
            path.unlink()
        self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_invalid_signing_or_flavor_blocks_are_refused_before_any_write(self):
        app = self._app()
        (app / 'src/main/AndroidManifest.xml').write_text(self.FRESH_MANIFEST)
        gradle = app / 'build.gradle.kts'
        original = gradle.read_text()
        for changed in (
            original.replace(android_signing.END_CONFIG, ''),
            original.replace(android_signing.BEGIN_CONFIG, android_signing.BEGIN_CONFIG + '\n    // drift'),
            original.replace(bootstrap.FLAVORS_END, ''),
            original.replace('create("play")', 'create("foreign")'),
        ):
            with self.subTest(gradle=changed):
                gradle.write_text(changed)
                before = {path.relative_to(app): path.read_bytes() for path in app.rglob('*') if path.is_file()}
                with self.assertRaises(RuntimeError):
                    bootstrap.configure_android(self.root)
                self.assertEqual({path.relative_to(app): path.read_bytes()
                                  for path in app.rglob('*') if path.is_file()}, before)
        gradle.write_text(original)

    def test_fresh_activity_with_partial_update_block_is_refused_before_writes(self):
        app = self._app()
        (app / 'src/main/AndroidManifest.xml').write_text(self.FRESH_MANIFEST)
        gradle = app / 'build.gradle.kts'
        gradle.write_text(gradle.read_text() + '\n' + bootstrap.UPDATE_DEPENDENCIES)
        before = {path: path.read_bytes() for path in app.rglob('*') if path.is_file()}
        with self.assertRaisesRegex(RuntimeError, 'Incomplete managed update'):
            bootstrap.configure_android(self.root)
        self.assertEqual({path: path.read_bytes() for path in app.rglob('*') if path.is_file()}, before)

    def test_cli_still_refuses_existing_native_directory(self):
        (self.root / 'android').mkdir()
        sentinel = self.root / 'android/sentinel'
        sentinel.write_text('owned')
        with patch.object(bootstrap, 'ROOT', self.root), patch.object(bootstrap, 'check_sdk'), \
                patch.object(bootstrap.shutil, 'which', return_value='/pinned/flutter'), \
                patch.object(sys, 'argv', ['bootstrap.py']):
            with self.assertRaises(SystemExit) as error:
                bootstrap.main()
        self.assertEqual(error.exception.code, 1)
        self.assertEqual(sentinel.read_text(), 'owned')

    def test_offline_icons_still_enforce_lockfile_and_use_pinned_dart(self):
        with patch.object(bootstrap.subprocess, 'run') as run:
            bootstrap.apply_launcher_icons('/pinned/bin/flutter', offline=True)
        self.assertEqual(run.call_args_list[0].args[0],
                         ['/pinned/bin/flutter', 'pub', 'get', '--enforce-lockfile', '--offline'])
        self.assertEqual(run.call_args_list[1].args[0], ['/pinned/bin/dart', 'run', 'flutter_launcher_icons'])

    def _merged_fixture(self, flavor):
        app = self.root / 'app'
        path = self.root / f'build/app/intermediates/merged_manifests/{flavor}Debug/processManifest/AndroidManifest.xml'
        path.parent.mkdir(parents=True, exist_ok=True)
        tree = ET.parse(app / 'src/main/AndroidManifest.xml')
        root = tree.getroot()
        a = '{' + bootstrap.ANDROID + '}'
        package = 'app.mergeline' if flavor == 'play' else 'io.gitlabmobile.gitlab_mobile'
        root.set('package', package)
        for node in root.findall('application/activity') + root.findall('application/service'):
            if node.get(a + 'name', '').startswith('.'):
                node.set(a + 'name', 'io.gitlabmobile.gitlab_mobile' + node.get(a + 'name'))
        ET.SubElement(root, 'uses-sdk', {a + 'minSdkVersion': '24', a + 'targetSdkVersion': '36'})
        existing = {node.get(a + 'name') for node in root.findall('uses-permission')}
        permissions = MERGED_COMMON_PERMISSIONS | {package + '.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'}
        if flavor == 'gitlab':
            permissions |= {'android.permission.REQUEST_INSTALL_PACKAGES'}
        for permission in sorted(permissions - existing):
            ET.SubElement(root, 'uses-permission', {a + 'name': permission})
        plugin = ET.SubElement(root.find('application'), 'service', {
            a + 'name': 'com.google.android.gms.metadata.ModuleDependencies',
            a + 'enabled': 'false', a + 'exported': 'false'})
        intent = ET.SubElement(plugin, 'intent-filter')
        ET.SubElement(intent, 'action', {a + 'name': 'com.google.android.gms.metadata.MODULE_DEPENDENCIES'})
        ET.SubElement(plugin, 'meta-data', {a + 'name': 'photopicker_activity:0:required', a + 'value': ''})
        tree.write(path)
        return path

    def test_merged_helper_requires_actual_both_flavors_and_rejects_privilege_drift(self):
        self._managed_android()
        with self.assertRaisesRegex(AssertionError, 'No actual gitlabDebug merged manifest'):
            verify_generated_root(self.root)
        gitlab = self._merged_fixture('gitlab')
        with self.assertRaisesRegex(AssertionError, 'No actual playDebug merged manifest'):
            verify_generated_root(self.root)
        play = self._merged_fixture('play')
        self.assertEqual(set(verify_generated_root(self.root)), {'gitlab', 'play'})
        original = play.read_text()
        for mutated in (
            original.replace('</manifest>', '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" /></manifest>'),
            original.replace('</manifest>', '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" /></manifest>'),
            original.replace('android:stopWithTask="true"', 'android:stopWithTask="false"'),
            original.replace('android:foregroundServiceType="dataSync"', 'android:foregroundServiceType="location"'),
            original.replace('android:allowBackup="false"', 'android:allowBackup="true"'),
            original.replace('android:usesCleartextTraffic="false"', 'android:usesCleartextTraffic="true"'),
            original.replace('android:host="gitlab.com"', 'android:host="foreign.example"'),
            original.replace('android:host="oauth"', 'android:host="foreign"'),
            original.replace('io.gitlabmobile.gitlab_mobile.AgentRunService', '.AgentRunService'),
            original.replace('android:foregroundServiceType="dataSync"',
                             'android:foregroundServiceType="dataSync" android:enabled="false"'),
            original.replace('android:foregroundServiceType="dataSync"',
                             'android:foregroundServiceType="dataSync" android:permission="foreign.permission"'),
            original.replace('android:foregroundServiceType="dataSync"',
                             'android:foregroundServiceType="dataSync" android:process=":foreign"'),
            original.replace('io.gitlabmobile.gitlab_mobile.MainActivity', 'foreign.MainActivity'),
            original.replace('io.gitlabmobile.gitlab_mobile.LinkActivity', 'foreign.LinkActivity'),
            original.replace('</application>', '<activity android:name="foreign.MainActivity" /></application>'),
        ):
            play.write_text(mutated)
            with self.assertRaises(AssertionError):
                verify_merged_manifest(play, 'play')
        play.write_text(original)
        gitlab.unlink()
        with self.assertRaisesRegex(AssertionError, 'No actual gitlabDebug merged manifest'):
            verify_generated_root(self.root)

    @unittest.skipUnless(os.environ.get('MR6C_GENERATED_ROOT'), 'GN: MR6C_GENERATED_ROOT not set')
    def test_actual_generated_merged_manifests(self):
        root = os.environ['MR6C_GENERATED_ROOT']
        manifests = verify_generated_root(root)
        apks = verify_generated_apks(root)
        for flavor, paths in manifests.items():
            for path in paths:
                print(f'MR6C merged manifest verified: {flavor}: {path}', flush=True)
            print(f'MR6C packaged compileSdk 36 verified: {flavor}: {apks[flavor]}', flush=True)

    def test_apk_helper_requires_both_real_outputs_and_checks_packaged_sdk_and_identity(self):
        sdk = self.root / 'sdk'
        tool = sdk / 'build-tools/36.0.0' / ('aapt2.exe' if os.name == 'nt' else 'aapt2')
        tool.parent.mkdir(parents=True)
        tool.touch()
        with patch.dict(os.environ, {'ANDROID_HOME': str(sdk)}):
            with self.assertRaisesRegex(AssertionError, 'Missing actual gitlabDebug APK'):
                verify_generated_apks(self.root)
            apks = self.root / 'build/app/outputs/flutter-apk'
            apks.mkdir(parents=True)
            (apks / 'app-gitlab-debug.apk').touch()
            def badging(command, **kwargs):
                package = 'app.mergeline' if 'app-play-debug.apk' in command[-1] else 'io.gitlabmobile.gitlab_mobile'
                return subprocess.CompletedProcess(command, 0, stdout=f"package: name='{package}' compileSdkVersion='36'\n")
            with patch.object(subprocess, 'run', side_effect=badging):
                with self.assertRaisesRegex(AssertionError, 'Missing actual playDebug APK'):
                    verify_generated_apks(self.root)
                (apks / 'app-play-debug.apk').touch()
                self.assertEqual(set(verify_generated_apks(self.root)), {'gitlab', 'play'})
            for header in (
                "package: name='io.gitlabmobile.gitlab_mobile' compileSdkVersion='35'",
                "package: name='io.gitlabmobile.gitlab_mobile'",
                "package: name='foreign.package' compileSdkVersion='36'",
            ):
                with self.subTest(header=header), patch.object(subprocess, 'run', return_value=
                        subprocess.CompletedProcess([], 0, stdout=header)):
                    with self.assertRaises(AssertionError):
                        verify_generated_apks(self.root)


if __name__ == '__main__':
    unittest.main()
