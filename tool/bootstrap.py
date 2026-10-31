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
import l10n

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


# The store name (lib/core/brand.dart). "GitLab" stays out of it: GitLab's
# trademark guidelines and Play's impersonation policy expect an independent
# client to carry its own name.
APP_NAME = 'Mergeline'
# Play gets its own application ID without the trademark. The GitLab channel
# keeps the original ID so installed previews keep updating in place.
PLAY_APPLICATION_ID = 'app.mergeline'

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
            return
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


def locales_config() -> str:
    """Android 13+ lists these in Settings › Apps › Mergeline › Language."""
    locales = ''.join(f'    <locale android:name="{tag}" />\n' for tag, *_ in l10n.LANGUAGES)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<locale-config xmlns:android="{ANDROID}">\n{locales}</locale-config>\n')


def ios_localizations() -> list[str]:
    """The app's languages as iOS localization names, for CFBundleLocalizations."""
    names = {'zh-TW': 'zh-Hant', 'zh-CN': 'zh-Hans'}
    return [names.get(tag, tag) for tag, *_ in l10n.LANGUAGES]


def register_localizations_ios(folder: Path) -> None:
    """Lets iOS offer the app's languages (Settings › Mergeline › Language)."""
    path = folder / 'Runner/Info.plist'
    if not path.is_file():
        return
    tree = ET.parse(path)
    plist = tree.getroot().find('dict')
    if plist is None:
        raise RuntimeError('Unknown iOS template: Info.plist dict missing.')
    children = list(plist)
    for index, node in enumerate(children[:-1]):
        if node.tag == 'key' and node.text == 'CFBundleLocalizations':
            plist.remove(children[index + 1])
            plist.remove(node)
            break
    plist.append(_plist_key('CFBundleLocalizations'))
    array = ET.SubElement(plist, 'array')
    for name in ios_localizations():
        ET.SubElement(array, 'string').text = name
    ET.indent(tree, space='\t')
    tree.write(path, encoding='utf-8', xml_declaration=True)


def harden_android(folder: Path) -> None:
    manifest = folder / 'app/src/main/AndroidManifest.xml'
    tree = ET.parse(manifest)
    root = tree.getroot()
    agent_files = agent_run_files()
    _check_agent_template(folder / 'app', root, agent_files)
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
                       'localeConfig': '@xml/locales_config',
                       'label': APP_NAME}.items():
        application.set(f'{{{ANDROID}}}{key}', value)
    for activity in application.findall('activity'):
        if f'{{{ANDROID}}}label' in activity.attrib:
            activity.set(f'{{{ANDROID}}}label', APP_NAME)
    register_oauth_android(root)
    register_incoming_links_android(root)
    for name in AGENT_PERMISSIONS:
        if not any(node.get(_android_attr('name')) == name for node in root.findall('uses-permission')):
            ET.SubElement(root, 'uses-permission', {_android_attr('name'): name})
    if application.find('service') is None:
        ET.SubElement(application, 'service', AGENT_SERVICE_ATTRIBUTES)
    ET.indent(tree, space='    ')
    _write_xml(manifest, tree)
    resource = folder / 'app/src/main/res/xml'
    resource.mkdir(parents=True, exist_ok=True)
    excludes = ''.join(f'<exclude domain="{domain}" path="." />' for domain in
                       ('root', 'file', 'database', 'sharedpref', 'external'))
    _write_text(resource / 'locales_config.xml', locales_config())
    _write_text(resource / 'backup_rules.xml', f'<full-backup-content>{excludes}</full-backup-content>\n')
    _write_text(resource / 'data_extraction_rules.xml',
        '<data-extraction-rules><cloud-backup disableIfNoEncryptionCapabilities="true">'
        f'{excludes}</cloud-backup><device-transfer>{excludes}</device-transfer></data-extraction-rules>\n')
    _write_managed_files(folder / 'app', agent_files)
    _transparent_system_bars(folder)


FLAVORS_BEGIN = '    // GITLAB_MOBILE_FLAVORS_BEGIN'
FLAVORS_END = '    // GITLAB_MOBILE_FLAVORS_END'
FLAVORS = f'''{FLAVORS_BEGIN}
    // Distribution channels (Flutter's appFlavor), updated differently. The
    // GitLab channel keeps the original application ID so installed previews
    // update in place; Play has its own. Build with --flavor.
    flavorDimensions += "distribution"
    productFlavors {{
        create("gitlab") {{
            dimension = "distribution"
        }}
        create("play") {{
            dimension = "distribution"
            applicationId = "{PLAY_APPLICATION_ID}"
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


# The Flutter 3.47.2 Android template already targets Java and Kotlin 17.
# Keep its AGP 9 compilerOptions and Flutter-owned SDK values intact.
NOTIFICATION_DESUGAR_BEGIN = '        // GITLAB_MOBILE_NOTIFICATION_DESUGAR_BEGIN'
NOTIFICATION_DESUGAR_END = '        // GITLAB_MOBILE_NOTIFICATION_DESUGAR_END'
NOTIFICATION_DESUGAR = f'''{NOTIFICATION_DESUGAR_BEGIN}
        isCoreLibraryDesugaringEnabled = true
{NOTIFICATION_DESUGAR_END}
'''
NOTIFICATION_DEPENDENCIES_BEGIN = '// GITLAB_MOBILE_NOTIFICATION_DEPENDENCIES_BEGIN'
NOTIFICATION_DEPENDENCIES_END = '// GITLAB_MOBILE_NOTIFICATION_DEPENDENCIES_END'
NOTIFICATION_DEPENDENCIES = f'''{NOTIFICATION_DEPENDENCIES_BEGIN}
dependencies {{
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}}
{NOTIFICATION_DEPENDENCIES_END}
'''
_JAVA_COMPILE_BLOCK = '''    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
'''
_KOTLIN_COMPILER_BLOCK = '''kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}'''


def configure_notification_gradle(path: Path) -> bool:
    """Upgrade only the known pinned template or an exact managed version."""
    text = path.read_text(encoding='utf-8')
    if (text.count(_KOTLIN_COMPILER_BLOCK) != 1 or 'kotlinOptions' in text or
            any(text.count(value) != 1 for value in (
                'compileSdk = flutter.compileSdkVersion',
                'minSdk = flutter.minSdkVersion',
                'targetSdk = flutter.targetSdkVersion'))):
        raise RuntimeError('Unknown Android SDK or Kotlin compiler template.')
    if text.count(_JAVA_COMPILE_BLOCK) != 1:
        raise RuntimeError('Unknown Android Java compileOptions template.')
    markers = (NOTIFICATION_DESUGAR_BEGIN, NOTIFICATION_DESUGAR_END,
               NOTIFICATION_DEPENDENCIES_BEGIN, NOTIFICATION_DEPENDENCIES_END)
    counts = tuple(text.count(marker) for marker in markers)
    if counts == (1, 1, 1, 1):
        options = text[text.index(markers[0]):text.index(markers[1]) + len(markers[1])]
        dependencies = text[text.index(markers[2]):text.index(markers[3]) + len(markers[3])]
        if (options != NOTIFICATION_DESUGAR.rstrip('\n') or
                dependencies != NOTIFICATION_DEPENDENCIES.rstrip('\n') or
                text.count('isCoreLibraryDesugaringEnabled') != 1 or
                text.count('coreLibraryDesugaring(') != 1 or
                _JAVA_COMPILE_BLOCK + NOTIFICATION_DESUGAR + '    }' not in text):
            raise RuntimeError('Stale managed notification Gradle configuration.')
        return False
    if counts != (0, 0, 0, 0):
        raise RuntimeError('Incomplete notification Gradle markers.')
    if ('isCoreLibraryDesugaringEnabled' in text or
            'coreLibraryDesugaring' in text or
            _JAVA_COMPILE_BLOCK + '    }' not in text):
        raise RuntimeError('Unknown notification Gradle configuration.')
    text = text.replace(_JAVA_COMPILE_BLOCK, _JAVA_COMPILE_BLOCK + NOTIFICATION_DESUGAR, 1)
    text = text.rstrip('\n') + '\n\n' + NOTIFICATION_DEPENDENCIES
    path.write_text(text, encoding='utf-8')
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
LINKS_MAIN_ACTIVITY = '''package io.gitlabmobile.gitlab_mobile

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
# A FragmentActivity, because local_auth (the app lock) shows its prompt
# through androidx.biometric fragments.
FRAGMENT_MAIN_ACTIVITY = '''package io.gitlabmobile.gitlab_mobile

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Each distribution flavor ships its own AppUpdateChannel.
        AppUpdateChannel.register(flutterEngine, this)
        LinkChannel.register(flutterEngine, this)
    }
}
'''
MAIN_ACTIVITY = FRAGMENT_MAIN_ACTIVITY.replace(
    '        LinkChannel.register(flutterEngine, this)\n',
    '        LinkChannel.register(flutterEngine, this)\n'
    '        AgentRunsChannel.register(flutterEngine, this)\n',
).replace('    }\n}\n', '''    }

    override fun onResume() {
        super.onResume()
        AgentRunsChannel.resumed(this)
    }

    override fun onPause() {
        AgentRunsChannel.paused(this)
        super.onPause()
    }

    override fun onDestroy() {
        AgentRunsChannel.activityDestroyed(this)
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AgentRunsChannel.engineDetached(flutterEngine, this)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
''')

