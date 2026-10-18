import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/anonymous_api.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/update/app_update.dart';
import 'package:gitlab_mobile/features/update/update_controller.dart';
import 'package:gitlab_mobile/features/update/update_section.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

const _project = '/api/v4/projects/86648389';
const _api = 'https://gitlab.com$_project';
const _debugSha = 'aaaaaaaa';
const _releaseSha = 'bbbbbbbb';

/// A synthetic gitlab.com: two releases, the newest a debug preview, the other
/// a gitlab-channel release build of versionCode 300.
final class _Server {
  _Server() {
    files[_debugSha] = {
      'gitlab-mobile-$_debugSha-debug.apk': utf8.encode('debug apk'),
      'build-metadata.json': utf8.encode(jsonEncode({'channel': 'gitlab', 'build_type': 'debug', 'version_code': 290,
        'version_name': '0.5.0', 'commit': '${_debugSha}0000'})),
    };
    files[_releaseSha] = {
      'gitlab-mobile-$_releaseSha-release.apk': Uint8List.fromList(List<int>.generate(4096, (i) => i % 251)),
      'build-metadata.json': utf8.encode(jsonEncode({'channel': 'gitlab', 'build_type': 'release', 'version_code': 300,
        'version_name': '0.5.0', 'commit': '${_releaseSha}1111'})),
    };
  }

  final files = <String, Map<String, Uint8List>>{};
  final headers = <Map<String, dynamic>>[];
  String? corrupt;

  int _packageId(String sha) => sha == _debugSha ? 7 : 8;
  String _shaOf(int id) => id == 7 ? _debugSha : _releaseSha;
  int _fileId(String name) => name.endsWith('.apk') ? 1 : 2;

  Map<String, Object> _release(String tag, String sha) => {
    'tag_name': tag,
    '_links': {'self': 'https://gitlab.com/aa22396584/gitlab-mobile/-/releases/$tag'},
    'assets': {'links': [
      for (final name in files[sha]!.keys)
        {'id': name.length, 'name': name, 'url': '$_api/packages/generic/gitlab-mobile-preview/$sha/$name', 'link_type': 'package'},
    ]},
  };

  Map<String, Object> _package(String sha) => {'id': _packageId(sha), 'name': 'gitlab-mobile-preview', 'version': sha,
    'package_type': 'generic', 'status': 'default', 'created_at': '2026-10-18T00:00:00Z'};

  FutureOr<ResponseBody> respond(RequestOptions request) {
    headers.add(Map.of(request.headers));
    final path = request.uri.path;
    if (path == '$_project/releases') {
      return jsonResponse([_release('v0.5.0-dev.$_debugSha', _debugSha), _release('v0.5.0-rc.$_releaseSha', _releaseSha)]);
    }
    if (path == '$_project/packages') {
      return jsonResponse([_package(request.uri.queryParameters['package_version']!)]);
    }
    final package = RegExp('^$_project/packages/([0-9]+)(/package_files(?:/([0-9]+)/download)?)?\$').firstMatch(path);
    if (package != null) {
      final sha = _shaOf(int.parse(package.group(1)!));
      if (package.group(2) == null) return jsonResponse(_package(sha));
      if (package.group(3) == null) {
        return jsonResponse([
          for (final MapEntry(key: name, value: bytes) in files[sha]!.entries)
            {'id': _fileId(name), 'file_name': name, 'size': bytes.length,
              'file_sha256': sha256.convert(bytes).toString(), 'created_at': '2026-10-18T00:00:00Z'},
        ]);
      }
      final name = files[sha]!.keys.firstWhere((name) => _fileId(name) == int.parse(package.group(3)!));
      var bytes = files[sha]![name]!;
      if (corrupt == name) bytes = Uint8List.fromList([...bytes.take(bytes.length - 1), bytes.last ^ 1]);
      return ResponseBody.fromBytes(bytes, 200, headers: {'content-type': ['application/octet-stream'],
        'content-length': ['${bytes.length}']});
    }
    return jsonResponse({'message': '404 Not Found'}, status: 404);
  }
}

