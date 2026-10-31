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
    'android.permission.USE_FINGERPRINT', 'android.permission.POST_NOTIFICATIONS',
    'android.permission.VIBRATE',
    'com.google.android.apps.aicore.service.BIND_SERVICE',
}
MERGED_GITLAB_PERMISSIONS = {
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
    'android.permission.REQUEST_INSTALL_PACKAGES',
}


def _require(condition, message='Generated Android verification failed'):
    # A normal assertion is removed by Python -O, but this check is a gate.
    if not condition:
        raise AssertionError(message)


def verify_merged_manifest(path, flavor):
    root = ET.parse(path).getroot()
    a = '{http://schemas.android.com/apk/res/android}'
    package = {'gitlab': 'io.gitlabmobile.gitlab_mobile', 'play': 'app.mergeline'}[flavor]
    _require(root.get('package') == package, f'{path}: wrong application ID')
    permissions = [node.get(a + 'name') for node in root.findall('uses-permission')]
    expected = MERGED_COMMON_PERMISSIONS | {package + '.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'}
    if flavor == 'gitlab':
        expected |= MERGED_GITLAB_PERMISSIONS
    _require(len(permissions) == len(set(permissions)), f'{path}: duplicate permissions')
    _require(set(permissions) == expected, f'{path}: permission difference {set(permissions) ^ expected}')
    _require(not root.findall('uses-permission-sdk-23'), f'{path}: unexpected conditional permissions')
    for node in root.findall('uses-permission'):
        _require(node.attrib == {a + 'name': node.get(a + 'name')}, f'{path}: conditional permission')
    app = root.find('application')
    _require(app is not None, f'{path}: missing application')
    for component in app:
        _require('agentrunqa' not in component.get(a + 'name', '').lower(),
                 f'{path}: QA adapter must not be an Android component')
    for name, value in {
        'allowBackup': 'false', 'usesCleartextTraffic': 'false',
        'fullBackupContent': '@xml/backup_rules', 'dataExtractionRules': '@xml/data_extraction_rules',
        'enableOnBackInvokedCallback': 'true',
    }.items():
        _require(app.get(a + name) == value, f'{path}: {name}')
    services = app.findall('service')
    namespace = 'io.gitlabmobile.gitlab_mobile'
    agents = [node for node in services if node.get(a + 'name', '').split('.')[-1] == 'AgentRunService']
    if flavor == 'gitlab':
        _require(len(agents) == 1, f'{path}: AgentRunService must be unique')
        service = agents[0]
        _require(service.attrib == {a + name: value for name, value in {
            'name': namespace + '.AgentRunService', 'exported': 'false',
            'stopWithTask': 'true', 'foregroundServiceType': 'dataSync',
        }.items()}, f'{path}: service attributes')
        _require(not list(service), f'{path}: unexpected service children')
    else:
        _require(not agents, f'{path}: play must not declare AgentRunService')
    # Non-agent services contributed by image_picker_android and mlkit:genai-prompt transitive AARs.
    plugin_services = {node.get(a + 'name'): node for node in services if node not in agents}
    _require(len(plugin_services) == len(services) - len(agents), f'{path}: duplicate plugin services')
    expected_plugin_services = {
        'com.google.android.gms.metadata.ModuleDependencies',
        'com.google.mlkit.common.internal.MlKitComponentDiscoveryService',
        'com.google.android.datatransport.runtime.backends.TransportBackendDiscovery',
        'com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService',
    }
    _require(set(plugin_services) == expected_plugin_services,
             f'{path}: unexpected plugin services {set(plugin_services) ^ expected_plugin_services}')
    plugin = plugin_services['com.google.android.gms.metadata.ModuleDependencies']
    _require(plugin.get(a + 'enabled') == 'false' and plugin.get(a + 'exported') == 'false', f'{path}: plugin service flags')
    _require([node.get(a + 'name') for node in plugin.findall('intent-filter/action')] == [
        'com.google.android.gms.metadata.MODULE_DEPENDENCIES'], f'{path}: plugin service action')
    _require([(node.get(a + 'name'), node.get(a + 'value')) for node in plugin.findall('meta-data')] == [
        ('photopicker_activity:0:required', '')], f'{path}: plugin service metadata')
    mlkit_service = plugin_services['com.google.mlkit.common.internal.MlKitComponentDiscoveryService']
    _require(mlkit_service.attrib == {
        a + 'name': 'com.google.mlkit.common.internal.MlKitComponentDiscoveryService',
        a + 'directBootAware': 'true',
        a + 'exported': 'false',
    }, f'{path}: MlKitComponentDiscoveryService attributes')
    _require(not mlkit_service.findall('intent-filter'), f'{path}: MlKitComponentDiscoveryService intent-filter')
    _require([(node.get(a + 'name'), node.get(a + 'value')) for node in mlkit_service.findall('meta-data')] == [(
        'com.google.firebase.components:com.google.mlkit.common.internal.CommonComponentRegistrar',
        'com.google.firebase.components.ComponentRegistrar',
    )], f'{path}: MlKitComponentDiscoveryService metadata')
    transport_discovery = plugin_services['com.google.android.datatransport.runtime.backends.TransportBackendDiscovery']
    _require(transport_discovery.attrib == {
        a + 'name': 'com.google.android.datatransport.runtime.backends.TransportBackendDiscovery',
        a + 'exported': 'false',
    }, f'{path}: TransportBackendDiscovery attributes')
    _require(not transport_discovery.findall('intent-filter'), f'{path}: TransportBackendDiscovery intent-filter')
    _require([(node.get(a + 'name'), node.get(a + 'value')) for node in transport_discovery.findall('meta-data')] == [
        ('backend:com.google.android.datatransport.cct.CctBackendFactory', 'cct'),
    ], f'{path}: TransportBackendDiscovery metadata')
    scheduler = plugin_services['com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService']
    _require(scheduler.attrib == {
        a + 'name': 'com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService',
        a + 'exported': 'false',
        a + 'permission': 'android.permission.BIND_JOB_SERVICE',
    }, f'{path}: JobInfoSchedulerService attributes')
    _require(not list(scheduler), f'{path}: JobInfoSchedulerService children')
    for action in app.findall('.//receiver/intent-filter/action'):
        _require(action.get(a + 'name') not in {
            'android.intent.action.BOOT_COMPLETED', 'android.intent.action.LOCKED_BOOT_COMPLETED',
        }, f'{path}: boot receiver')
    for receiver in app.findall('receiver'):
        _require(not receiver.get(a + 'name', '').startswith(
            'com.dexterous.flutterlocalnotifications.'), f'{path}: unexpected notification receiver')
    for provider in app.findall('.//provider'):
        _require(provider.get(a + 'name') != 'com.google.mlkit.common.internal.MlKitInitProvider' and
                 'mlkitinitprovider' not in provider.get(a + 'name', '').lower() and
                 'mlkitinitprovider' not in provider.get(a + 'authorities', '').lower(),
                 f'{path}: MlKitInitProvider must not be present in merged manifest')
    def activity(name):
        matches = [node for node in app.findall('activity') if node.get(a + 'name', '').split('.')[-1] == name]
        _require(len(matches) == 1, f'{path}: {name} must be unique')
        _require(matches[0].get(a + 'name') == namespace + '.' + name, f'{path}: {name} class')
        return matches[0]
    main = activity('MainActivity')
    _require(main.get(a + 'exported') == 'true', f'{path}: launcher export')
    _require(main.get(a + 'launchMode') == 'singleTop', f'{path}: launcher mode')
    _require([node.get(a + 'value') for node in main.findall('meta-data')
            if node.get(a + 'name') == 'flutter_deeplinking_enabled'] == ['false'], f'{path}: Flutter deep linking')
    launcher = [node for node in main.findall('intent-filter')
                if any(action.get(a + 'name') == 'android.intent.action.MAIN' for action in node.findall('action'))]
    _require(len(launcher) == 1, f'{path}: launcher intent')
    _require([node.get(a + 'name') for node in launcher[0].findall('category')] == ['android.intent.category.LAUNCHER'], f'{path}: launcher category')
    link = activity('LinkActivity')
    for name, value in {'exported': 'true', 'noHistory': 'true', 'taskAffinity': '', 'excludeFromRecents': 'true'}.items():
        _require(link.get(a + name) == value, f'{path}: link {name}')
    _require(len(link.findall('intent-filter')) == 2, f'{path}: link intent filters')
    view, share = link.findall('intent-filter')
    _require([node.get(a + 'name') for node in view.findall('action')] == ['android.intent.action.VIEW'], f'{path}: link action')
    _require({node.get(a + 'name') for node in view.findall('category')} == {
        'android.intent.category.DEFAULT', 'android.intent.category.BROWSABLE'}, f'{path}: link categories')
    _require([node.attrib for node in view.findall('data')] == [
        {a + 'scheme': 'https'}, {a + 'host': 'gitlab.com'}], f'{path}: link data')
    _require([node.get(a + 'name') for node in share.findall('action')] == ['android.intent.action.SEND'], f'{path}: share action')
    _require([node.get(a + 'name') for node in share.findall('category')] == ['android.intent.category.DEFAULT'], f'{path}: share category')
    _require([node.attrib for node in share.findall('data')] == [{a + 'mimeType': 'text/plain'}], f'{path}: share data')
    _require(len(main.findall('intent-filter')) == 2, f'{path}: launcher / OAuth filters')
    oauth = [node for node in main.findall('intent-filter')
             if any(action.get(a + 'name') == 'android.intent.action.VIEW' for action in node.findall('action'))]
    _require(len(oauth) == 1, f'{path}: OAuth filter')
    _require([node.attrib for node in oauth[0].findall('data')] == [{
        a + 'scheme': 'io.gitlabmobile.app', a + 'host': 'oauth', a + 'pathPrefix': '/callback'}], f'{path}: OAuth data')
    _require({node.get(a + 'name') for node in oauth[0].findall('category')} == {
        'android.intent.category.DEFAULT', 'android.intent.category.BROWSABLE'}, f'{path}: OAuth categories')
    sdk = root.find('uses-sdk')
    _require(sdk is not None and sdk.get(a + 'minSdkVersion') == '24', f'{path}: min SDK')
    _require(sdk.get(a + 'targetSdkVersion') == '36', f'{path}: target SDK')