AGENT_CHANNEL = 'io.gitlabmobile/agent_runs'
AGENT_PERMISSIONS = (
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
    'android.permission.POST_NOTIFICATIONS',
)
AGENT_SERVICE_ATTRIBUTES = {
    _android_attr('name'): '.AgentRunService',
    _android_attr('exported'): 'false',
    _android_attr('foregroundServiceType'): 'dataSync',
    _android_attr('stopWithTask'): 'true',
}
AGENT_STRINGS = {
    'ai_run_channel_name': 'aiRunChannelName',
    'ai_run_service_title': 'aiRunServiceTitle',
    'ai_run_service_text': 'aiRunServiceText',
}
AGENT_ICON = f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="{ANDROID}" android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M12,2L14.5,9.5L22,12L14.5,14.5L12,22L9.5,14.5L2,12L9.5,9.5Z" />
</vector>
'''

# One main-looper owner; no engine, storage, scheduler or network in the service.
# Expected failures cross the channel as bounded codes, never exception text.
AGENT_RUN_SERVICE = r'''package io.gitlabmobile.gitlab_mobile

// Generated by tool/bootstrap.py. The entire file is managed.
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import java.lang.ref.WeakReference
import java.util.UUID

class AgentRunService : Service() {
    internal var permitId: String? = null
        private set
    private var foregroundStarted = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A stale-only getService instance can stop immediately. A separately
        // queued foreground start must discharge its obligation in its own callback.
        if (intent?.action == ACTION_STOP_ALL) {
            AgentRunsChannel.notificationStop(this)
            return START_NOT_STICKY
        }
        // Every start must discharge startForegroundService's obligation FIRST, even
        // after release/cancellation or for a stale/null intent. STARTING stops only
        // revoke authority; they never call stopService/stopSelf. After promotion,
        // stop only if no current permit exists: a stale intent must not stop a
        // newer pending start sharing this service. Bind only a matching start,
        // once per instance; onCreate/old onDestroy cannot adopt a newer permit.
        AgentRunsChannel.startCommandReceived(intent?.getStringExtra(EXTRA_PERMIT_ID))
        val failure = try {
            promote(AgentRunsChannel.startProgress(intent?.getStringExtra(EXTRA_PERMIT_ID)))
            null
        } catch (_: SecurityException) {
            "security_exception"
        } catch (_: IllegalStateException) {
            "start_denied"
        } catch (_: RuntimeException) {
            "start_failed"
        }
        if (failure != null) AgentRunsChannel.serviceStartFailed(this, intent?.getStringExtra(EXTRA_PERMIT_ID), failure)
        else AgentRunsChannel.serviceStarted(this, intent?.getStringExtra(EXTRA_PERMIT_ID))
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        AgentRunsChannel.serviceTimedOut(this)
    }

    override fun onDestroy() {
        AgentRunsChannel.serviceEnded(this, "service_destroyed")
        super.onDestroy()
    }

    internal fun promote(progress: RunProgress) {
        val notification = notification(progress)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        foregroundStarted = true
    }

    internal fun bindPermit(id: String): Boolean {
        if (permitId == null) permitId = id
        return permitId == id
    }

    internal fun update(progress: RunProgress) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(progress))
    }

    internal fun removeForeground() {
        try {
            if (foregroundStarted) stopForeground(STOP_FOREGROUND_REMOVE)
        } finally {
            foregroundStarted = false
        }
    }

    internal fun stopNative() {
        try {
            removeForeground()
        } finally {
            stopSelf()
        }
    }

    private fun notification(progress: RunProgress): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                NOTIFICATION_CHANNEL, getString(R.string.ai_run_channel_name), NotificationManager.IMPORTANCE_LOW
            ).apply { lockscreenVisibility = Notification.VISIBILITY_PRIVATE })
        }
        fun builder(): Notification.Builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            Notification.Builder(this)
        }
        // Public content always comes from safe resources, even with a Dart language override.
        val publicVersion = builder().setSmallIcon(R.drawable.ic_ai_runs)
            .setContentTitle(getString(R.string.ai_run_service_title))
            .setContentText(getString(R.string.ai_run_service_text))
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        val ongoing = builder().setSmallIcon(R.drawable.ic_ai_runs)
            .setContentTitle(progress.title ?: getString(R.string.ai_run_service_title))
            .setContentText(progress.text ?: getString(R.string.ai_run_service_text))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
        progress.stopAllLabel?.let { label ->
            val stopIntent = Intent(this, AgentRunService::class.java).setAction(ACTION_STOP_ALL)
            val stop = PendingIntent.getService(this, STOP_REQUEST_CODE, stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val action = Notification.Action.Builder(null, label, stop)
            if (Build.VERSION.SDK_INT >= 31) action.setAuthenticationRequired(false)
            val stopAction = action.build()
            publicVersion.addAction(stopAction)
            ongoing.addAction(stopAction)
        }
        return ongoing.setPublicVersion(publicVersion.build()).build()
    }

    companion object {
        const val NOTIFICATION_ID = 6100
        const val NOTIFICATION_CHANNEL = "ai_runs_v1"
        internal const val EXTRA_PERMIT_ID = "permitId"
        internal const val ACTION_STOP_ALL = "io.gitlabmobile.agent_runs.STOP_ALL"
        private const val STOP_REQUEST_CODE = 6101
    }
}

