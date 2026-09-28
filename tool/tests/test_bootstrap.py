from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstrap


class BootstrapTests(unittest.TestCase):
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
        self.assertEqual(app.get(attribute + 'label'), 'GitLab Mobile')
        self.assertEqual(app.get(attribute + 'allowBackup'), 'false')
        self.assertEqual(app.get(attribute + 'usesCleartextTraffic'), 'false')
        self.assertEqual(manifest.find('uses-permission').get(attribute + 'name'), 'android.permission.INTERNET')
        backup = ET.parse(source / 'res/xml/data_extraction_rules.xml').getroot()
        self.assertEqual(len(backup.find('device-transfer').findall('exclude')), 5)

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
        self.assertIn('<key>CFBundleDisplayName</key>\n\t\t<string>GitLab Mobile</string>', text)
        self.assertIn('<key>CFBundleName</key>\n\t\t<string>GitLab Mobile</string>', text)
        self.assertNotIn('gitlab_mobile', text)

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
        other = {item.get('name'): item.text
                 for item in ET.parse(styles).getroot().find('style[@name="Other"]').findall('item')}
        self.assertEqual(other.get('android:statusBarColor'), '#FF112233')

    def test_android_patch_is_idempotent(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest><application/></manifest>')
        bootstrap.harden_android(self.root)
        bootstrap.harden_android(self.root)
        self.assertEqual(len(ET.parse(source / 'AndroidManifest.xml').getroot().findall('uses-permission')), 1)

    def test_unknown_android_template_fails(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest/>')
        with self.assertRaises(RuntimeError):
            bootstrap.harden_android(self.root)

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


if __name__ == '__main__':
    unittest.main()