GitLabApi _api0(_Server server) =>
    anonymousGitLabApi(updateInstance, dio: Dio()..httpClientAdapter = FakeAdapter(server.respond),
      cdnAdapter: FakeAdapter(server.respond));

final class _Platform implements UpdatePlatform {
  final installs = <String>[];
  InstallStart result = InstallStart.started;
  @override
  Future<InstallStart> installApk(String path) async {
    installs.add(path);
    return result;
  }
  @override
  Future<({bool available, int? versionCode, bool downloaded})> checkPlay() async =>
      (available: true, versionCode: 310, downloaded: false);
  @override
  Future<bool> startPlayUpdate() async => true;
  @override
  Future<void> completePlayUpdate() async {}
}

final class _Store implements UpdatePreferenceStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('update-test-'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('the channel follows the Android flavor and is off elsewhere', () {
    expect(updateChannelFor('gitlab', TargetPlatform.android), UpdateChannel.gitlab);
    expect(updateChannelFor('play', TargetPlatform.android), UpdateChannel.play);
    expect(updateChannelFor(null, TargetPlatform.android), UpdateChannel.none);
    expect(updateChannelFor('gitlab', TargetPlatform.iOS), UpdateChannel.none);
  });

  test('the newest gitlab release build is found anonymously, skipping debug previews', () async {
    final server = _Server();
    final api = _api0(server);
    addTearDown(api.close);
    final release = await latestAppRelease(api);
    expect(release, isNotNull);
    expect(release!.versionCode, 300);
    expect(release.label, '0.5.0 (300)');
    expect(release.tag, 'v0.5.0-rc.$_releaseSha');
    expect(release.file.name, 'gitlab-mobile-$_releaseSha-release.apk');
    for (final sent in server.headers) {
      expect(sent.keys.where(isCredentialHeader), isEmpty, reason: 'no credential leaves the update check');
    }
  });

  test('metadata that does not match its recorded SHA-256 fails the check', () async {
    final server = _Server()..corrupt = 'build-metadata.json';
    final api = _api0(server);
    addTearDown(api.close);
    await expectLater(latestAppRelease(api),
      throwsA(isA<ApiFailure>().having((f) => f.title, 'title', '更新資訊驗證失敗')));
  });

  test('a debug-only or play metadata is never offered to the gitlab channel', () async {
    final server = _Server();
    server.files[_releaseSha]!['build-metadata.json'] = utf8.encode(jsonEncode({'channel': 'play',
      'build_type': 'release', 'version_code': 300, 'version_name': '0.5.0', 'commit': ''}));
    final api = _api0(server);
    addTearDown(api.close);
    expect(await latestAppRelease(api), isNull);
  });

  test('the APK downloads into updates/ and is checked against GitLab', () async {
    final server = _Server();
    final api = _api0(server);
    addTearDown(api.close);
    final release = (await latestAppRelease(api))!;
    final directory = Directory('${temp.path}/updates');
    File('${temp.path}/updates/old.apk').createSync(recursive: true);
    final apk = await downloadAppRelease(api, release, directory);
    expect(apk.path, '${directory.path}/gitlab-mobile-300.apk');
    expect(apk.readAsBytesSync(), server.files[_releaseSha]!['gitlab-mobile-$_releaseSha-release.apk']);
    expect(directory.listSync().map((entry) => entry.path), [apk.path], reason: 'earlier updates were removed');

    server.corrupt = 'gitlab-mobile-$_releaseSha-release.apk';
    await expectLater(downloadAppRelease(api, release, directory),
      throwsA(isA<ApiFailure>().having((f) => f.title, 'title', '更新檔驗證失敗')));
    expect(directory.existsSync(), isFalse, reason: 'a file that failed verification is deleted');
  });

  group('controller', () {
    AppUpdateController controller(_Server server, {String build = '290', _Platform? platform, _Store? store}) {
      final updates = AppUpdateController(
        channel: UpdateChannel.gitlab,
        store: store ?? _Store(),
        buildInfo: () async => BuildInfo(version: '0.5.0', buildNumber: build, commit: 'test'),
        api: () => _api0(server),
        platform: platform ?? _Platform(),
        directory: () async => Directory('${temp.path}/updates'),
      );
      addTearDown(updates.dispose);
      return updates;
    }

    test('offers a higher versionCode, downloads it and hands it to the installer', () async {
      final platform = _Platform();
      final updates = controller(_Server(), platform: platform);
      await updates.start();
      expect(updates.stage, UpdateStage.available);
      expect(updates.unannounced, isTrue, reason: 'the start-up check points it out once');
      await updates.download();
      expect(updates.stage, UpdateStage.downloaded);
      platform.result = InstallStart.needsPermission;
      await updates.install();
      expect(updates.needsPermission, isTrue);
      expect(updates.stage, UpdateStage.downloaded, reason: 'the user comes back and taps 安裝 again');
      platform.result = InstallStart.started;
      await updates.install();
      expect(platform.installs, ['${temp.path}/updates/gitlab-mobile-300.apk', '${temp.path}/updates/gitlab-mobile-300.apk']);
      expect(updates.needsPermission, isFalse);
    });

    test('the same or a newer build is up to date, and a disabled start-up check stays quiet', () async {
      final current = controller(_Server(), build: '300');
      await current.check();
      expect(current.stage, UpdateStage.upToDate);
      final server = _Server();
      final quiet = controller(server, store: _Store()..value = '0');
      await quiet.start();
      expect(quiet.autoCheck, isFalse);
      expect(server.headers, isEmpty, reason: 'nothing is requested');
      expect(quiet.stage, UpdateStage.idle);
    });
  });

  testWidgets('the section walks from 檢查 to 安裝', (tester) async {
    final platform = _Platform();
    final server = _Server();
    final updates = AppUpdateController(
      channel: UpdateChannel.gitlab,
      store: _Store(),
      buildInfo: () async => const BuildInfo(version: '0.5.0', buildNumber: '290', commit: 'test'),
      api: () => _api0(server),
      platform: platform,
      directory: () async => Directory('${temp.path}/updates'),
    );
    addTearDown(updates.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [UpdateSection(controller: updates)]))));
    expect(find.text('檢查更新'), findsOneWidget);
    // The fake server, the file writes and the hashing isolate run on the real
    // event loop, so the controller is driven there; the buttons are checked
    // to be the ones that start each step.
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('app-update-check'))).onPressed, isNotNull);
    await tester.runAsync(updates.check);
    await tester.pump();
    expect(find.text('有新版本 0.5.0 (300)'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('app-update-download'))).onPressed, isNotNull);
    await tester.runAsync(updates.download);
    await tester.pump();
    expect(find.text('已下載並驗證 0.5.0 (300)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-update-install')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(platform.installs, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('app-update-auto-check')));
    await tester.pump();
    expect(updates.autoCheck, isFalse);
  });

  testWidgets('an update the start-up check found gets a badge on 我的 and one snack bar', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    FlutterSecureStorage.setMockInitialValues({});
    final appearance = AppearanceController(MemoryAppearanceStore());
    addTearDown(appearance.dispose);
    final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
    addTearDown(shortcuts.dispose);
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    final server = _Server();
    final updates = AppUpdateController(
      channel: UpdateChannel.gitlab,
      store: _Store(),
      buildInfo: () async => const BuildInfo(version: '0.5.0', buildNumber: '290', commit: 'test'),
      api: () => _api0(server),
      platform: _Platform(),
      directory: () async => Directory('${temp.path}/updates'),
    );
    addTearDown(updates.dispose);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      await updates.start();
    });
    expect(updates.unannounced, isTrue);

    await tester.pumpWidget(AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts,
      buildInfoLoader: () async => const BuildInfo(version: '0.5.0', buildNumber: '290', commit: 'test'),
      updates: updates));
    await settleNetworkWidgets(tester);
    expect(find.text('有新版本可以更新'), findsOneWidget);
    expect(updates.unannounced, isFalse, reason: 'pointed out once');
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)), findsWidgets);
    await tester.tap(find.text('查看'));
    await settleNetworkWidgets(tester);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 3);
    await tester.scrollUntilVisible(find.text('應用程式更新'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('有新版本 0.5.0 (300)'), findsOneWidget);
  });
}