internal data class RunProgress(val workCount: Int, val step: Int, val title: String?, val text: String?, val stopAllLabel: String?)

// Only a separately registered debug source-set adapter implements these hooks.
internal interface AgentRunTestEvents : java.io.Closeable {
    fun wrap(result: MethodChannel.Result): MethodChannel.Result
    fun invalidated(deliver: () -> Unit)
    fun taskBackInvoked()
}

internal object AgentRunsChannel {
    private const val CHANNEL = "io.gitlabmobile/agent_runs"
    private const val MAX_NONCES = 4096
    private const val MAX_OP_SEQ = 9007199254740991L
    private const val MAX_ID_LENGTH = 128
    private const val MAX_TITLE_LENGTH = 160
    private const val MAX_TEXT_LENGTH = 256
    private val idPattern = Regex("[A-Za-z0-9._:-]+")
    private enum class State { STARTING, ACTIVE, RELEASED, INVALIDATED }
    private class Permit(val createdRequestId: String, val createdOpSeq: Long, var progress: RunProgress) {
        val id: String = UUID.randomUUID().toString()
        var latestStartSeq: Long = createdOpSeq
        var latestStartRequestId: String = createdRequestId
        var state = State.STARTING
        val nonces = HashSet<String>()
        val pending = mutableListOf<PendingStart>()
    }
    private data class PendingStart(val requestId: String, val opSeq: Long, val result: MethodChannel.Result)
    private var current: Permit? = null
    private var service: AgentRunService? = null
    private val pendingForegroundStarts = HashSet<String>()
    private var deferredStop: AgentRunService? = null
    private var channel: MethodChannel? = null
    private var owner: Activity? = null
    private var visible: Activity? = null
    private var registration: Any? = null
    private var engineReference: WeakReference<FlutterEngine>? = null
    private var engineListener: FlutterEngine.EngineLifecycleListener? = null
    private var testEvents: AgentRunTestEvents? = null
    private var lastOpSeq = 0L
    private var cleanupFailed = false

    private fun mainThread() = check(Looper.myLooper() == Looper.getMainLooper())
    private fun reply(status: String, vararg fields: Pair<String, Any>): Map<String, Any> =
        mapOf("version" to 1, "status" to status, *fields)
    private fun reject(result: MethodChannel.Result, reason: String) =
        result.success(reply("rejected", "reason" to reason))
    private fun number(args: Map<*, *>, key: String, min: Long, max: Long): Long? {
        val value = args[key]
        if (value !is Int && value !is Long) return null
        return (value as Number).toLong().takeIf { it in min..max }
    }
    private fun id(args: Map<*, *>, key: String): String? = (args[key] as? String)?.takeIf {
        it.length in 1..MAX_ID_LENGTH && idPattern.matches(it)
    }
    private fun progress(args: Map<*, *>): RunProgress? {
        val count = number(args, "workCount", 1, 3)?.toInt() ?: return null
        val step = number(args, "step", 0, 1000000)?.toInt() ?: return null
        for ((key, limit) in listOf("title" to MAX_TITLE_LENGTH, "text" to MAX_TEXT_LENGTH, "stopAllLabel" to MAX_TITLE_LENGTH)) {
            val value = args[key]
            if (value != null && (value !is String || value.isBlank() || value.length > limit ||
                    value.any { it < ' ' || it == '\u007f' })) return null
        }
        return RunProgress(count, step, args["title"] as? String, args["text"] as? String, args["stopAllLabel"] as? String)
    }
    private fun sequence(args: Map<*, *>, result: MethodChannel.Result): Long? {
        val seq = number(args, "opSeq", 1, MAX_OP_SEQ)
        if (seq == null) { reject(result, "invalid_arguments"); return null }
        if (seq <= lastOpSeq) {
            result.success(reply("rejected", "reason" to "stale_operation", "opSeqFloor" to lastOpSeq))
            return null
        }
        // Record cancellation before touching the service; a late lower-sequence start stays dead.
        lastOpSeq = seq
        return seq
    }