def verify_generated_root(root):
    root = Path(root)
    intermediates = root / 'build/app/intermediates'
    manifests = {}
    for flavor in ('gitlab', 'play'):
        candidates = [path for directory in intermediates.glob('merged_manifest*')
                      for path in directory.rglob('AndroidManifest.xml')
                      if flavor + 'debug' in str(path.relative_to(directory)).lower()]
        _require(candidates, f'No actual {flavor}Debug merged manifest under {intermediates}')
        for path in candidates:
            verify_merged_manifest(path, flavor)
        manifests[flavor] = candidates
    return manifests


def _property_value(path, name):
    """Read a Java properties value, including escaped separators and continuations."""
    if not path.is_file():
        return None
    logical = []
    pending = ''
    for physical in path.read_text(encoding='iso-8859-1').splitlines():
        line = pending + (physical.lstrip(' \t\f') if pending else physical)
        slash_count = len(line) - len(line.rstrip('\\'))
        if slash_count % 2:
            pending = line[:-1]
            continue
        pending = ''
        logical.append(line)
    if pending:
        logical.append(pending)

    def decode(value):
        def unescape(match):
            escape = match.group(1)
            if escape.startswith('u'):
                return chr(int(escape[1:], 16))
            return {'t': '\t', 'r': '\r', 'n': '\n', 'f': '\f'}.get(escape, escape)
        return re.sub(r'\\(u[0-9a-fA-F]{4}|.)', unescape, value)

    result = None
    for line in logical:
        line = line.lstrip(' \t\f')
        if not line or line[0] in '#!':
            continue
        match = re.match(r'((?:\\.|[^\\=:\s])*)(?:\s*[=:]\s*|\s+)?(.*)', line)
        if match and decode(match.group(1)) == name:
            result = decode(match.group(2))
    return result


def _android_sdk(root):
    sdk = (os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or
           _property_value(Path(root) / 'android/local.properties', 'sdk.dir'))
    _require(sdk, 'ANDROID_HOME, ANDROID_SDK_ROOT or android/local.properties sdk.dir is required')
    return Path(sdk)


def verify_android_build_config(root):
    """Check the generated Java compilation targets and pinned Android Gradle plugin."""
    android = Path(root) / 'android'
    settings = android / 'settings.gradle.kts'
    app = android / 'app/build.gradle.kts'
    _require(settings.is_file() and app.is_file(), 'Missing generated Android Gradle configuration')
    settings_text = settings.read_text()
    versions = re.findall(r'^\s*id\("com\.android\.application"\)\s+version\s+"([^"]+)"\s+apply\s+false\s*$',
                          settings_text, re.MULTILINE)
    _require(versions == ['9.1.0'], f'{settings}: Android Gradle plugin must be 9.1.0')
    app_text = app.read_text()
    blocks = re.findall(r'\bcompileOptions\s*\{([^{}]*)\}', app_text)
    _require(len(blocks) == 1, f'{app}: expected one Java compileOptions block')
    for key in ('sourceCompatibility', 'targetCompatibility'):
        values = re.findall(r'^\s*' + key + r'\s*=\s*([^\s]+)\s*$', blocks[0], re.MULTILINE)
        _require(values == ['JavaVersion.VERSION_17'], f'{app}: {key} must be Java 17')
    _require(bootstrap._KOTLIN_COMPILER_BLOCK in app_text and 'kotlinOptions' not in app_text,
             f'{app}: Kotlin compiler target must be JVM 17 using AGP 9 DSL')
    for value in ('compileSdk = flutter.compileSdkVersion', 'minSdk = flutter.minSdkVersion',
                  'targetSdk = flutter.targetSdkVersion'):
        _require(app_text.count(value) == 1, f'{app}: expected Flutter SDK setting {value}')
    _require(blocks[0].count('isCoreLibraryDesugaringEnabled = true') == 1,
             f'{app}: desugaring must be enabled')
    _require(app_text.count('coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")') == 1,
             f'{app}: expected desugar_jdk_libs 2.1.4')


