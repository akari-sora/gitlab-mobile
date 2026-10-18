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

import android_signing

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


# Links from other apps go through LinkActivity, a translucent trampoline that
# forwards one https URL to the launcher activity in the app's own task. Only
# gitlab.com can be declared ahead of time; Android 12+ hands it over only after
# the user allows it in the app's "open by default" settings. Flutter's own
# deep linking stays off: app_links delivers the URL, and the route-name
# handling would otherwise push a route the app does not define.
LINK_ACTIVITY_NAME = '.LinkActivity'
LINK_HOSTS = ('gitlab.com',)
DEEP_LINKING_META = 'flutter_deeplinking_enabled'


def _launcher_activity(application: ET.Element) -> ET.Element | None:
    for candidate in application.findall('activity'):
        for intent in candidate.findall('intent-filter'):
            actions = [node.get(_android_attr('name')) for node in intent.findall('action')]
            if 'android.intent.action.MAIN' in actions:
                return candidate
    return None


def register_incoming_links_android(root: ET.Element) -> None:
    application = root.find('application')
    if application is None:
        raise RuntimeError('Unknown Android template: application missing.')
    launcher = _launcher_activity(application)
    if launcher is None:
        return
    meta = next((node for node in launcher.findall('meta-data')
                 if node.get(_android_attr('name')) == DEEP_LINKING_META), None)
    if meta is None:
        meta = ET.SubElement(launcher, 'meta-data', {_android_attr('name'): DEEP_LINKING_META})
    meta.set(_android_attr('value'), 'false')
    for existing in application.findall('activity'):
        if existing.get(_android_attr('name')) == LINK_ACTIVITY_NAME:
            application.remove(existing)
    activity = ET.SubElement(application, 'activity', {
        _android_attr('name'): LINK_ACTIVITY_NAME,
        _android_attr('exported'): 'true',
        _android_attr('excludeFromRecents'): 'true',
        _android_attr('noHistory'): 'true',
        _android_attr('taskAffinity'): '',
        _android_attr('theme'): '@android:style/Theme.Translucent.NoTitleBar',
    })
    view = ET.SubElement(activity, 'intent-filter')
    ET.SubElement(view, 'action', {_android_attr('name'): 'android.intent.action.VIEW'})
    ET.SubElement(view, 'category', {_android_attr('name'): 'android.intent.category.DEFAULT'})
    ET.SubElement(view, 'category', {_android_attr('name'): 'android.intent.category.BROWSABLE'})
    ET.SubElement(view, 'data', {_android_attr('scheme'): 'https'})
    for host in LINK_HOSTS:
        ET.SubElement(view, 'data', {_android_attr('host'): host})
    share = ET.SubElement(activity, 'intent-filter')
    ET.SubElement(share, 'action', {_android_attr('name'): 'android.intent.action.SEND'})
    ET.SubElement(share, 'category', {_android_attr('name'): 'android.intent.category.DEFAULT'})
    ET.SubElement(share, 'data', {_android_attr('mimeType'): 'text/plain'})


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
    register_incoming_links_android(root)
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


FLAVORS_BEGIN = '    // GITLAB_MOBILE_FLAVORS_BEGIN'
FLAVORS_END = '    // GITLAB_MOBILE_FLAVORS_END'
FLAVORS = f'''{FLAVORS_BEGIN}
    // Distribution channels (Flutter's appFlavor). Both keep the application
    // ID; they differ only in how the app is updated. Build with --flavor.
    flavorDimensions += "distribution"
    productFlavors {{
        create("gitlab") {{
            dimension = "distribution"
        }}
        create("play") {{
            dimension = "distribution"
        }}
    }}
{FLAVORS_END}
'''


def configure_flavors(path: Path) -> bool:
    """Adds the gitlab and play product flavors after the managed signing block."""
    text = path.read_text(encoding='utf-8')
    if text.count(FLAVORS_BEGIN) or text.count(FLAVORS_END):
        if text.count(FLAVORS_BEGIN) != 1 or text.count(FLAVORS_END) != 1:
            raise RuntimeError('Incomplete Android flavor markers; review the Gradle file manually.')
        block = text[text.index(FLAVORS_BEGIN):text.index(FLAVORS_END) + len(FLAVORS_END)]
        if block != FLAVORS.rstrip('\n'):
            raise RuntimeError('Stale managed Android flavors; review and refresh the owned block.')
        return False
    if 'productFlavors' in text or 'flavorDimensions' in text:
        raise RuntimeError('Unknown Android Gradle template: flavors already defined.')
    anchor = android_signing.END_CONFIG + '\n'
    if text.count(anchor) != 1:
        raise RuntimeError('Configure Android signing before the flavors.')
    path.write_text(text.replace(anchor, anchor + FLAVORS, 1), encoding='utf-8')
    return True