    fun register(engine: FlutterEngine, activity: Activity) {
        mainThread()
        // A new channel binding cannot inherit authority from an old Dart engine,
        // even if Android reuses the same Activity instance.
        owner?.let { activityDestroyed(it) }
        // The optional debug class installs an inert registration channel. Only
        // C8's explicit Dart QA entry activates it; release has no QA handler.
        testEvents = try {
            Class.forName("io.gitlabmobile.gitlab_mobile.AgentRunQaAdapter")
                .getDeclaredConstructor(BinaryMessenger::class.java)
                .newInstance(engine.dartExecutor.binaryMessenger) as AgentRunTestEvents
        } catch (_: ClassNotFoundException) {
            null
        }
        val binding = Any()
        registration = binding
        owner = activity
        engineReference = WeakReference(engine)
        val listener = object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() {
                if (registration === binding) stop("activity_destroyed")
            }
            override fun onEngineWillDestroy() {
                // FlutterEngine is iterating its listener set here; do not remove
                // this listener synchronously from inside the callback.
                activityDestroyed(activity, binding, engineDestroying = true)
            }
        }
        engineListener = listener
        engine.addEngineLifecycleListener(listener)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { bridge ->
            bridge.setMethodCallHandler { call, rawResult ->
                mainThread()
                val result = testEvents?.wrap(rawResult) ?: rawResult
                if (owner !== activity || registration !== binding) {
                    reject(result, "unavailable")
                } else {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) reject(result, "invalid_arguments") else when (call.method) {
                        "startRuns" -> start(activity, args, result)
                        "updateProgress" -> update(args, result)
                        "releaseRuns" -> release(args, result)
                        "stopAll" -> if (validKeys(args, setOf("opSeq"), result) && sequence(args, result) != null) {
                            val reason = if (stop("user_stop")) null else "cleanup_failed"
                            result.success(if (reason == null) reply("stopped") else reply("rejected", "reason" to reason))
                        }
                        "acquireContinuation" -> acquire(args, result)
                        "moveTaskToBack" -> moveBack(activity, args, result)
                        else -> result.notImplemented()
                    }
                }
            }
        }
    }

    private fun validKeys(args: Map<*, *>, allowed: Set<String>, result: MethodChannel.Result): Boolean {
        if (args.keys.any { it !in allowed }) { reject(result, "invalid_arguments"); return false }
        return true
    }
    private fun moveBack(activity: Activity, args: Map<*, *>, result: MethodChannel.Result) {
        if (!validKeys(args, setOf("opSeq"), result)) return
        sequence(args, result) ?: return
        if (visible !== activity || activity.isFinishing || activity.isDestroyed) {
            reject(result, "foreground_required"); return
        }
        val moved = try {
            testEvents?.taskBackInvoked()
            activity.moveTaskToBack(true)
        } catch (_: SecurityException) {
            reject(result, "security_exception"); return
        } catch (_: RuntimeException) {
            reject(result, "move_failed"); return
        }
        result.success(reply(if (moved) "moved" else "not_moved"))
    }
    fun resumed(activity: Activity) { mainThread(); if (owner === activity) visible = activity }
    fun paused(activity: Activity) { mainThread(); if (visible === activity) visible = null }
    fun engineDetached(engine: FlutterEngine, activity: Activity) {
        mainThread()
        if (engineReference?.get() !== engine) return
        activityDestroyed(activity)
    }
    fun activityDestroyed(activity: Activity, expectedBinding: Any? = registration, engineDestroying: Boolean = false) {
        mainThread()
        if (owner !== activity || registration !== expectedBinding) return
        stop("activity_destroyed")
        visible = null
        owner = null
        registration = null
        val engine = engineReference?.get()
        val listener = engineListener
        engineReference = null
        engineListener = null
        if (!engineDestroying && listener != null) engine?.removeEngineLifecycleListener(listener)
        channel?.setMethodCallHandler(null)
        channel = null
        testEvents?.close()
        testEvents = null
    }

    private fun start(activity: Activity, args: Map<*, *>, result: MethodChannel.Result) {
        if (!validKeys(args, setOf("opSeq", "startRequestId", "workCount", "step", "title", "text", "stopAllLabel"), result)) return
        val requestId = id(args, "startRequestId")
        val progress = progress(args)
        if (requestId == null || progress == null) { reject(result, "invalid_arguments"); return }
        val seq = sequence(args, result) ?: return
        if (cleanupFailed) { reject(result, "cleanup_failed"); return }
        if (visible !== activity || activity.isFinishing || activity.isDestroyed) {
            reject(result, "foreground_required"); return
        }
        var permit = current
        if (permit != null) {
            permit.latestStartSeq = seq
            permit.latestStartRequestId = requestId
            permit.progress = progress
            if (permit.state == State.ACTIVE) {
                try {
                    val running = service ?: throw IllegalStateException()
                    running.update(progress)
                } catch (_: RuntimeException) {
                    stop("notification_failed")
                    reject(result, "notification_failed")
                    return
                }
                active(result, permit, requestId, seq)
            } else {
                permit.pending.add(PendingStart(requestId, seq, result))
            }
            return
        }
        permit = Permit(requestId, seq, progress)
        permit.pending.add(PendingStart(requestId, seq, result))
        current = permit
        val intent = Intent(activity, AgentRunService::class.java).putExtra(AgentRunService.EXTRA_PERMIT_ID, permit.id)
        pendingForegroundStarts.add(permit.id)
        try {
            val component = if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent) else activity.startService(intent)
            if (component == null) {
                pendingForegroundStarts.remove(permit.id)
                stop("start_failed")
            }
        } catch (_: SecurityException) {
            pendingForegroundStarts.remove(permit.id)
            stop("security_exception")
        } catch (_: IllegalStateException) {
            // Includes ForegroundServiceStartNotAllowedException on API 31+.
            pendingForegroundStarts.remove(permit.id)
            stop("start_denied")
        } catch (_: RuntimeException) {
            pendingForegroundStarts.remove(permit.id)
            stop("start_failed")
        }
    }

    private fun active(result: MethodChannel.Result, permit: Permit, requestId: String, seq: Long) {
        result.success(reply("active", "permitId" to permit.id, "startRequestId" to requestId, "opSeq" to seq))
    }

    internal fun startProgress(expectedId: String?): RunProgress =
        current?.takeIf { it.id == expectedId }?.progress ?: RunProgress(1, 0, null, null, null)

    internal fun serviceForTestEvents(): AgentRunService? = service

    fun startCommandReceived(expectedId: String?) {
        mainThread()
        expectedId?.let { pendingForegroundStarts.remove(it) }
    }

    fun notificationStop(instance: AgentRunService) {
        mainThread()
        stop("user_stop", instance)
    }

    fun serviceStartFailed(instance: AgentRunService, expectedId: String?, reason: String) {
        mainThread()
        val permit = current
        if (permit == null) { stopNative(instance); return }
        if (permit.id == expectedId && (instance.permitId == null || instance.permitId == permit.id)) stop(reason, instance)
    }

    fun serviceStarted(instance: AgentRunService, expectedId: String?) {
        mainThread()
        val permit = current
        if (permit == null) {
            stopNative(instance)
            return
        }
        // An obsolete intent must neither revive its permit nor stop a newer one.
        if (permit.id != expectedId) return
        if (!instance.bindPermit(permit.id)) return
        deferredStop = null
        service = instance
        try {
            instance.update(permit.progress)
        } catch (_: RuntimeException) {
            stop("notification_failed")
            return
        }
        permit.state = State.ACTIVE
        // Engine replies are independent of promotion and of each other.
        val pending = permit.pending.toList()
        permit.pending.clear()
        pending.forEach {
            try { active(it.result, permit, it.requestId, it.opSeq) }
            catch (_: RuntimeException) { /* Engine gone; still answer the remaining starts. */ }
        }
    }

    private fun update(args: Map<*, *>, result: MethodChannel.Result) {
        if (!validKeys(args, setOf("opSeq", "permitId", "workCount", "step", "title", "text", "stopAllLabel"), result)) return
        val permitId = id(args, "permitId")
        val progress = progress(args)
        if (permitId == null || progress == null) { reject(result, "invalid_arguments"); return }
        sequence(args, result) ?: return
        val permit = current
        if (permit == null || permit.id != permitId || permit.state != State.ACTIVE) {
            reject(result, "permit_inactive"); return
        }
        try {
            val running = service ?: throw IllegalStateException()
            running.update(progress)
            permit.progress = progress
        } catch (_: RuntimeException) {
            stop("notification_failed")
            reject(result, "notification_failed")
            return
        }
        result.success(reply("updated", "permitId" to permit.id))
    }

    private fun release(args: Map<*, *>, result: MethodChannel.Result) {
        if (!validKeys(args, setOf("opSeq", "permitId", "startRequestId"), result)) return
        val byPermit = args.containsKey("permitId")
        val byRequest = args.containsKey("startRequestId")
        val target = id(args, if (byPermit) "permitId" else "startRequestId")
        if (byPermit == byRequest || target == null) { reject(result, "invalid_arguments"); return }
        sequence(args, result) ?: return
        val permit = current
        if (permit == null) {
            result.success(if (cleanupFailed) reply("rejected", "reason" to "cleanup_failed")
                else reply("released", "didRelease" to false))
            return
        }
        val ownsRequest = permit.createdRequestId == target && permit.latestStartSeq == permit.createdOpSeq
        if ((byPermit && permit.id != target) || (byRequest && !ownsRequest)) {
            result.success(reply("released", "didRelease" to false)); return
        }
        // Normal release is terminal but does not send permitInvalidated.
        permit.state = State.RELEASED
        permit.nonces.clear()
        current = null
        val stopped = stopNative()
        finishPending(permit, "released")
        result.success(if (stopped) reply("released", "didRelease" to true) else reply("rejected", "reason" to "cleanup_failed"))
    }

    private fun acquire(args: Map<*, *>, result: MethodChannel.Result) {
        if (!validKeys(args, setOf("opSeq", "permitId", "kind", "nonce"), result)) return
        val permitId = id(args, "permitId")
        val kind = args["kind"] as? String
        val nonce = id(args, "nonce")
        if (permitId == null || kind !in setOf("model", "mutation") || nonce == null) {
            reject(result, "invalid_arguments"); return
        }
        sequence(args, result) ?: return
        val permit = current
        if (permit == null || permit.id != permitId || permit.state != State.ACTIVE) {
            reject(result, "permit_inactive"); return
        }
        if (nonce in permit.nonces) { reject(result, "nonce_replayed"); return }
        if (permit.nonces.size >= MAX_NONCES) { reject(result, "nonce_capacity"); return }
        permit.nonces.add(nonce)
        result.success(reply("ticket", "permitId" to permit.id, "kind" to kind!!,
            "nonce" to nonce, "ticketId" to UUID.randomUUID().toString()))
    }

    private fun invalidate(): Permit? {
        val permit = current ?: return null
        permit.state = State.INVALIDATED
        permit.nonces.clear()
        current = null
        return permit
    }
    private fun stopNative(instance: AgentRunService? = null): Boolean {
        val running = service ?: instance ?: deferredStop
        service = null
        // Revocation does not erase a foreground-start dispatch already accepted
        // by Android. Its normal callback promotes before completing this stop.
        if (pendingForegroundStarts.isNotEmpty()) {
            deferredStop = running
            try { running?.removeForeground() } catch (_: RuntimeException) { cleanupFailed = true }
            return !cleanupFailed
        }
        deferredStop = null
        return try {
            running?.stopNative()
            !cleanupFailed
        } catch (_: RuntimeException) {
            cleanupFailed = true
            false
        }
    }
    private fun finishPending(permit: Permit, reason: String) {
        val pending = permit.pending.toList()
        permit.pending.clear()
        pending.forEach { try { reject(it.result, reason) } catch (_: RuntimeException) { /* Engine gone. */ } }
    }
    private fun notifyInvalidated(permit: Permit?, reason: String) {
        if (permit == null) return
        finishPending(permit, reason)
        val deliver = {
            try {
                channel?.invokeMethod("permitInvalidated", mapOf("version" to 1, "permitId" to permit.id,
                    "reason" to reason, "startRequestId" to permit.latestStartRequestId))
            } catch (_: RuntimeException) { /* Best effort only; native authority is already gone. */ }
            Unit
        }
        val events = testEvents
        if (events == null) deliver() else events.invalidated(deliver)
    }
    private fun stop(reason: String, instance: AgentRunService? = null): Boolean {
        val permit = invalidate()
        val stopped = stopNative(instance)
        notifyInvalidated(permit, reason)
        return stopped
    }
    fun serviceEnded(instance: AgentRunService, reason: String) {
        mainThread()
        // A delayed destroy from an old service cannot invalidate a newer permit.
        val permit = if (current?.id == instance.permitId) invalidate() else null
        if (service === instance) service = null
        if (deferredStop === instance) deferredStop = null
        try { instance.stopNative() } catch (_: RuntimeException) { cleanupFailed = true }
        notifyInvalidated(permit, reason)
    }

    fun serviceTimedOut(instance: AgentRunService) {
        serviceEnded(instance, "timeout")
    }
}
'''


AGENT_RUN_QA_ADAPTER = r'''package io.gitlabmobile.gitlab_mobile