def verify_generated_apks(root):
    """compileSdk is written by AAPT into the APK, not Gradle's text manifests."""
    sdk = _android_sdk(root)
    executable = 'aapt2.exe' if os.name == 'nt' else 'aapt2'
    tools = sorted((sdk / 'build-tools').glob('*/' + executable))
    _require(tools, f'No installed {executable} under {sdk}')
    analyzer_name = 'apkanalyzer.bat' if os.name == 'nt' else 'apkanalyzer'
    analyzers = sorted((sdk / 'cmdline-tools').glob('*/bin/' + analyzer_name))
    _require(analyzers, f'No installed {analyzer_name} under {sdk}')
    apks = {}
    for flavor, package in (('gitlab', 'io.gitlabmobile.gitlab_mobile'), ('play', 'app.mergeline')):
        apk = Path(root) / f'build/app/outputs/flutter-apk/app-{flavor}-debug.apk'
        _require(apk.is_file(), f'Missing actual {flavor}Debug APK: {apk}')
        result = subprocess.run([str(tools[-1]), 'dump', 'badging', str(apk)],
                                capture_output=True, text=True, check=True, timeout=120)
        header = next((line for line in result.stdout.splitlines() if line.startswith('package: ')), '')
        attributes = dict(re.findall(r"(\w+)='([^']*)'", header))
        _require(attributes.get('name') == package, f'{apk}: packaged application ID')
        _require(attributes.get('compileSdkVersion') == '36', f'{apk}: packaged compile SDK')
        for method in ('onTimeout(II)V', 'onDestroy()V'):
            command = [str(analyzers[-1]), 'dex', 'code', '--class',
                       'io.gitlabmobile.gitlab_mobile.AgentRunService', '--method', method, str(apk)]
            result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=120)
            _require(re.search(r'^\.method\s+[^\n]*\b' + re.escape(method) + r'\s*$', result.stdout, re.MULTILINE)
                     and '.registers ' in result.stdout and '.end method' in result.stdout,
                     f'{apk}: missing compiled AgentRunService.{method}')
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
        gradle.write_text(self.GRADLE)
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
        (self.root / 'Runner/AppDelegate.swift').write_text(bootstrap.IOS_APP_DELEGATE_TEMPLATE)
        path = self.root / 'Runner.xcodeproj/project.pbxproj'
        path.write_text(('buildSettings = {\nINFOPLIST_FILE = Runner/Info.plist;\n};\n') * count)
        return path

    def test_ios_patches_three_runner_configs_and_creates_entitlements(self):
        path = self.prepare_ios(3)
        bootstrap.configure_ios(self.root)
        self.assertEqual(path.read_text().count('CODE_SIGN_ENTITLEMENTS'), 3)
        self.assertTrue((self.root / 'Runner/Runner.entitlements').is_file())

    def test_ios_generated_delegate_registers_backup_exclusion(self):
        self.prepare_ios(3)
        bootstrap.configure_ios(self.root)
        delegate = (self.root / 'Runner/AppDelegate.swift').read_text()
        self.assertIn('name: "mergeline/backup"', delegate)
        self.assertIn('engineBridge.applicationRegistrar.messenger()', delegate)
        self.assertIn('call.method == "excludeFromBackup"', delegate)
        self.assertIn('arguments["path"] as? String', delegate)
        self.assertIn('values.isExcludedFromBackup = true', delegate)
        self.assertIn('try url.setResourceValues(values)', delegate)
        self.assertIn('FlutterError(code: "backupExclusionFailed"', delegate)
        _, repeated = bootstrap.ios_backup_app_delegate(self.root)
        self.assertEqual(delegate, repeated)

    def test_ios_delegate_drift_fails_before_project_mutation(self):
        project = self.prepare_ios(3)
        delegate = self.root / 'Runner/AppDelegate.swift'
        delegate.write_text(delegate.read_text() + '// changed\n')
        original = project.read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'AppDelegate'):
            bootstrap.configure_ios(self.root)
        self.assertEqual(project.read_bytes(), original)

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
        '    compileSdk = flutter.compileSdkVersion\n'
        '    compileOptions {\n        sourceCompatibility = JavaVersion.VERSION_17\n'
        '        targetCompatibility = JavaVersion.VERSION_17\n    }\n'
        '    defaultConfig {\n        minSdk = flutter.minSdkVersion\n'
        '        targetSdk = flutter.targetSdkVersion\n    }\n'
        '    buildTypes {\n        release {\n'
        '            signingConfig = signingConfigs.getByName("debug")\n        }\n    }\n}\n'
        '\nkotlin {\n    compilerOptions {\n'
        '        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17\n    }\n}\n'
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

    def test_notification_gradle_uses_pinned_template_and_is_idempotent(self):
        gradle = self.root / 'build.gradle.kts'
        gradle.write_text(self.GRADLE)
        self.assertTrue(bootstrap.configure_notification_gradle(gradle))
        configured = gradle.read_text()
        self.assertEqual(configured.count('isCoreLibraryDesugaringEnabled = true'), 1)
        self.assertEqual(configured.count('coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'), 1)
        self.assertIn(bootstrap._KOTLIN_COMPILER_BLOCK, configured)
        self.assertNotIn('kotlinOptions', configured)
        self.assertNotIn('multiDex', configured)
        self.assertFalse(bootstrap.configure_notification_gradle(gradle))
        self.assertEqual(gradle.read_text(), configured)

    def test_notification_gradle_rejects_stale_partial_or_foreign_before_writing(self):
        gradle = self.root / 'build.gradle.kts'
        gradle.write_text(self.GRADLE)
        bootstrap.configure_notification_gradle(gradle)
        managed = gradle.read_text()
        for changed in (
            managed.replace(bootstrap.NOTIFICATION_DESUGAR_END, ''),
            managed.replace(bootstrap.NOTIFICATION_DEPENDENCIES_END, ''),
            managed.replace('desugar_jdk_libs:2.1.4', 'desugar_jdk_libs:2.0.0'),
            managed.replace('isCoreLibraryDesugaringEnabled = true', 'isCoreLibraryDesugaringEnabled = false'),
            managed.replace('JavaVersion.VERSION_17', 'JavaVersion.VERSION_11', 1),
            managed.replace('JvmTarget.JVM_17', 'JvmTarget.JVM_11'),
            managed.replace('compileSdk = flutter.compileSdkVersion', 'compileSdk = 35'),
            self.GRADLE.replace('    compileOptions {',
                                '    compileOptions {\n        isCoreLibraryDesugaringEnabled = true'),
        ):
            with self.subTest(changed=changed):
                gradle.write_text(changed)
                with self.assertRaises(RuntimeError):
                    bootstrap.configure_notification_gradle(gradle)
                self.assertEqual(gradle.read_text(), changed)

    def test_notification_plugin_has_exact_stable_pin_and_matching_lock(self):
        root = Path(__file__).resolve().parents[2]
        pubspec = (root / 'pubspec.yaml').read_text()
        lock = (root / 'pubspec.lock').read_text()
        pins = re.findall(r'^  flutter_local_notifications:\s*(\S+)\s*$', pubspec, re.MULTILINE)
        self.assertEqual(pins, ['22.3.3'], 'the notification plugin must be pinned exactly')
        block = re.search(r'^  flutter_local_notifications:\n(?:(?!  [a-zA-Z_][^\n]*:\n).+\n)+',
                          lock, re.MULTILINE)
        self.assertIsNotNone(block)
        self.assertRegex(block.group(), r'(?m)^    version: "22\.3\.3"$')


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
        app = self._managed_android()
        bootstrap.configure_update_channels(app)
        gitlab_manifest = (app / 'src/gitlab/AndroidManifest.xml').read_text()
        self.assertIn('android.permission.REQUEST_INSTALL_PACKAGES', gitlab_manifest)
        self.assertIn('android:exported="false"', gitlab_manifest)
        self.assertIn('${applicationId}.updates', gitlab_manifest)
        play_manifest = (app / 'src/play/AndroidManifest.xml').read_text()
        self.assertEqual(play_manifest, bootstrap.PLAY_MANIFEST)
        self.assertNotIn('REQUEST_INSTALL_PACKAGES', play_manifest,
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
        app = self._managed_android()
        activity = app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'MainActivity.kt'
        activity.write_text(bootstrap.TEMPLATE_MAIN_ACTIVITY.replace('FlutterActivity()', 'FlutterFragmentActivity()'))
        with self.assertRaisesRegex(RuntimeError, 'Unknown MainActivity template'):
            bootstrap.configure_update_channels(app)
        for earlier in (bootstrap.LINKS_MAIN_ACTIVITY, bootstrap.FRAGMENT_MAIN_ACTIVITY):
            activity.write_text(earlier)
            bootstrap.configure_update_channels(app)
            self.assertEqual(activity.read_text(), bootstrap.MAIN_ACTIVITY, 'an earlier managed activity is upgraded')
        bootstrap.configure_update_channels(app)
        gradle = app / 'build.gradle.kts'
        gradle.write_text(gradle.read_text().replace('app-update:2.1.0', 'app-update:1.0.0'))
        with self.assertRaisesRegex(RuntimeError, 'Stale managed update dependencies'):
            bootstrap.configure_update_channels(app)

    def test_update_channels_require_complete_agent_before_any_write(self):
        app = self._app()
        (app / 'src/main/AndroidManifest.xml').write_text(self.FRESH_MANIFEST)
        before = {p: p.read_bytes() for p in app.rglob('*') if p.is_file()}
        with self.assertRaisesRegex(RuntimeError, 'complete agent service template'):
            bootstrap.configure_update_channels(app)
        self.assertEqual({p: p.read_bytes() for p in app.rglob('*') if p.is_file()}, before)
        bootstrap.configure_android(self.root)
        for name in bootstrap.agent_run_files():
            path = app / name
            content = path.read_bytes()
            path.unlink()
            before = {p: p.read_bytes() for p in app.rglob('*') if p.is_file()}
            with self.subTest(missing=name), self.assertRaisesRegex(RuntimeError, 'Incomplete managed agent'):
                bootstrap.configure_update_channels(app)
            self.assertEqual({p: p.read_bytes() for p in app.rglob('*') if p.is_file()}, before)
            path.write_bytes(content)

    def test_update_only_activity_is_refused_consistently_before_writing(self):
        app = self._managed_android()
        activity = app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'MainActivity.kt'
        activity.write_text(bootstrap.UPDATE_ONLY_MAIN_ACTIVITY)
        # Reproduce the full old update-only tree: no link component or service.
        for name in bootstrap.agent_run_files():
            (app / name).unlink()
        (app / 'src/main/kotlin' / bootstrap.KOTLIN_PACKAGE / 'LinkActivity.kt').unlink()
        manifest = app / 'src/main/AndroidManifest.xml'
        tree = ET.parse(manifest)
        root = tree.getroot()
        a = '{' + bootstrap.ANDROID + '}'
        for node in list(root.findall('uses-permission')):
            if node.get(a + 'name') in bootstrap.AGENT_PERMISSIONS:
                root.remove(node)
        application = root.find('application')
        for node in list(application):
            if node.tag == 'service' or node.get(a + 'name') == bootstrap.LINK_ACTIVITY_NAME:
                application.remove(node)
        tree.write(manifest)
        before = {p: p.read_bytes() for p in app.rglob('*') if p.is_file()}
        for check in (lambda: bootstrap._check_update_template(app),
                      lambda: bootstrap.configure_update_channels(app),
                      lambda: bootstrap.configure_android(self.root)):
            with self.assertRaisesRegex(RuntimeError, 'Unknown MainActivity template'):
                check()
            self.assertEqual({p: p.read_bytes() for p in app.rglob('*') if p.is_file()}, before)

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
        command = self._body(source, 'override fun onStartCommand')
        self.assertIn('        if (failure != null) AgentRunsChannel.serviceStartFailed(this, intent?.getStringExtra(EXTRA_PERMIT_ID), failure)\n'
                      '        else AgentRunsChannel.serviceStarted(this, intent?.getStringExtra(EXTRA_PERMIT_ID))\n', command)
        promotion = self._body(command, 'try')
        self.assertEqual(promotion.strip(),
                         'promote(AgentRunsChannel.startProgress(intent?.getStringExtra(EXTRA_PERMIT_ID)))\n            null')
        self.assertLess(command.index('promote('), command.index('AgentRunsChannel.serviceStarted('))
        failed = self._body(source, 'fun serviceStartFailed')
        self.assertIn('if (permit.id == expectedId && (instance.permitId == null || instance.permitId == permit.id)) stop(reason, instance)', failed)
        # Only the getService stop intent bypasses promotion (C4). All FGS starts
        # still discharge the foreground obligation before any active reply.
        stop_branch = self._body(command, 'if (intent?.action == ACTION_STOP_ALL)')
        self.assertEqual(stop_branch.strip(),
                         'AgentRunsChannel.notificationStop(this)\n            return START_NOT_STICKY')
        fgs_start = command[command.index('// Every start'):]
        self.assertNotIn('return', fgs_start[:fgs_start.index('promote(')])
        self.assertNotIn('stopNative(', command)
        self.assertNotIn('current', promotion)
        start = self._body(source, 'fun serviceStarted')
        self.assertLess(start.index('permit.state = State.ACTIVE'), start.index('active(it.result'))
        self.assertIn('if (permit.id != expectedId) return', start)
        orphan = self._body(start, 'if (permit == null)')
        self.assertIn('stopNative(instance)', orphan)
        self.assertIn('return', orphan)
        self.assertIn('State.STARTING', source)
        for forbidden in ('FlutterEngine(', 'SharedPreferences', 'WorkManager', 'AlarmManager',
                          'START_STICKY', 'onTaskRemoved', 'File(', 'CoroutineScope', 'WakeLock'):
            self.assertNotIn(forbidden, source)
        self.assertNotRegex(source, r'\bThread\(')
        self.assertIn('Looper.myLooper() == Looper.getMainLooper()', source)
        self.assertNotIn('override fun onCreate', source, 'creation must not bind to the mutable current permit')
        self.assertNotIn('fun serviceCreated', source)
        self.assertIn('internal var permitId: String? = null\n        private set', source)
        bind = self._body(source, 'internal fun bindPermit')
        self.assertEqual(bind.strip(), 'if (permitId == null) permitId = id\n        return permitId == id')
        self.assertLess(start.index('permit.id != expectedId'), start.index('instance.bindPermit(permit.id)'))
        self.assertLess(start.index('if (!instance.bindPermit(permit.id)) return'), start.index('service = instance'))
        self.assertEqual(source[:source.index('internal data class RunProgress')].count('permitId = id'), 1,
                         'a service lifetime can only bind once')

    def test_agent_starting_cancellation_only_revokes_until_promoted_callback(self):
        source = bootstrap.AGENT_RUN_SERVICE
        # Release/stopAll/register/destroy may arrive either before onCreate or
        # between onCreate/onStartCommand. Neither ordering may stop a STARTING FGS.
        self.assertNotIn('stopService(', source)
        self.assertNotRegex(source, r'\b(?:context|activity)\??\.stopService\(')
        self.assertNotIn('serviceCreated', source)
        native = self._body(source, 'private fun stopNative(instance:')
        self.assertIn('val running = service ?: instance', native)
        self.assertIn('running?.stopNative()', native)
        self.assertNotIn('stopSelf(', native)
        start = self._body(source, 'fun serviceStarted')
        self.assertEqual(source.count('service = instance'), 1)
        self.assertNotIn('service =', self._body(source, 'private fun start('))
        instance_stop = self._body(source, 'internal fun stopNative')
        self.assertIn('removeForeground()', instance_stop)
        self.assertIn('if (foregroundStarted) stopForeground(STOP_FOREGROUND_REMOVE)',
                      self._body(source, 'internal fun removeForeground'))
        self.assertIn('stopSelf()', self._body(instance_stop, 'finally'))
        self.assertNotIn('return', instance_stop, 'stale getService stop must stopSelf without promotion')
        promote = self._body(source, 'internal fun promote')
        self.assertGreater(promote.index('foregroundStarted = true'), promote.rindex('startForeground('))
        self.assertEqual(source.count('foregroundStarted = true'), 1)
        # Null/cancelled/released: stop only after the unconditional promotion.
        # Stale A intent with current B: keep the shared service, await B's intent.
        tail = start[start.index('if (permit.id != expectedId) return'):]
        self.assertNotIn('instance.stopNative()', tail)
        for signature in ('private fun release(', 'private fun stop(reason:', 'fun activityDestroyed', 'fun register('):
            body = self._body(source, signature)
            self.assertNotIn('stopSelf(', body)
            self.assertNotIn('stopService(', body)

    def test_agent_pending_replies_are_outside_promotion_and_individually_isolated(self):
        source = bootstrap.AGENT_RUN_SERVICE
        command = self._body(source, 'override fun onStartCommand')
        self.assertNotIn('active(', self._body(command, 'try'))
        started = self._body(source, 'fun serviceStarted')
        self.assertNotIn('active(', self._body(started, 'try'))
        self.assertLess(started.index('permit.state = State.ACTIVE'), started.index('val pending = permit.pending.toList()'))
        self.assertLess(started.index('permit.pending.clear()'), started.index('pending.forEach'))
        each = self._body(started, 'pending.forEach')
        self.assertIn('try { active(it.result, permit, it.requestId, it.opSeq) }', each)
        self.assertIn('catch (_: RuntimeException)', each)
        self.assertNotIn('stop(', each)
        rejected = self._body(source, 'private fun finishPending')
        self.assertIn('permit.pending.toList()', rejected)
        self.assertLess(rejected.index('permit.pending.clear()'), rejected.index('pending.forEach'))
        self.assertIn('pending.forEach { try { reject(it.result, reason) } catch (_: RuntimeException)', rejected)
        self.assertIn('finishPending(permit, "released")', self._body(source, 'private fun release('))
        self.assertIn('finishPending(permit, reason)', self._body(source, 'private fun notifyInvalidated'))

    def test_stop_intent_preserves_pending_foreground_dispatches_across_revocation(self):
        source = bootstrap.AGENT_RUN_SERVICE
        self.assertIn('private val pendingForegroundStarts = HashSet<String>()', source)
        self.assertIn('private var deferredStop: AgentRunService? = null', source)
        start = self._body(source, 'private fun start(')
        self.assertLess(start.index('pendingForegroundStarts.add(permit.id)'),
                        start.index('activity.startForegroundService(intent)'))
        dispatch = start[start.index('pendingForegroundStarts.add(permit.id)'):]
        failed_dispatch = self._body(start, 'if (component == null)')
        self.assertLess(failed_dispatch.index('pendingForegroundStarts.remove(permit.id)'),
                        failed_dispatch.index('stop("start_failed")'))
        for exception in ('SecurityException', 'IllegalStateException', 'RuntimeException'):
            failed = self._body(dispatch, f'catch (_: {exception})')
            self.assertLess(failed.index('pendingForegroundStarts.remove(permit.id)'), failed.index('stop('))
        command = self._body(source, 'override fun onStartCommand')
        stop_branch = self._body(command, 'if (intent?.action == ACTION_STOP_ALL)')
        self.assertNotIn('startCommandReceived', stop_branch,
                         'a getService stop is not the queued foreground-start command')
        self.assertLess(command.index('AgentRunsChannel.startCommandReceived('), command.index('promote('))
        received = self._body(source, 'fun startCommandReceived(')
        self.assertIn('expectedId?.let { pendingForegroundStarts.remove(it) }', received)
        for signature in ('private fun invalidate(', 'private fun release(', 'fun activityDestroyed('):
            body = self._body(source, signature)
            self.assertNotIn('pendingForegroundStarts.', body,
                             'stop/release/detach cannot forget an accepted undelivered start')
        native = self._body(source, 'private fun stopNative(instance:')
        self.assertIn('val running = service ?: instance ?: deferredStop', native)
        self.assertLess(native.index('service = null'), native.index('if (pendingForegroundStarts.isNotEmpty())'))
        deferred = self._body(native, 'if (pendingForegroundStarts.isNotEmpty())')
        self.assertIn('deferredStop = running', deferred)
        self.assertIn('return !cleanupFailed', deferred)
        self.assertIn('running?.removeForeground()', deferred,
                      'pending dispatches cannot retain the active foreground notification')
        self.assertNotIn('stopNative()', deferred)
        self.assertLess(native.index('deferredStop = null'), native.index('running?.stopNative()'))
        started = self._body(source, 'fun serviceStarted(')
        self.assertIn('stopNative(instance)', self._body(started, 'if (permit == null)'))
        self.assertIn('deferredStop = null', started)
        failed = self._body(source, 'fun serviceStartFailed(')
        self.assertIn('stopNative(instance)', self._body(failed, 'if (permit == null)'))
        self.assertIn('stop(reason, instance)', failed)
        self.assertIn('if (deferredStop === instance) deferredStop = null',
                      self._body(source, 'fun serviceEnded('))

    def test_agent_destroy_timeout_and_stop_invalidate_before_native_stop_and_callback(self):
        source = bootstrap.AGENT_RUN_SERVICE
        for signature, call in [('override fun onTimeout', 'AgentRunsChannel.serviceTimedOut(this)'),
                                ('override fun onDestroy', 'AgentRunsChannel.serviceEnded(this, "service_destroyed")')]:
            body = self._body(source, signature)
            self.assertTrue(body.lstrip().startswith(call))
            self.assertNotIn('promote(', body)
            self.assertNotIn('serviceStarted(', body)
        ended = self._body(source, 'fun serviceEnded')
        self.assertLess(ended.index('invalidate()'), ended.index('instance.stopNative()'))
        self.assertLess(ended.index('service = null'), ended.index('instance.stopNative()'))
        self.assertLess(ended.index('instance.stopNative()'), ended.index('notifyInvalidated('))
        self.assertLess(ended.index('invalidate()'), ended.index('notifyInvalidated('))
        self.assertIn('current?.id == instance.permitId', ended, 'late destroy is scoped to its permit')
        timeout = self._body(source, 'fun serviceTimedOut')
        self.assertEqual(timeout.strip(), 'serviceEnded(instance, "timeout")')
        stop = self._body(source, 'private fun stop(reason:')
        self.assertLess(stop.index('invalidate()'), stop.index('stopNative(instance)'))
        self.assertLess(stop.index('stopNative(instance)'), stop.index('notifyInvalidated('))
        invalidation = self._body(source, 'private fun invalidate')
        self.assertLess(invalidation.index('State.INVALIDATED'), invalidation.index('current = null'))
        self.assertIn('permit.nonces.clear()', invalidation)
        native = self._body(source, 'internal fun stopNative')
        self.assertIn('removeForeground()', native)
        self.assertIn('stopForeground(STOP_FOREGROUND_REMOVE)',
                      self._body(source, 'internal fun removeForeground'))
        self.assertIn('finally', native)
        self.assertIn('stopSelf()', native)
        main = self._body(bootstrap.MAIN_ACTIVITY, 'override fun onDestroy')
        self.assertLess(main.index('AgentRunsChannel.activityDestroyed(this)'), main.index('super.onDestroy()'))
        destroyed = self._body(source, 'fun activityDestroyed')
        self.assertLess(destroyed.index('stop("activity_destroyed")'), destroyed.index('channel = null'))

    def test_engine_detach_checks_the_exact_engine_and_owner_before_revoking(self):
        source = bootstrap.AGENT_RUN_SERVICE
        cleanup = self._body(bootstrap.MAIN_ACTIVITY, 'override fun cleanUpFlutterEngine')
        self.assertLess(cleanup.index('AgentRunsChannel.engineDetached(flutterEngine, this)'),
                        cleanup.index('super.cleanUpFlutterEngine(flutterEngine)'))
        detach = self._body(source, 'fun engineDetached(')
        self.assertIn('if (engineReference?.get() !== engine) return', detach)
        self.assertLess(detach.index('if (engineReference?.get() !== engine) return'),
                        detach.index('activityDestroyed(activity)'))
        destroyed = self._body(source, 'fun activityDestroyed(')
        self.assertIn('if (owner !== activity || registration !== expectedBinding) return', destroyed)
        self.assertLess(destroyed.index('stop("activity_destroyed")'),
                        destroyed.index('channel?.setMethodCallHandler(null)'))
        self.assertIn('engineReference = null', destroyed)

    def test_engine_lifecycle_is_binding_scoped_and_does_not_modify_listener_iteration(self):
        source = bootstrap.AGENT_RUN_SERVICE
        register = self._body(source, 'fun register(')
        self.assertLess(register.index('owner?.let { activityDestroyed(it) }'),
                        register.index('registration = binding'))
        self.assertIn('engineReference = WeakReference(engine)', register)
        self.assertIn('engine.addEngineLifecycleListener(listener)', register)
        restart = self._body(register, 'override fun onPreEngineRestart')
        self.assertIn('if (registration === binding) stop("activity_destroyed")', restart)
        destroyed_callback = self._body(register, 'override fun onEngineWillDestroy')
        self.assertIn('activityDestroyed(activity, binding, engineDestroying = true)', destroyed_callback)
        for callback in (restart, destroyed_callback):
            self.assertNotIn('removeEngineLifecycleListener', callback)
        destroyed = self._body(source, 'fun activityDestroyed(')
        self.assertIn('if (!engineDestroying && listener != null)', destroyed)
        self.assertIn('engine?.removeEngineLifecycleListener(listener)', destroyed)
        self.assertLess(destroyed.index('stop("activity_destroyed")'),
                        destroyed.index('engineReference = null'))
        self.assertIn('engineListener = null', destroyed)

    def test_agent_ordering_request_release_and_cancel_before_start_are_generated(self):
        source = bootstrap.AGENT_RUN_SERVICE
        sequence = self._body(source, 'private fun sequence')
        self.assertIn('seq <= lastOpSeq', sequence)
        self.assertIn('"stale_operation"', sequence)
        self.assertIn('"opSeqFloor" to lastOpSeq))\n            return null', sequence)
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
        self.assertIn('var latestStartRequestId: String = createdRequestId', source)
        self.assertIn('permit.latestStartRequestId = requestId', start)
        self.assertIn('"startRequestId" to permit.latestStartRequestId',
                      self._body(source, 'private fun notifyInvalidated'))
        self.assertIn('active(result, permit, requestId, seq)', start)
        release = self._body(source, 'private fun release(')
        self.assertIn('byPermit == byRequest', release, 'exactly one release scope')
        self.assertLess(release.index('sequence(args, result)'), release.index('val permit = current'))
        self.assertNotIn('if (cleanupFailed) { reject(result, "cleanup_failed"); return }', release,
                         'cleanup failure must not prevent revoking a matching permit')
        self.assertIn('if (cleanupFailed) reply("rejected", "reason" to "cleanup_failed")',
                      self._body(release, 'if (permit == null)'))
        self.assertIn('permit.createdRequestId == target && permit.latestStartSeq == permit.createdOpSeq', release)
        self.assertIn('(byPermit && permit.id != target) || (byRequest && !ownsRequest)', release)
        self.assertLess(release.index('!ownsRequest'), release.index('permit.state = State.RELEASED'))
        self.assertLess(release.index('State.RELEASED'), release.index('stopNative()'))
        self.assertIn('"didRelease" to false', release)
        self.assertIn('result.success(reply("released", "didRelease" to false)); return', release)
        self.assertIn('permit.nonces.clear()', release)
        self.assertNotIn('notifyInvalidated(', release)
        self.assertIn('cleanupFailed = true', source)
        self.assertIn('if (cleanupFailed) { reject(result, "cleanup_failed"); return }', start)

    def test_stop_all_uses_immutable_explicit_get_service_and_stale_stop_never_promotes(self):
        source = bootstrap.AGENT_RUN_SERVICE
        notification = self._body(source, 'private fun notification(')
        self.assertIn('Intent(this, AgentRunService::class.java).setAction(ACTION_STOP_ALL)', notification)
        self.assertIn('PendingIntent.getService(this, STOP_REQUEST_CODE, stopIntent,', notification)
        self.assertIn('PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE', notification)
        self.assertNotIn('getForegroundService', source)
        self.assertIn('Notification.Action.Builder(null, label, stop)', notification)
        self.assertIn('if (Build.VERSION.SDK_INT >= 31) action.setAuthenticationRequired(false)', notification)
        self.assertIn('val stopAction = action.build()', notification)
        self.assertIn('publicVersion.addAction(stopAction)', notification)
        self.assertIn('ongoing.addAction(stopAction)', notification)
        self.assertLess(notification.index('publicVersion.addAction(stopAction)'),
                        notification.index('publicVersion.build()'))
        self.assertIn('progress.stopAllLabel?.let { label ->', notification)
        self.assertIn('STOP_REQUEST_CODE = 6101', source)
        self.assertIn('ACTION_STOP_ALL = "io.gitlabmobile.agent_runs.STOP_ALL"', source)
        command = self._body(source, 'override fun onStartCommand')
        branch = self._body(command, 'if (intent?.action == ACTION_STOP_ALL)')
        self.assertLess(command.index('if (intent?.action == ACTION_STOP_ALL)'), command.index('promote('))
        self.assertIn('AgentRunsChannel.notificationStop(this)', branch)
        self.assertIn('return START_NOT_STICKY', branch)
        for forbidden in ('startForeground', 'promote(', 'startRuns', 'startService', 'postDelayed', 'invokeMethod'):
            self.assertNotIn(forbidden, branch)
        stop = self._body(source, 'fun notificationStop(')
        self.assertEqual(stop.strip(), 'mainThread()\n        stop("user_stop", instance)')
        native = self._body(source, 'private fun stopNative(instance:')
        self.assertIn('val running = service ?: instance', native)
        self.assertLess(native.index('service = null'), native.index('running?.stopNative()'))
        instance_stop = self._body(source, 'internal fun stopNative')
        self.assertNotIn('return', instance_stop)
        self.assertIn('stopSelf()', self._body(instance_stop, 'finally'))

    def test_stop_paths_cannot_wait_for_dart_or_restart_service_and_detach_drops_engine(self):
        source = bootstrap.AGENT_RUN_SERVICE
        for text in (bootstrap.MAIN_ACTIVITY, source):
            destroyed = self._body(text, 'override fun onDestroy')
            for forbidden in ('startService', 'startForeground', 'promote(', 'postDelayed', 'invokeMethod'):
                self.assertNotIn(forbidden, destroyed)
        for signature in ('fun serviceEnded(', 'fun serviceTimedOut(', 'fun notificationStop(',
                          'fun activityDestroyed(', 'private fun stop(reason:', 'internal fun stopNative'):
            body = self._body(source, signature)
            for forbidden in ('startService', 'startForeground', 'promote(', 'postDelayed',
                              'MethodChannel.Result', 'invokeMethod', 'await', 'CountDownLatch'):
                self.assertNotIn(forbidden, body, signature)
        notify = self._body(source, 'private fun notifyInvalidated')
        self.assertIn('channel?.invokeMethod("permitInvalidated", mapOf(', notify)
        self.assertNotIn('MethodChannel.Result', notify, 'callback cannot own the native stop continuation')
        self.assertNotIn('object :', notify)
        native = self._body(source, 'internal fun stopNative')
        self.assertLess(native.index('removeForeground()'), native.index('stopSelf()'))
        detached = self._body(source, 'fun activityDestroyed(')
        for statement in ('channel?.setMethodCallHandler(null)', 'channel = null', 'owner = null',
                          'registration = null', 'visible = null', 'testEvents?.close()', 'testEvents = null'):
            self.assertIn(statement, detached)
        self.assertLess(detached.index('stop("activity_destroyed")'), detached.index('channel?.setMethodCallHandler(null)'))
        cleanup = self._body(bootstrap.MAIN_ACTIVITY, 'override fun cleanUpFlutterEngine')
        self.assertLess(cleanup.index('AgentRunsChannel.engineDetached(flutterEngine, this)'),
                        cleanup.index('super.cleanUpFlutterEngine(flutterEngine)'))
        for forbidden in ('startService', 'startForeground', 'postDelayed'):
            self.assertNotIn(forbidden, cleanup)
        self.assertNotRegex(source, r'(?:private|internal)\s+(?:var|val)\s+\w+\s*:\s*FlutterEngine(?!\.)')

    def test_stop_action_label_uses_bounded_dart_progress_and_initial_matching_start(self):
        source = bootstrap.AGENT_RUN_SERVICE
        progress = self._body(source, 'private fun progress(')
        self.assertIn('"stopAllLabel" to MAX_TITLE_LENGTH', progress)
        self.assertIn('value.isBlank()', progress)
        self.assertIn('value.length > limit', progress)
        self.assertIn("value.any { it < ' ' || it == '\\u007f' }", progress)
        self.assertIn('args["stopAllLabel"] as? String', progress)
        for signature in ('private fun start(', 'private fun update('):
            self.assertIn('"stopAllLabel"', self._body(source, signature))
        self.assertIn('current?.takeIf { it.id == expectedId }?.progress ?: RunProgress(1, 0, null, null, null)', source)
        self.assertIn('promote(AgentRunsChannel.startProgress(intent?.getStringExtra(EXTRA_PERMIT_ID)))', source)
        bridge = (Path(bootstrap.__file__).resolve().parents[1] /
                  'lib/features/ai/ai_background_execution.dart').read_text()
        self.assertIn('l10n.aiRunServiceStopAll', bridge)

    def test_fault_adapter_is_debug_only_explicitly_registered_bounded_and_content_free(self):
        files = bootstrap.agent_run_files()
        adapters = [name for name, text in files.items() if 'class AgentRunQaAdapter' in text]
        self.assertEqual(adapters, [f'src/debug/kotlin/{bootstrap.KOTLIN_PACKAGE}/AgentRunQaAdapter.kt'])
        qa = bootstrap.AGENT_RUN_QA_ADAPTER
        self.assertIn('"io.gitlabmobile/agent_runs_qa"', qa)
        for method in ('configure', 'syntheticTimeout', 'reset'):
            self.assertIn(f'"{method}" ->', qa)
        self.assertIn('dropCallback = drop', qa)
        self.assertIn('!dropCallback', qa)
        self.assertIn('call.method == "register" && args.isEmpty()', qa)
        self.assertIn('else if (!registered)', qa)
        self.assertIn('if (!registered) return result', qa)
        self.assertIn('replyDelayMs = delay.toLong()', qa)
        self.assertIn('!in 0L..5000L', qa)
        self.assertIn('handler.postDelayed({ if (!closed) reply() }, delay)', qa)
        self.assertIn('AgentRunsChannel.serviceEnded(instance, "synthetic_timeout")', qa)
        self.assertIn('"event" to "synthetic_timeout"', qa)
        self.assertNotIn('"synthetic_timeout"', bootstrap.AGENT_RUN_SERVICE)
        self.assertIn('serviceEnded(instance, "timeout")', bootstrap.AGENT_RUN_SERVICE)
        for forbidden in ('Intent', 'Activity', 'SharedPreferences', 'File(', 'GitLab', 'account', 'startForeground'):
            # Comments document the boundary; executable lines cannot cross it.
            code = '\n'.join(line for line in qa.splitlines() if not line.lstrip().startswith('//'))
            self.assertNotIn(forbidden, code)
        self.assertIn('channel.setMethodCallHandler(null)', self._body(qa, 'override fun close'))
        self.assertIn('handler.removeCallbacksAndMessages(null)', self._body(qa, 'override fun close'))
        register = self._body(bootstrap.AGENT_RUN_SERVICE, 'fun register(')
        self.assertIn('Class.forName("io.gitlabmobile.gitlab_mobile.AgentRunQaAdapter")', register)
        self.assertIn('catch (_: ClassNotFoundException)', register)
        self.assertNotIn('ReflectiveOperationException', register,
                         'a broken debug adapter must fail visibly, rather than look like release absence')
        production_handler = self._body(register, 'bridge.setMethodCallHandler')
        for forbidden in ('registerServiceQa', 'Class.forName', 'syntheticTimeout', 'dropCallback', 'replyDelayMs'):
            self.assertNotIn(forbidden, production_handler)
        self.assertNotIn('"io.gitlabmobile/agent_runs_qa"', bootstrap.AGENT_RUN_SERVICE)
        root = Path(bootstrap.__file__).resolve().parents[1]
        self.assertFalse(any('registerServiceQa' in path.read_text() or 'agent_runs_qa' in path.read_text()
                             for path in (root / 'lib').rglob('*.dart')))

    def test_agent_foreground_owner_progress_limits_and_all_sequence_guards(self):
        source = bootstrap.AGENT_RUN_SERVICE
        self.assertEqual(self._body(source, 'fun resumed').strip(),
                         'mainThread(); if (owner === activity) visible = activity')
        self.assertEqual(self._body(source, 'fun paused').strip(),
                         'mainThread(); if (visible === activity) visible = null')
        self.assertIn('AgentRunsChannel.paused(this)', self._body(bootstrap.MAIN_ACTIVITY, 'override fun onPause'))
        self.assertLess(self._body(bootstrap.MAIN_ACTIVITY, 'override fun onPause').index('AgentRunsChannel.paused(this)'),
                        self._body(bootstrap.MAIN_ACTIVITY, 'override fun onPause').index('super.onPause()'))
        register = self._body(source, 'fun register(')
        self.assertIn('owner?.let { activityDestroyed(it) }', register)
        self.assertIn('val reason = if (stop("user_stop")) null else "cleanup_failed"', register)
        destroyed = self._body(source, 'fun activityDestroyed')
        for expression in ('if (owner !== activity || registration !== expectedBinding) return',
                           'visible = null', 'owner = null', 'registration = null'):
            self.assertIn(expression, destroyed)
        start = self._body(source, 'private fun start(')
        self.assertIn('if (visible !== activity || activity.isFinishing || activity.isDestroyed)', start)
        self.assertIn('reject(result, "foreground_required"); return', start)
        self.assertIn('val running = service ?: throw IllegalStateException()\n                    running.update(progress)', start)
        self.assertNotIn('service!!', source)
        update = self._body(source, 'private fun update(')
        self.assertIn('if (permit == null || permit.id != permitId || permit.state != State.ACTIVE)', update)
        self.assertIn('val running = service ?: throw IllegalStateException()', update)
        for signature in ('private fun start(', 'private fun update(', 'private fun release(', 'private fun acquire('):
            body = self._body(source, signature)
            self.assertEqual(body.count('sequence(args, result)'), 1, signature)
            self.assertLess(body.index('sequence(args, result)'), body.index('val permit = current')
                            if 'val permit = current' in body else body.index('var permit = current'))
        progress = self._body(source, 'private fun progress(')
        self.assertIn('number(args, "workCount", 1, 3)', progress)
        self.assertIn('number(args, "step", 0, 1000000)', progress)
        self.assertIn("value.any { it < ' ' || it == '\\u007f' }", progress)
        self.assertIn('value !is String || value.isBlank() || value.length > limit', progress)
        for limit in ('MAX_TITLE_LENGTH = 160', 'MAX_TEXT_LENGTH = 256', 'MAX_ID_LENGTH = 128'):
            self.assertIn(limit, source)

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
        self.assertIn('"moveTaskToBack" -> moveBack(activity, args, result)', bootstrap.AGENT_RUN_SERVICE)

    def test_task_back_validates_sequence_and_live_activity_before_one_call(self):
        source = bootstrap.AGENT_RUN_SERVICE
        register = self._body(source, 'fun register(')
        self.assertLess(register.index('owner !== activity || registration !== binding'),
                        register.index('"moveTaskToBack" ->'))
        body = self._body(source, 'private fun moveBack(')
        keys = 'if (!validKeys(args, setOf("opSeq"), result)) return'
        seq = 'sequence(args, result) ?: return'
        guard = 'if (visible !== activity || activity.isFinishing || activity.isDestroyed)'
        call = 'activity.moveTaskToBack(true)'
        self.assertIn(keys, body)
        self.assertIn(seq, body)
        self.assertIn(guard, body)
        self.assertIn('reject(result, "foreground_required"); return', body)
        self.assertEqual(body.count(call), 1)
        self.assertLess(body.index(keys), body.index(seq))
        self.assertLess(body.index(seq), body.index(guard))
        self.assertLess(body.index(guard), body.index(call))
        for forbidden in ('startService', 'startForegroundService', 'start(', 'stop(',
                          'current', 'service', 'finish(', 'SystemNavigator'):
            self.assertNotIn(forbidden, body)

    def test_task_back_preserves_android_boolean_and_uses_bounded_failure_codes(self):
        body = self._body(bootstrap.AGENT_RUN_SERVICE, 'private fun moveBack(')
        self.assertIn('val moved = try {', body)
        self.assertIn('reply(if (moved) "moved" else "not_moved")', body)
        self.assertIn('catch (_: SecurityException)', body)
        self.assertIn('reject(result, "security_exception"); return', body)
        self.assertIn('catch (_: RuntimeException)', body)
        self.assertIn('reject(result, "move_failed"); return', body)
        self.assertEqual(body.count('result.success('), 1)
        for forbidden in ('message', 'stackTrace', 'toString()', 'result.error', 'unsupported'):
            self.assertNotIn(forbidden, body)

    def test_task_back_qa_counter_counts_only_actual_calls_and_stays_debug_only(self):
        source = bootstrap.AGENT_RUN_SERVICE
        body = self._body(source, 'private fun moveBack(')
        self.assertEqual(source.count('testEvents?.taskBackInvoked()'), 1)
        self.assertIn('testEvents?.taskBackInvoked()\n            activity.moveTaskToBack(true)', body)
        qa = bootstrap.AGENT_RUN_QA_ADAPTER
        self.assertIn('private var taskBackCallCount = 0L', qa)
        self.assertIn('"taskBackCalls" -> if (args.isEmpty())', qa)
        self.assertIn('mapOf("version" to 1, "count" to taskBackCallCount)', qa)
        self.assertEqual(self._body(qa, 'override fun taskBackInvoked').strip(),
                         'if (!closed && registered) taskBackCallCount++')
        reset = self._body(qa, '"reset" -> if (args.isEmpty())')
        self.assertIn('taskBackCallCount = 0L', reset)
        self.assertNotIn('taskBackCallCount', source)
        self.assertNotIn('"taskBackCalls"', source)

    def test_agent_notification_is_private_with_safe_public_resources_and_monochrome_icon(self):
        source = bootstrap.AGENT_RUN_SERVICE
        self.assertIn('NOTIFICATION_ID = 6100', source)
        self.assertIn('NOTIFICATION_CHANNEL = "ai_runs_v1"', source)
        notification = self._body(source, 'private fun notification(')
        self.assertIn('NotificationManager.IMPORTANCE_LOW', notification)
        self.assertIn('lockscreenVisibility = Notification.VISIBILITY_PRIVATE', notification)
        self.assertIn('.setVisibility(Notification.VISIBILITY_PRIVATE)', notification)
        self.assertIn('return ongoing.setPublicVersion(publicVersion.build()).build()', notification)
        public = notification[notification.index('val publicVersion'):notification.index('val ongoing')]
        self.assertNotIn('progress.', public)
        self.assertIn('R.string.ai_run_service_title', public)
        self.assertIn('R.string.ai_run_service_text', public)
        self.assertIn('progress.title ?: getString(R.string.ai_run_service_title)', notification)
        self.assertIn('progress.text ?: getString(R.string.ai_run_service_text)', notification)
        self.assertNotRegex(source, r'[\u3400-\u9fff]')
        self.assertNotRegex(notification, r'setContent(?:Title|Text)\("')
        self.assertIn('PendingIntent.getService(', notification)
        icon = ET.fromstring(bootstrap.AGENT_ICON)
        self.assertEqual(icon.tag, 'vector')
        self.assertEqual({node.get('{' + bootstrap.ANDROID + '}fillColor') for node in icon.findall('path')}, {'#FFFFFFFF'})

    @staticmethod
    def _resource_value(value):
        # Android quoted string syntax, independently decoded after XML parsing.
        if not (value.startswith('"') and value.endswith('"')):
            raise AssertionError('Android resource value must be quoted')
        return re.sub(r'\\([\\\'"@?nrt])', lambda match: {'n': '\n', 'r': '\r', 't': '\t'}.get(
            match[1], match[1]), value[1:-1])

    def test_agent_resources_cover_all_languages_and_android_escaping_round_trips(self):
        app = self._managed_android()
        _, catalogs = bootstrap.l10n.load()
        paths = list((app / 'src/main/res').glob('values*/strings.xml'))
        self.assertEqual(len(paths), 25, '24 languages plus the Indonesian legacy resource alias')
        self.assertEqual((app / 'src/main/res/values-in/strings.xml').read_bytes(),
                         (app / 'src/main/res/values-id/strings.xml').read_bytes())
        languages = {language for _, _, _, language, _, _ in bootstrap.l10n.LANGUAGES}
        self.assertEqual(languages & {'id', 'he', 'yi', 'in', 'iw', 'ji'}, {'id'})
        locales = ET.parse(app / 'src/main/res/xml/locales_config.xml').getroot()
        names = [node.get('{' + bootstrap.ANDROID + '}name') for node in locales]
        self.assertIn('id', names)
        self.assertNotIn('in', names)
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
        for name in set(files) - {'src/play/AndroidManifest.xml'}:
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
            with self.assertRaisesRegex(RuntimeError, 'Unknown managed Android content: src/play/AndroidManifest.xml'):
                bootstrap.configure_android(self.root)
            path.write_text(bootstrap.PLAY_MANIFEST)
        foreign = app / 'src/staging/AndroidManifest.xml'
        foreign.parent.mkdir(parents=True, exist_ok=True)
        foreign.write_text(f'<manifest xmlns:android="{bootstrap.ANDROID}" />')
        with self.assertRaisesRegex(RuntimeError, 'Unknown Android source-set manifest: staging'):
            bootstrap.configure_android(self.root)
        foreign.unlink()
        foreign.parent.rmdir()
        self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_play_manifest_removes_fgs_and_upgrades_pre_change_tree(self):
        app = self._managed_android()
        main_manifest = app / 'src/main/AndroidManifest.xml'
        gitlab_manifest = app / 'src/gitlab/AndroidManifest.xml'
        play_manifest = app / 'src/play/AndroidManifest.xml'
        main_before = main_manifest.read_bytes()
        gitlab_before = gitlab_manifest.read_bytes()
        self.assertEqual(play_manifest.read_text(), bootstrap.PLAY_MANIFEST)
        self.assertEqual(gitlab_manifest.read_text(), bootstrap.GITLAB_MANIFEST)
        a = '{' + bootstrap.ANDROID + '}'
        tools = '{http://schemas.android.com/tools}'
        play_root = ET.parse(play_manifest).getroot()
        self.assertEqual(
            [(node.get(a + 'name'), node.get(tools + 'node')) for node in play_root.findall('uses-permission')],
            [
                ('android.permission.FOREGROUND_SERVICE', 'remove'),
                ('android.permission.FOREGROUND_SERVICE_DATA_SYNC', 'remove'),
            ],
        )
        self.assertEqual(
            [(node.get(a + 'name'), node.get(tools + 'node')) for node in play_root.findall('application/service')],
            [('.AgentRunService', 'remove')],
        )
        self.assertNotIn('POST_NOTIFICATIONS', play_manifest.read_text())
        main_root = ET.parse(main_manifest).getroot()
        self.assertIn(
            'android.permission.POST_NOTIFICATIONS',
            [node.get(a + 'name') for node in main_root.findall('uses-permission')],
        )
        # Upgrading a pre-change managed tree (no play manifest yet) adds it cleanly.
        play_manifest.unlink()
        bootstrap.configure_android(self.root)
        self.assertEqual(play_manifest.read_text(), bootstrap.PLAY_MANIFEST)
        self.assertEqual(main_manifest.read_bytes(), main_before)
        self.assertEqual(gitlab_manifest.read_bytes(), gitlab_before)
        # A tampered play manifest is refused before any writes.
        before = {path: path.read_bytes() for path in app.rglob('*') if path.is_file()}
        for tampered in (
            bootstrap.PLAY_MANIFEST.replace('FOREGROUND_SERVICE_DATA_SYNC', 'POST_NOTIFICATIONS'),
            bootstrap.PLAY_MANIFEST.replace('tools:node="remove"', 'tools:node="merge"', 1),
            bootstrap.PLAY_MANIFEST + '<!-- drift -->\n',
        ):
            play_manifest.write_text(tampered)
            with self.subTest(tampered=tampered), self.assertRaisesRegex(
                RuntimeError, 'Unknown managed Android content: src/play/AndroidManifest.xml'
            ):
                bootstrap.configure_android(self.root)
        play_manifest.write_text(bootstrap.PLAY_MANIFEST)
        self.assertEqual({path: path.read_bytes() for path in app.rglob('*') if path.is_file()}, before)

    def test_missing_play_manifest_and_another_managed_file_is_refused_before_writes(self):
        app = self._managed_android()
        files = bootstrap._check_update_template(app)
        play_manifest = app / 'src/play/AndroidManifest.xml'
        play_manifest.unlink()
        for name in sorted(set(files) - {'src/play/AndroidManifest.xml'}):
            path = app / name
            original = path.read_bytes()
            path.unlink()
            before = {item: item.read_bytes() for item in app.rglob('*') if item.is_file()}
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, 'Incomplete managed update/link'):
                bootstrap.configure_android(self.root)
            self.assertFalse(play_manifest.exists())
            self.assertEqual({item: item.read_bytes() for item in app.rglob('*') if item.is_file()}, before)
            path.write_bytes(original)

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

    def test_invalid_notification_blocks_are_refused_before_any_write(self):
        app = self._managed_android()
        gradle = app / 'build.gradle.kts'
        original = gradle.read_text()
        for changed in (
            original.replace(bootstrap.NOTIFICATION_DESUGAR_END, ''),
            original.replace(bootstrap.NOTIFICATION_DEPENDENCIES_END, ''),
            original.replace('desugar_jdk_libs:2.1.4', 'desugar_jdk_libs:2.0.0'),
            original.replace('JvmTarget.JVM_17', 'JvmTarget.JVM_11'),
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

    def test_default_bootstrap_does_not_resolve_offline(self):
        with patch.object(bootstrap.subprocess, 'run') as run:
            bootstrap.apply_launcher_icons('/pinned/bin/flutter')
        self.assertEqual(run.call_args_list[0].args[0],
                         ['/pinned/bin/flutter', 'pub', 'get', '--enforce-lockfile'])
        with patch.object(bootstrap, 'ROOT', self.root), patch.object(bootstrap, 'check_sdk'), \
                patch.object(bootstrap.shutil, 'which', return_value='/pinned/flutter'), \
                patch.object(bootstrap.tempfile, 'TemporaryDirectory'), \
                patch.object(bootstrap.subprocess, 'run'), patch.object(bootstrap, 'configure_android'), \
                patch.object(bootstrap, 'configure_ios'), patch.object(bootstrap.shutil, 'copytree'), \
                patch.object(bootstrap.shutil, 'copy2'), patch.object(bootstrap, 'apply_launcher_icons') as icons, \
                patch('builtins.print'), \
                patch.object(sys, 'argv', ['bootstrap.py']):
            self.assertEqual(bootstrap.main(), 0)
        icons.assert_called_once_with('/pinned/flutter', offline=False)

    def test_generate_templates_copies_local_packages_dir(self):
        plugin_dir = self.root / 'packages/mergeline_on_device_ai'
        plugin_dir.mkdir(parents=True)
        (plugin_dir / 'pubspec.yaml').write_text('name: mergeline_on_device_ai\n')
        observed_packages = []

        def fake_flutter_create(cmd, **kwargs):
            template_dir = Path(cmd[-1])
            observed_packages.append((template_dir / 'packages/mergeline_on_device_ai/pubspec.yaml').read_text())
            (template_dir / 'android').mkdir(parents=True, exist_ok=True)
            (template_dir / 'ios').mkdir(parents=True, exist_ok=True)
            (template_dir / '.metadata').write_text('metadata\n')

        with patch.object(bootstrap, 'ROOT', self.root), \
                patch.object(bootstrap.subprocess, 'run', side_effect=fake_flutter_create), \
                patch.object(bootstrap, 'configure_android'), \
                patch.object(bootstrap, 'configure_ios'):
            bootstrap.generate_templates('/pinned/flutter')
        self.assertEqual(observed_packages, ['name: mergeline_on_device_ai\n'])
        self.assertTrue((self.root / 'android').is_dir())
        self.assertTrue((self.root / 'ios').is_dir())
        self.assertTrue((self.root / '.metadata').is_file())

    def _merged_fixture(self, flavor):
        app = self.root / 'app'
        path = self.root / f'build/app/intermediates/merged_manifests/{flavor}Debug/processManifest/AndroidManifest.xml'
        path.parent.mkdir(parents=True, exist_ok=True)
        tree = ET.parse(app / 'src/main/AndroidManifest.xml')
        root = tree.getroot()
        a = '{' + bootstrap.ANDROID + '}'
        package = 'app.mergeline' if flavor == 'play' else 'io.gitlabmobile.gitlab_mobile'
        root.set('package', package)
        if flavor == 'play':
            for node in list(root.findall('uses-permission')):
                if node.get(a + 'name') in {
                    'android.permission.FOREGROUND_SERVICE',
                    'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
                }:
                    root.remove(node)
            application = root.find('application')
            for node in list(application.findall('service')):
                if node.get(a + 'name', '').split('.')[-1] == 'AgentRunService':
                    application.remove(node)
        for node in root.findall('application/activity') + root.findall('application/service'):
            if node.get(a + 'name', '').startswith('.'):
                node.set(a + 'name', 'io.gitlabmobile.gitlab_mobile' + node.get(a + 'name'))
        ET.SubElement(root, 'uses-sdk', {a + 'minSdkVersion': '24', a + 'targetSdkVersion': '36'})
        existing = {node.get(a + 'name') for node in root.findall('uses-permission')}
        permissions = MERGED_COMMON_PERMISSIONS | {package + '.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'}
        if flavor == 'gitlab':
            permissions |= MERGED_GITLAB_PERMISSIONS
        for permission in sorted(permissions - existing):
            ET.SubElement(root, 'uses-permission', {a + 'name': permission})
        app_node = root.find('application')
        plugin = ET.SubElement(app_node, 'service', {
            a + 'name': 'com.google.android.gms.metadata.ModuleDependencies',
            a + 'enabled': 'false', a + 'exported': 'false'})
        intent = ET.SubElement(plugin, 'intent-filter')
        ET.SubElement(intent, 'action', {a + 'name': 'com.google.android.gms.metadata.MODULE_DEPENDENCIES'})
        ET.SubElement(plugin, 'meta-data', {a + 'name': 'photopicker_activity:0:required', a + 'value': ''})
        mlkit_service = ET.SubElement(app_node, 'service', {
            a + 'name': 'com.google.mlkit.common.internal.MlKitComponentDiscoveryService',
            a + 'directBootAware': 'true', a + 'exported': 'false'})
        ET.SubElement(mlkit_service, 'meta-data', {
            a + 'name': 'com.google.firebase.components:com.google.mlkit.common.internal.CommonComponentRegistrar',
            a + 'value': 'com.google.firebase.components.ComponentRegistrar'})
        transport_discovery = ET.SubElement(app_node, 'service', {
            a + 'name': 'com.google.android.datatransport.runtime.backends.TransportBackendDiscovery',
            a + 'exported': 'false'})
        ET.SubElement(transport_discovery, 'meta-data', {
            a + 'name': 'backend:com.google.android.datatransport.cct.CctBackendFactory',
            a + 'value': 'cct'})
        ET.SubElement(app_node, 'service', {
            a + 'name': 'com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService',
            a + 'exported': 'false',
            a + 'permission': 'android.permission.BIND_JOB_SERVICE'})
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
        play_root = ET.parse(play).getroot()
        a = '{' + bootstrap.ANDROID + '}'
        play_permissions = {node.get(a + 'name') for node in play_root.findall('uses-permission')}
        self.assertNotIn('android.permission.FOREGROUND_SERVICE', play_permissions)
        self.assertNotIn('android.permission.FOREGROUND_SERVICE_DATA_SYNC', play_permissions)
        self.assertEqual(
            [node for node in play_root.findall('application/service')
             if node.get(a + 'name', '').split('.')[-1] == 'AgentRunService'],
            [],
        )
        gitlab_root = ET.parse(gitlab).getroot()
        gitlab_permissions = {node.get(a + 'name') for node in gitlab_root.findall('uses-permission')}
        self.assertIn('android.permission.FOREGROUND_SERVICE', gitlab_permissions)
        self.assertIn('android.permission.FOREGROUND_SERVICE_DATA_SYNC', gitlab_permissions)
        self.assertEqual(
            len([node for node in gitlab_root.findall('application/service')
                 if node.get(a + 'name', '').split('.')[-1] == 'AgentRunService']),
            1,
        )
        original = play.read_text()
        for mutated in (
            original.replace('</manifest>', '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" /></manifest>'),
            original.replace('</manifest>', '<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" /></manifest>'),
            original.replace('</manifest>', '<uses-permission android:name="android.permission.FOREGROUND_SERVICE" /></manifest>'),
            original.replace('</manifest>', '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" /></manifest>'),
            original.replace('</manifest>', '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" /></manifest>'),
            original.replace('</application>', '<service android:name="io.gitlabmobile.gitlab_mobile.AgentRunService" android:exported="false" android:foregroundServiceType="dataSync" android:stopWithTask="true" /></application>'),
            original.replace('</application>', '<service android:name=".AgentRunService" android:exported="false" android:foregroundServiceType="dataSync" android:stopWithTask="true" /></application>'),
            original.replace('</application>', '<receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" /></application>'),
            original.replace('</application>', '<receiver android:name="foreign.BootReceiver"><intent-filter><action android:name="android.intent.action.BOOT_COMPLETED" /></intent-filter></receiver></application>'),
            original.replace('android:allowBackup="false"', 'android:allowBackup="true"'),
            original.replace('android:usesCleartextTraffic="false"', 'android:usesCleartextTraffic="true"'),
            original.replace('android:host="gitlab.com"', 'android:host="foreign.example"'),
            original.replace('android:host="oauth"', 'android:host="foreign"'),
            original.replace('io.gitlabmobile.gitlab_mobile.MainActivity', 'foreign.MainActivity'),
            original.replace('io.gitlabmobile.gitlab_mobile.LinkActivity', 'foreign.LinkActivity'),
            original.replace('</application>', '<activity android:name="foreign.MainActivity" /></application>'),
            original.replace('</application>', '<activity android:name="io.gitlabmobile.gitlab_mobile.AgentRunQaAdapter" android:exported="true" /></application>'),
            original.replace('</application>', '<provider android:name="com.google.mlkit.common.internal.MlKitInitProvider" android:authorities="app.mergeline.mlkitinitprovider" android:exported="false" android:initOrder="99" /></application>'),
        ):
            play.write_text(mutated)
            with self.assertRaises(AssertionError):
                verify_merged_manifest(play, 'play')
        play.write_text(original)
        original_gitlab = gitlab.read_text()
        for mutated in (
            original_gitlab.replace('<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />', ''),
            original_gitlab.replace('<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />', ''),
            original_gitlab.replace('<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />', ''),
            original_gitlab.replace('android:stopWithTask="true"', 'android:stopWithTask="false"'),
            original_gitlab.replace('android:foregroundServiceType="dataSync"', 'android:foregroundServiceType="location"'),
            original_gitlab.replace('io.gitlabmobile.gitlab_mobile.AgentRunService', '.AgentRunService'),
            original_gitlab.replace('android:foregroundServiceType="dataSync"',
                                    'android:foregroundServiceType="dataSync" android:enabled="false"'),
            original_gitlab.replace('android:foregroundServiceType="dataSync"',
                                    'android:foregroundServiceType="dataSync" android:permission="foreign.permission"'),
            original_gitlab.replace('android:foregroundServiceType="dataSync"',
                                    'android:foregroundServiceType="dataSync" android:process=":foreign"'),
            re.sub(r'<service[^>]*AgentRunService[^>]*/>', '', original_gitlab),
        ):
            gitlab.write_text(mutated)
            with self.assertRaises(AssertionError):
                verify_merged_manifest(gitlab, 'gitlab')
        gitlab.write_text(original_gitlab)
        gitlab.unlink()
        with self.assertRaisesRegex(AssertionError, 'No actual gitlabDebug merged manifest'):
            verify_generated_root(self.root)

    @unittest.skipUnless(os.environ.get('MR6C_GENERATED_ROOT'), 'GN: MR6C_GENERATED_ROOT not set')
    def test_actual_generated_merged_manifests(self):
        root = os.environ['MR6C_GENERATED_ROOT']
        manifests = verify_generated_root(root)
        verify_android_build_config(root)
        apks = verify_generated_apks(root)
        print('MR6C Java 17 compilation targets and AGP 9.1.0 verified', flush=True)
        for flavor, paths in manifests.items():
            for path in paths:
                print(f'MR6C merged manifest verified: {flavor}: {path}', flush=True)
            print(f'MR6C packaged compileSdk 36 and service methods verified: {flavor}: {apks[flavor]}', flush=True)

    def test_merged_helper_failure_is_enforced_under_python_optimized(self):
        module = Path(__file__).resolve()
        code = ('import importlib.util, sys; '
                'spec = importlib.util.spec_from_file_location("bootstrap_test", sys.argv[1]); '
                'module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); '
                'module.verify_generated_root(sys.argv[2])')
        result = subprocess.run([sys.executable, '-O', '-c', code, str(module), str(self.root)],
                                capture_output=True, text=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No actual gitlabDebug merged manifest', result.stderr)

    def test_merged_helper_android_sdk_property_fallback_and_escaped_path(self):
        local = self.root / 'android/local.properties'
        local.parent.mkdir(parents=True)
        local.write_text('sdk.dir=/path/with\\ space/android\\:sdk\n', encoding='iso-8859-1')
        with patch.dict(os.environ, {'ANDROID_HOME': '', 'ANDROID_SDK_ROOT': ''}):
            self.assertEqual(_android_sdk(self.root), Path('/path/with space/android:sdk'))
            with patch.dict(os.environ, {'ANDROID_SDK_ROOT': '/explicit/sdk'}):
                self.assertEqual(_android_sdk(self.root), Path('/explicit/sdk'))
            local.unlink()
            with self.assertRaisesRegex(AssertionError, 'sdk.dir is required'):
                _android_sdk(self.root)

    def test_merged_helper_requires_java_17_and_pinned_agp(self):
        android = self.root / 'android'
        app = android / 'app/build.gradle.kts'
        app.parent.mkdir(parents=True)
        settings = android / 'settings.gradle.kts'
        good_settings = 'plugins {\n    id("com.android.application") version "9.1.0" apply false\n}\n'
        gradle_fixture = self.root / 'fixture.gradle.kts'
        gradle_fixture.write_text(self.GRADLE)
        bootstrap.configure_notification_gradle(gradle_fixture)
        good_app = gradle_fixture.read_text()
        settings.write_text(good_settings)
        app.write_text(good_app)
        verify_android_build_config(self.root)
        for path, text in ((settings, good_settings.replace('9.1.0', '8.1.0')),
                           (app, good_app.replace('sourceCompatibility = JavaVersion.VERSION_17',
                                                  'sourceCompatibility = JavaVersion.VERSION_11')),
                           (app, good_app.replace('targetCompatibility = JavaVersion.VERSION_17',
                                                  'targetCompatibility = JavaVersion.VERSION_11')),
                           (app, good_app.replace('JvmTarget.JVM_17', 'JvmTarget.JVM_11')),
                           (app, good_app.replace('desugar_jdk_libs:2.1.4', 'desugar_jdk_libs:2.0.0')),
                           (app, good_app.replace('isCoreLibraryDesugaringEnabled = true',
                                                  'isCoreLibraryDesugaringEnabled = false')),
                           (app, good_app.replace('compileSdk = flutter.compileSdkVersion', 'compileSdk = 35'))):
            with self.subTest(path=path, text=text):
                path.write_text(text)
                with self.assertRaises(AssertionError):
                    verify_android_build_config(self.root)
                settings.write_text(good_settings)
                app.write_text(good_app)

    def test_apk_helper_requires_both_real_outputs_and_checks_packaged_sdk_and_identity(self):
        sdk = self.root / 'sdk'
        tool = sdk / 'build-tools/36.0.0' / ('aapt2.exe' if os.name == 'nt' else 'aapt2')
        tool.parent.mkdir(parents=True)
        tool.touch()
        analyzer = sdk / 'cmdline-tools/latest/bin' / ('apkanalyzer.bat' if os.name == 'nt' else 'apkanalyzer')
        analyzer.parent.mkdir(parents=True)
        analyzer.touch()
        with patch.dict(os.environ, {'ANDROID_HOME': str(sdk)}):
            with self.assertRaisesRegex(AssertionError, 'Missing actual gitlabDebug APK'):
                verify_generated_apks(self.root)
            apks = self.root / 'build/app/outputs/flutter-apk'
            apks.mkdir(parents=True)
            (apks / 'app-gitlab-debug.apk').touch()
            def badging(command, **kwargs):
                if command[1:3] == ['dex', 'code']:
                    method = command[command.index('--method') + 1]
                    return subprocess.CompletedProcess(command, 0, stdout=f'.method public {method}\n.registers 3\n.end method\n')
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

            def broken_dex(command, **kwargs):
                if command[1:3] == ['dex', 'code']:
                    return subprocess.CompletedProcess(command, 0, stdout='')
                return badging(command, **kwargs)
            with patch.object(subprocess, 'run', side_effect=broken_dex):
                with self.assertRaisesRegex(AssertionError, 'missing compiled AgentRunService'):
                    verify_generated_apks(self.root)
            def missing_dex(command, **kwargs):
                if command[1:3] == ['dex', 'code']:
                    raise subprocess.CalledProcessError(1, command, stderr='missing or invalid DEX')
                return badging(command, **kwargs)
            with patch.object(subprocess, 'run', side_effect=missing_dex):
                with self.assertRaises(subprocess.CalledProcessError):
                    verify_generated_apks(self.root)


if __name__ == '__main__':
    unittest.main()