KOTLIN_PACKAGE = 'io/gitlabmobile/gitlab_mobile'
TEMPLATE_MAIN_ACTIVITY = '''package io.gitlabmobile.gitlab_mobile

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
'''
UPDATE_ONLY_MAIN_ACTIVITY = '''package io.gitlabmobile.gitlab_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Each distribution flavor ships its own AppUpdateChannel.
        AppUpdateChannel.register(flutterEngine, this)
    }
}
'''
MAIN_ACTIVITY = '''package io.gitlabmobile.gitlab_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Each distribution flavor ships its own AppUpdateChannel.
        AppUpdateChannel.register(flutterEngine, this)
        LinkChannel.register(flutterEngine, this)
    }
}
'''
LINK_CHANNEL = 'io.gitlabmobile/links'

# Both flavors: the trampoline for links from other apps, and the channel that
# opens the app's "open by default" settings.
LINK_ACTIVITY = r'''package io.gitlabmobile.gitlab_mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Takes a gitlab.com link tapped in another app, or the first https URL in
 * text shared to this app, and hands it to MainActivity in the app's own task,
 * where app_links reports it to Dart. Starting here keeps a second Flutter
 * engine out of the sending app's task. Nothing but one https URL is passed on.
 */
class LinkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        linkFrom(intent)?.let { link ->
            startActivity(
                Intent(this, MainActivity::class.java)
                    .setAction(Intent.ACTION_VIEW)
                    .setData(link)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                    )
            )
        }
        finish()
    }

    companion object {
        private const val MAX_LENGTH = 2048
        private val HTTPS = Regex("""https://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+""")

        fun linkFrom(intent: Intent?): Uri? {
            val text = when (intent?.action) {
                Intent.ACTION_VIEW -> intent.dataString
                Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                else -> null
            } ?: return null
            val match = HTTPS.find(text)?.value?.trimEnd('.', ',', ';', ':', '!', '?', ')', ']', '\'')
                ?: return null
            if (match.length > MAX_LENGTH) return null
            val uri = Uri.parse(match)
            return if (uri.scheme == "https" && !uri.host.isNullOrEmpty()) uri else null
        }
    }
}

object LinkChannel {
    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "io.gitlabmobile/links").setMethodCallHandler { call, result ->
            when (call.method) {
                "openByDefaultSettings" -> result.success(openByDefaultSettings(activity))
                else -> result.notImplemented()
            }
        }
    }

    /** Android 12+ lists gitlab.com there for the user to allow; older versions open the app's details. */
    private fun openByDefaultSettings(activity: Activity): Boolean {
        val target = Uri.parse("package:${activity.packageName}")
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Intent(Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS, target)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, target)
        }
        return try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
'''
UPDATE_CHANNEL = 'io.gitlabmobile/app_update'

# GitLab channel: hands an APK the app downloaded and verified into
# cache/updates/ to the system package installer. The user confirms the install
# in the system UI; Android first asks them to allow installs from this app.
GITLAB_UPDATE_CHANNEL = f'''package io.gitlabmobile.gitlab_mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Serves only cache/updates/ (res/xml/update_paths.xml). */
class UpdateFileProvider : FileProvider()

object AppUpdateChannel {{
    fun register(engine: FlutterEngine, activity: Activity) {{
        MethodChannel(engine.dartExecutor.binaryMessenger, "{UPDATE_CHANNEL}").setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "installApk" -> result.success(install(activity, call.argument<String>("path")))
                else -> result.notImplemented()
            }}
        }}
    }}

    private fun install(activity: Activity, path: String?): String {{
        val updates = File(activity.cacheDir, "updates").canonicalFile
        val apk = path?.let {{ File(it).canonicalFile }} ?: return "invalid"
        if (apk.parentFile != updates || !apk.isFile || !apk.name.endsWith(".apk")) return "invalid"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()) {{
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${{activity.packageName}}")))
            return "needsPermission"
        }}
        val uri = FileProvider.getUriForFile(activity, "${{activity.packageName}}.updates", apk)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {{
            activity.startActivity(intent)
            "started"
        }} catch (_: ActivityNotFoundException) {{
            "unavailable"
        }}
    }}
}}
'''

GITLAB_MANIFEST = '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- GitLab channel only: hands a verified update APK to the system installer. -->
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
    <application>
        <provider
            android:name=".UpdateFileProvider"
            android:authorities="${applicationId}.updates"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/update_paths" />
        </provider>
    </application>
</manifest>
'''

GITLAB_UPDATE_PATHS = '''<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="updates" path="updates/" />
</paths>
'''

# Play channel: Google Play's in-app updates (flexible). No install permission:
# Play policy forbids an app from updating itself any other way.
PLAY_UPDATE_CHANNEL = f'''package io.gitlabmobile.gitlab_mobile