// Generated debug-only fault adapter. Registered by C8's explicit QA Dart entry;
// no Activity, exported intent, storage, account or network access.
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class AgentRunQaAdapter(messenger: BinaryMessenger) : AgentRunTestEvents {
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "io.gitlabmobile/agent_runs_qa")
    private var dropCallback = false
    private var replyDelayMs = 0L
    private var registered = false
    private var closed = false
    private var taskBackCallCount = 0L

    init {
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            if (closed || args == null) {
                result.error("invalid_arguments", null, null)
            } else if (call.method == "register" && args.isEmpty()) {
                registered = true
                result.success(mapOf("version" to 1, "status" to "ready"))
            } else if (!registered) {
                result.error("not_registered", null, null)
            } else when (call.method) {
                "configure" -> {
                    val drop = args["dropCallback"]
                    val delay = args["replyDelayMs"]
                    if (args.keys.toSet() != setOf("dropCallback", "replyDelayMs") || drop !is Boolean ||
                            (delay !is Int && delay !is Long) || (delay as Number).toLong() !in 0L..5000L) {
                        result.error("invalid_arguments", null, null)
                    } else {
                        dropCallback = drop
                        replyDelayMs = delay.toLong()
                        result.success(mapOf("version" to 1, "status" to "configured"))
                    }
                }
                "syntheticTimeout" -> if (args.isEmpty()) {
                    val instance = AgentRunsChannel.serviceForTestEvents()
                    if (instance != null) AgentRunsChannel.serviceEnded(instance, "synthetic_timeout")
                    result.success(mapOf("version" to 1, "event" to "synthetic_timeout", "didStop" to (instance != null)))
                } else result.error("invalid_arguments", null, null)
                "taskBackCalls" -> if (args.isEmpty()) {
                    result.success(mapOf("version" to 1, "count" to taskBackCallCount))
                } else result.error("invalid_arguments", null, null)
                "reset" -> if (args.isEmpty()) {
                    dropCallback = false
                    replyDelayMs = 0L
                    taskBackCallCount = 0L
                    result.success(mapOf("version" to 1, "status" to "reset"))
                } else result.error("invalid_arguments", null, null)
                else -> result.notImplemented()
            }
        }
    }

    override fun invalidated(deliver: () -> Unit) {
        if (!closed && (!registered || !dropCallback)) deliver()
    }

    override fun taskBackInvoked() {
        if (!closed && registered) taskBackCallCount++
    }

    override fun wrap(result: MethodChannel.Result): MethodChannel.Result {
        if (!registered) return result
        return object : MethodChannel.Result {
            private fun deliver(reply: () -> Unit): Unit {
                if (closed) return
                val delay = replyDelayMs
                if (delay == 0L) reply()
                else handler.postDelayed({ if (!closed) reply() }, delay)
            }
            override fun success(value: Any?) = deliver { result.success(value) }
            override fun error(code: String, message: String?, details: Any?) = deliver { result.error(code, message, details) }
            override fun notImplemented() = deliver { result.notImplemented() }
        }
    }

    override fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        handler.removeCallbacksAndMessages(null)
    }
}
'''


def android_string(value: str) -> str:
    """Quote for Android's resource parser; ElementTree handles XML escaping."""
    escaped = (value.replace('\\', '\\\\').replace("'", "\\'").replace('"', '\\"')
               .replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t'))
    if escaped.startswith(('@', '?')):
        escaped = '\\' + escaped
    return '"' + escaped + '"'


def agent_run_files() -> dict[str, str]:
    _, catalogs = l10n.load()
    files = {
        f'src/main/kotlin/{KOTLIN_PACKAGE}/AgentRunService.kt': AGENT_RUN_SERVICE,
        f'src/debug/kotlin/{KOTLIN_PACKAGE}/AgentRunQaAdapter.kt': AGENT_RUN_QA_ADAPTER,
        'src/main/res/drawable/ic_ai_runs.xml': AGENT_ICON,
    }
    for tag, _, _, language, _, country in l10n.LANGUAGES:
        qualifier = language + (f'-r{country}' if country else '')
        directory = 'values' if tag == 'en' else f'values-{qualifier}'
        resources = ET.Element('resources')
        for name, key in AGENT_STRINGS.items():
            value = catalogs[tag][key]
            if l10n.placeholders(value):
                raise RuntimeError(f'Native fallback must be generic, without placeholders: {key} ({tag}).')
            ET.SubElement(resources, 'string', {'name': name, 'formatted': 'false'}).text = android_string(value)
        ET.indent(resources, space='    ')
        files[f'src/main/res/{directory}/strings.xml'] = (
            '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(resources, encoding='unicode') + '\n')
        # Keep both modern and legacy Android resource codes, with identical bytes.
        legacy = {'id': 'in', 'he': 'iw', 'yi': 'ji'}.get(language)
        if legacy:
            legacy_qualifier = legacy + (f'-r{country}' if country else '')
            files[f'src/main/res/values-{legacy_qualifier}/strings.xml'] = files[f'src/main/res/{directory}/strings.xml']
    return files


def _check_managed_files(app: Path, files: dict[str, str]) -> None:
    for name, content in files.items():
        path = app / name
        if path.exists() and (not path.is_file() or path.read_text(encoding='utf-8') != content):
            raise RuntimeError(f'Unknown managed Android content: {name}; review before upgrading.')


def _write_managed_files(app: Path, files: dict[str, str]) -> None:
    for name, content in files.items():
        path = app / name
        path.parent.mkdir(parents=True, exist_ok=True)
        _write_text(path, content)


def _write_text(path: Path, content: str) -> None:
    if not path.is_file() or path.read_bytes() != content.encode('utf-8'):
        path.write_text(content, encoding='utf-8')


def _write_xml(path: Path, tree: ET.ElementTree) -> None:
    content = ET.tostring(tree.getroot(), encoding='utf-8', xml_declaration=True)
    if not path.is_file() or path.read_bytes() != content:
        path.write_bytes(content)


def _check_agent_template(app: Path, root: ET.Element, files: dict[str, str]) -> None:
    application = root.find('application')
    if application is None:
        raise RuntimeError('Unknown Android template: application missing.')
    permissions = root.findall('uses-permission')
    names = [node.get(_android_attr('name')) for node in permissions]
    allowed = {'android.permission.INTERNET', *AGENT_PERMISSIONS}
    if (len(names) != len(set(names)) or set(names) - allowed or root.findall('uses-permission-sdk-23') or
            any(node.attrib != {_android_attr('name'): name} or len(node)
                for node, name in zip(permissions, names))):
        raise RuntimeError('Unknown or conflicting Android permission content.')
    services = application.findall('service')
    if services and (len(services) != 1 or services[0].attrib != AGENT_SERVICE_ATTRIBUTES or len(services[0])):
        raise RuntimeError('Unknown or conflicting AgentRunService manifest content.')
    present = [name in names for name in AGENT_PERMISSIONS]
    artifacts = [(app / name).exists() for name in files]
    if any((*present, *artifacts, bool(services))) and not all((*present, *artifacts, bool(services))):
        raise RuntimeError('Incomplete managed agent service template; review before upgrading.')
    if application.findall('receiver'):
        raise RuntimeError('Unknown Android receiver content; no background restart is supported.')
    # The link trampoline is another fully managed component. Do not silently
    # replace an exported/conflicting activity while hardening the manifest.
    expected_root = ET.fromstring(
        f'<manifest xmlns:android="{ANDROID}"><application><activity android:name=".MainActivity">'
        '<intent-filter><action android:name="android.intent.action.MAIN" /></intent-filter>'
        '</activity></application></manifest>')
    register_incoming_links_android(expected_root)
    expected_link = expected_root.find('application/activity[@android:name=".LinkActivity"]', {'android': ANDROID})
    links = [node for node in application.findall('activity')
             if node.get(_android_attr('name'), '').endswith('LinkActivity')]
    if links and (len(links) != 1 or _xml_shape(links[0]) != _xml_shape(expected_link)):
        raise RuntimeError('Unknown or conflicting LinkActivity manifest content.')
    _check_managed_files(app, files)


def _xml_shape(node: ET.Element) -> tuple:
    return node.tag, sorted(node.attrib.items()), (node.text or '').strip(), tuple(_xml_shape(child) for child in node)

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

PLAY_MANIFEST = '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <!-- Play channel: background AI runs stay off; remove foreground-service declarations. -->
    <uses-permission
        android:name="android.permission.FOREGROUND_SERVICE"
        tools:node="remove" />
    <uses-permission
        android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"
        tools:node="remove" />
    <application>
        <service
            android:name=".AgentRunService"
            tools:node="remove" />
    </application>
</manifest>
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
    """Upgrade only exact managed activities, channels and dependency blocks."""
    files = _check_update_template(app)
    agents = agent_run_files()
    _check_agent_template(app, ET.parse(app / 'src/main/AndroidManifest.xml').getroot(), agents)
    if not all((app / name).is_file() for name in agents):
        raise RuntimeError('Configure the complete agent service template before the update channels.')
    gradle = app / 'build.gradle.kts'
    text = gradle.read_text(encoding='utf-8')
    if UPDATE_DEPENDENCIES_BEGIN not in text:
        if FLAVORS_BEGIN not in text:
            raise RuntimeError('Configure the flavors before the update channels.')
        gradle.write_text(text.rstrip('\n') + '\n\n' + UPDATE_DEPENDENCIES, encoding='utf-8')
    activity = app / 'src/main/kotlin' / KOTLIN_PACKAGE / 'MainActivity.kt'
    if activity.read_text(encoding='utf-8') != MAIN_ACTIVITY:
        activity.write_text(MAIN_ACTIVITY, encoding='utf-8')
    _write_managed_files(app, files)


def _check_update_template(app: Path) -> dict[str, str]:
    text = (app / 'build.gradle.kts').read_text(encoding='utf-8')
    if text.count(UPDATE_DEPENDENCIES_BEGIN) or text.count(UPDATE_DEPENDENCIES_END):
        if text.count(UPDATE_DEPENDENCIES_BEGIN) != 1 or text.count(UPDATE_DEPENDENCIES_END) != 1:
            raise RuntimeError('Incomplete managed update dependency markers.')
        block = text[text.index(UPDATE_DEPENDENCIES_BEGIN):text.index(UPDATE_DEPENDENCIES_END) + len(UPDATE_DEPENDENCIES_END)]
        if block != UPDATE_DEPENDENCIES.rstrip('\n'):
            raise RuntimeError('Stale managed update dependencies; review and refresh the owned block.')
    activity = app / 'src/main/kotlin' / KOTLIN_PACKAGE / 'MainActivity.kt'
    current = activity.read_text(encoding='utf-8')
    if current not in (TEMPLATE_MAIN_ACTIVITY, LINKS_MAIN_ACTIVITY,
                       FRAGMENT_MAIN_ACTIVITY, MAIN_ACTIVITY):
        raise RuntimeError('Unknown MainActivity template; review before registering the update channel.')
    files = {
        f'src/main/kotlin/{KOTLIN_PACKAGE}/LinkActivity.kt': LINK_ACTIVITY,
        f'src/gitlab/kotlin/{KOTLIN_PACKAGE}/AppUpdateChannel.kt': GITLAB_UPDATE_CHANNEL,
        'src/gitlab/AndroidManifest.xml': GITLAB_MANIFEST,
        'src/gitlab/res/xml/update_paths.xml': GITLAB_UPDATE_PATHS,
        f'src/play/kotlin/{KOTLIN_PACKAGE}/AppUpdateChannel.kt': PLAY_UPDATE_CHANNEL,
        'src/play/AndroidManifest.xml': PLAY_MANIFEST,
    }
    _check_managed_files(app, files)
    present = {name for name in files if (app / name).exists()}
    required = set(files)
    if current == TEMPLATE_MAIN_ACTIVITY:
        required = set()
    elif 'src/play/AndroidManifest.xml' not in present:
        required.remove('src/play/AndroidManifest.xml')
    if present != required:
        raise RuntimeError('Incomplete managed update/link template; review before upgrading.')
    if current == TEMPLATE_MAIN_ACTIVITY and UPDATE_DEPENDENCIES_BEGIN in text:
        raise RuntimeError('Incomplete managed update template; dependencies exist without channels.')
    if current != TEMPLATE_MAIN_ACTIVITY and UPDATE_DEPENDENCIES_BEGIN not in text:
        raise RuntimeError('Incomplete managed update dependency markers.')
    for manifest in (app / 'src').glob('*/AndroidManifest.xml'):
        source_set = manifest.parent.name
        if source_set in {'main', 'gitlab'} or (
                source_set == 'play' and manifest.is_file() and manifest.read_text(encoding='utf-8') == PLAY_MANIFEST):
            continue
        # These two unmodified manifests come from the pinned Flutter template.
        expected = ET.fromstring(f'<manifest xmlns:android="{ANDROID}">'
                                 '<uses-permission android:name="android.permission.INTERNET" /></manifest>')
        if source_set not in {'debug', 'profile'} or _xml_shape(ET.parse(manifest).getroot()) != _xml_shape(expected):
            raise RuntimeError(f'Unknown Android source-set manifest: {source_set}; review before upgrading.')
    return files


def _fresh_launcher() -> ET.Element:
    """The pinned Flutter 3.47.2 launcher, before our managed hardening."""
    activity = ET.Element('activity', {_android_attr(key): value for key, value in {
        'name': '.MainActivity', 'exported': 'true', 'launchMode': 'singleTop', 'taskAffinity': '',
        'theme': '@style/LaunchTheme',
        'configChanges': 'orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode',
        'hardwareAccelerated': 'true', 'windowSoftInputMode': 'adjustResize',
    }.items()})
    ET.SubElement(activity, 'meta-data', {_android_attr('name'): 'io.flutter.embedding.android.NormalTheme',
                                          _android_attr('resource'): '@style/NormalTheme'})
    intent = ET.SubElement(activity, 'intent-filter')
    ET.SubElement(intent, 'action', {_android_attr('name'): 'android.intent.action.MAIN'})
    ET.SubElement(intent, 'category', {_android_attr('name'): 'android.intent.category.LAUNCHER'})
    return activity


def _check_launcher_template(root: ET.Element, managed: bool) -> None:
    expected = ET.Element('manifest')
    application = ET.SubElement(expected, 'application')
    application.append(_fresh_launcher())
    if managed:
        register_oauth_android(expected)
        register_incoming_links_android(expected)
    actual_activities = root.findall('application/activity')
    if [_xml_shape(node) for node in actual_activities] != [_xml_shape(node) for node in application.findall('activity')]:
        raise RuntimeError('Unknown or conflicting launcher/activity manifest content.')


def configure_android(folder: Path) -> None:
    # Refuse partial/conflicting input before writing even the hardening files.
    _check_update_template(folder / 'app')
    manifest = ET.parse(folder / 'app/src/main/AndroidManifest.xml').getroot()
    _check_agent_template(folder / 'app', manifest, agent_run_files())
    activity = folder / 'app/src/main/kotlin' / KOTLIN_PACKAGE / 'MainActivity.kt'
    has_agent = (folder / 'app/src/main/kotlin' / KOTLIN_PACKAGE / 'AgentRunService.kt').exists()
    activity_text = activity.read_text(encoding='utf-8')
    if has_agent != (activity_text == MAIN_ACTIVITY):
        raise RuntimeError('Incomplete managed agent activity/service template.')
    _check_launcher_template(manifest, managed=activity_text != TEMPLATE_MAIN_ACTIVITY)
    # Reuse the signing/flavor validators on a scratch file before hardening
    # writes anything. A malformed managed block must not leave a half-upgrade.
    gradle = folder / 'app/build.gradle.kts'
    with tempfile.TemporaryDirectory(prefix='bootstrap-gradle-') as temporary:
        candidate = Path(temporary) / 'build.gradle.kts'
        candidate.write_text(gradle.read_text(encoding='utf-8'), encoding='utf-8')
        android_signing.configure_gradle(candidate)
        configure_flavors(candidate)
        configure_notification_gradle(candidate)
        configured_gradle = candidate.read_text(encoding='utf-8')
    harden_android(folder)
    _write_text(gradle, configured_gradle)
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


# local_auth shows its prompt from a FragmentActivity; on Android 8 and below
# that prompt needs an AppCompat theme (androidx.biometric brings appcompat).
# DayNight covers the night variant too, so both styles files use it.
APP_THEME_PARENT = 'Theme.AppCompat.DayNight.NoActionBar'


def _patch_style_bars(path: Path) -> None:
    tree = ET.parse(path)
    root = tree.getroot()
    for style in root.findall('style'):
        if style.get('name') not in {'LaunchTheme', 'NormalTheme'}:
            continue
        style.set('parent', APP_THEME_PARENT)
        items = {item.get('name'): item for item in style.findall('item')}
        for name, value in _SYSTEM_BAR_ITEMS:
            item = items.get(name)
            if item is None:
                item = ET.SubElement(style, 'item', {'name': name})
            item.text = value
    ET.indent(tree, space='    ')
    _write_xml(path, tree)


def apply_launcher_icons(flutter: str, *, offline: bool = False) -> None:
    subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile', *(['--offline'] if offline else [])],
                   cwd=ROOT, check=True, timeout=180)
    dart = str(Path(flutter).resolve().parent / 'dart')
    subprocess.run([dart, 'run', 'flutter_launcher_icons'], cwd=ROOT, check=True, timeout=120)


IOS_APP_DELEGATE_TEMPLATE = '''import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
'''

IOS_BACKUP_REGISTRATION = '''    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let backupChannel = FlutterMethodChannel(
      name: "mergeline/backup",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    backupChannel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "invalidArguments", message: nil, details: nil))
        return
      }
      do {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "backupExclusionFailed", message: nil, details: nil))
      }
    }'''

def ios_backup_app_delegate(folder: Path) -> tuple[Path, str]:
    path = folder / 'Runner/AppDelegate.swift'
    text = path.read_text(encoding='utf-8')
    expected = IOS_APP_DELEGATE_TEMPLATE.replace(
        '    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)',
        IOS_BACKUP_REGISTRATION,
        1,
    )
    if text not in (IOS_APP_DELEGATE_TEMPLATE, expected):
        raise RuntimeError('Unknown iOS AppDelegate template; review required.')
    return path, expected


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
    app_delegate, backup_delegate = ios_backup_app_delegate(folder)
    project.write_text(changed, encoding='utf-8')
    app_delegate.write_text(backup_delegate, encoding='utf-8')
    (folder / 'Runner/Runner.entitlements').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>keychain-access-groups</key><array/></dict></plist>
''', encoding='utf-8')
    register_oauth_ios(folder)
    register_photo_library_ios(folder)
    register_face_id_ios(folder)
    register_localizations_ios(folder)
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
        keys['CFBundleDisplayName'].text = APP_NAME
    else:
        plist.append(_plist_key('CFBundleDisplayName'))
        ET.SubElement(plist, 'string').text = APP_NAME
    if 'CFBundleName' in keys:
        keys['CFBundleName'].text = APP_NAME
    else:
        plist.append(_plist_key('CFBundleName'))
        ET.SubElement(plist, 'string').text = APP_NAME
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


