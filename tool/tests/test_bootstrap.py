from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstrap
import android_signing


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
        self.assertEqual(len(ET.parse(source / 'AndroidManifest.xml').getroot().findall('uses-permission')), 1)

    def test_unknown_android_template_fails(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest/>')
        with self.assertRaises(RuntimeError):
            bootstrap.harden_android(self.root)

    def test_configure_android_embeds_stable_signing_loader(self):
        source = self.root / 'app/src/main'
        source.mkdir(parents=True)
        (source / 'AndroidManifest.xml').write_text('<manifest><application/></manifest>')
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
            activity.write_text(earlier)
            bootstrap.configure_update_channels(app)
            self.assertEqual(activity.read_text(), bootstrap.MAIN_ACTIVITY, 'an earlier managed activity is upgraded')
        activity.write_text(bootstrap.TEMPLATE_MAIN_ACTIVITY)
        bootstrap.configure_update_channels(app)
        gradle = app / 'build.gradle.kts'
        gradle.write_text(gradle.read_text().replace('app-update:2.1.0', 'app-update:1.0.0'))
        with self.assertRaisesRegex(RuntimeError, 'Stale managed update dependencies'):
            bootstrap.configure_update_channels(app)


if __name__ == '__main__':
    unittest.main()