import android.app.Activity
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object AppUpdateChannel {{
    private const val REQUEST_CODE = 4317

    fun register(engine: FlutterEngine, activity: Activity) {{
        val manager = AppUpdateManagerFactory.create(activity)
        MethodChannel(engine.dartExecutor.binaryMessenger, "{UPDATE_CHANNEL}").setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "checkPlay" -> manager.appUpdateInfo
                    .addOnSuccessListener {{ info ->
                        result.success(mapOf(
                            "available" to (info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
                                info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)),
                            "versionCode" to info.availableVersionCode(),
                            "downloaded" to (info.installStatus() == InstallStatus.DOWNLOADED),
                        ))
                    }}
                    .addOnFailureListener {{ result.error("play", it.message, null) }}
                "startPlayUpdate" -> manager.appUpdateInfo
                    .addOnSuccessListener {{ info ->
                        val ready = info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
                            info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)
                        result.success(ready && manager.startUpdateFlowForResult(
                            info, activity, AppUpdateOptions.defaultOptions(AppUpdateType.FLEXIBLE), REQUEST_CODE))
                    }}
                    .addOnFailureListener {{ result.error("play", it.message, null) }}
                "completePlayUpdate" -> manager.completeUpdate()
                    .addOnSuccessListener {{ result.success(true) }}
                    .addOnFailureListener {{ result.error("play", it.message, null) }}
                else -> result.notImplemented()
            }}
        }}
    }}
}}
'''

UPDATE_DEPENDENCIES_BEGIN = '// GITLAB_MOBILE_UPDATE_DEPENDENCIES_BEGIN'
UPDATE_DEPENDENCIES_END = '// GITLAB_MOBILE_UPDATE_DEPENDENCIES_END'
UPDATE_DEPENDENCIES = f'''{UPDATE_DEPENDENCIES_BEGIN}
dependencies {{
    "gitlabImplementation"("androidx.core:core:1.13.1")
    "playImplementation"("com.google.android.play:app-update:2.1.0")
}}
{UPDATE_DEPENDENCIES_END}
'''


def configure_update_channels(app: Path) -> None:
    """Writes each flavor's AppUpdateChannel, the shared LinkActivity, and the MainActivity that registers both channels."""
    gradle = app / 'build.gradle.kts'
    text = gradle.read_text(encoding='utf-8')
    if text.count(UPDATE_DEPENDENCIES_BEGIN) or text.count(UPDATE_DEPENDENCIES_END):
        block = text[text.index(UPDATE_DEPENDENCIES_BEGIN):text.index(UPDATE_DEPENDENCIES_END) + len(UPDATE_DEPENDENCIES_END)]
        if text.count(UPDATE_DEPENDENCIES_BEGIN) != 1 or block != UPDATE_DEPENDENCIES.rstrip('\n'):
            raise RuntimeError('Stale managed update dependencies; review and refresh the owned block.')
    else:
        if FLAVORS_BEGIN not in text:
            raise RuntimeError('Configure the flavors before the update channels.')
        gradle.write_text(text.rstrip('\n') + '\n\n' + UPDATE_DEPENDENCIES, encoding='utf-8')
    activity = app / 'src/main/kotlin' / KOTLIN_PACKAGE / 'MainActivity.kt'
    current = activity.read_text(encoding='utf-8')
    if current not in (TEMPLATE_MAIN_ACTIVITY, UPDATE_ONLY_MAIN_ACTIVITY, MAIN_ACTIVITY):
        raise RuntimeError('Unknown MainActivity template; review before registering the update channel.')
    activity.write_text(MAIN_ACTIVITY, encoding='utf-8')
    files = {
        f'src/main/kotlin/{KOTLIN_PACKAGE}/LinkActivity.kt': LINK_ACTIVITY,
        f'src/gitlab/kotlin/{KOTLIN_PACKAGE}/AppUpdateChannel.kt': GITLAB_UPDATE_CHANNEL,
        'src/gitlab/AndroidManifest.xml': GITLAB_MANIFEST,
        'src/gitlab/res/xml/update_paths.xml': GITLAB_UPDATE_PATHS,
        f'src/play/kotlin/{KOTLIN_PACKAGE}/AppUpdateChannel.kt': PLAY_UPDATE_CHANNEL,
    }
    for name, content in files.items():
        path = app / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')


def configure_android(folder: Path) -> None:
    harden_android(folder)
    android_signing.configure_gradle(folder / 'app/build.gradle.kts')
    configure_flavors(folder / 'app/build.gradle.kts')
    configure_update_channels(folder / 'app')


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
            configure_android(template / 'android')
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