def register_face_id_ios(folder: Path) -> None:
    """The app lock may use Face ID; iOS requires a reason before asking."""
    path = folder / 'Runner/Info.plist'
    if not path.is_file():
        return
    tree = ET.parse(path)
    plist = tree.getroot().find('dict')
    if plist is None:
        raise RuntimeError('Unknown iOS template: Info.plist dict missing.')
    for node in list(plist):
        if node.tag == 'key' and node.text == 'NSFaceIDUsageDescription':
            return
    plist.append(_plist_key('NSFaceIDUsageDescription'))
    ET.SubElement(plist, 'string').text = f'開啟 App 鎖定後，用 Face ID 解鎖 {APP_NAME}。'
    ET.indent(tree, space='\t')
    tree.write(path, encoding='utf-8', xml_declaration=True)


def _plist_key(name: str) -> ET.Element:
    key = ET.Element('key')
    key.text = name
    return key


def generate_templates(flutter: str) -> None:
    with tempfile.TemporaryDirectory(prefix='gitlab-mobile-') as temporary:
        template = Path(temporary) / 'gitlab_mobile'
        packages_dir = ROOT / 'packages'
        if packages_dir.is_dir():
            shutil.copytree(packages_dir, template / 'packages')
        subprocess.run([flutter, 'create', '--platforms=android,ios', '--org=io.gitlabmobile',
                        '--project-name=gitlab_mobile', '--no-pub', str(template)], check=True)
        configure_android(template / 'android')
        configure_ios(template / 'ios')
        for name in ('android', 'ios'):
            shutil.copytree(template / name, ROOT / name)
        shutil.copy2(template / '.metadata', ROOT / '.metadata')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default='flutter', help='Path to pinned Flutter executable.')
    parser.add_argument('--check-sdk', action='store_true')
    parser.add_argument('--offline', action='store_true', help='Resolve locked Pub packages from the existing cache only.')
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
        generate_templates(flutter)
        apply_launcher_icons(flutter, offline=args.offline)
        print('Native runners generated. Apple team/signing and device checks remain unconfigured.')
        print('Next: flutter pub get; dart format lib test; flutter analyze; flutter test')
        return 0
    except (RuntimeError, subprocess.SubprocessError, OSError, ValueError) as exc:
        parser.exit(1, f'Bootstrap stopped: {exc}\n')


if __name__ == '__main__':
    raise SystemExit(main())
