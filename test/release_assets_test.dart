import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/registry_models.dart';
import 'package:gitlab_mobile/core/release_assets.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/release_assets_section.dart';
import 'package:gitlab_mobile/shared/package_download.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

const _api = 'https://example.com/gitlab/api/v4';
const _apk = '$_api/projects/42/packages/generic/mobile-preview/1.2.3/app-debug.apk';
final _sha = 'c' * 64;

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

Map<String, dynamic> _release() => {
  'tag_name': 'v1.2.3',
  'name': 'v1.2.3 preview',
  'description': 'Notes',
  'released_at': '2026-10-18T02:00:00Z',
  'assets': {
    'count': 5,
    'links': [
      {'id': 1, 'name': 'app-debug.apk', 'url': _apk, 'link_type': 'package'},
      {'id': 2, 'name': 'Changelog', 'url': 'https://docs.example.org/changelog', 'link_type': 'other'},
      {'id': 3, 'name': 'Plain HTTP', 'url': 'http://mirror.example.org/app.apk', 'link_type': 'other'},
    ],
    'sources': [
      {'format': 'zip', 'url': 'https://example.com/gitlab/studio/mobile-workspace/-/archive/v1.2.3/mobile-workspace-v1.2.3.zip'},
      {'format': 'tar.gz', 'url': 'https://example.com/gitlab/studio/mobile-workspace/-/archive/v1.2.3/mobile-workspace-v1.2.3.tar.gz'},
    ],
  },
};

Map<String, dynamic> _package(int id, {String name = 'mobile-preview', String version = '1.2.3'}) => {
  'id': id, 'name': name, 'version': version, 'package_type': 'generic',
  'status': 'default', 'created_at': '2026-10-18T00:00:00Z',
};

Map<String, dynamic> _file(int id, String name) => {
  'id': id, 'file_name': name, 'size': 2048, 'file_sha256': _sha, 'created_at': '2026-10-18T00:00:00Z',
};

final class _ReleaseFixture extends WorkspaceFixture {
  List<Map<String, dynamic>> packages = [_package(5), _package(9), _package(11, name: 'mobile-preview-extra')];
  List<Map<String, dynamic>> files = [_file(20, 'app-debug.apk'), _file(31, 'app-debug.apk'), _file(32, 'SHA256SUMS')];

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = _apiPath(request);
    if (path == 'projects/42/releases') return jsonResponse([_release()]);
    if (path == 'projects/42/packages') return jsonResponse(packages);
    if (path == 'projects/42/packages/9/package_files') return jsonResponse(files);
    return super.respond(request);
  }
}

final class _RecordingDownloader implements PackageDownloader {
  RegistryPackage? package;
  RegistryPackageFile? file;

  @override
  Future<File> download({
    required int projectId,
    required RegistryPackage package,
    required RegistryPackageFile file,
    required Account account,
    required bool Function() isCurrent,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  }) {
    this.package = package;
    this.file = file;
    return Completer<File>().future;
  }
}

void main() {
  final instance = GitLabInstance.parse('https://example.com/gitlab');
  ReleasePackageLink? parse(String url) =>
      parseReleasePackageLink(Uri.parse(url), instance: instance, projectId: 42, projectPath: 'studio/mobile-workspace');

  group('parseReleasePackageLink', () {
    test('accepts this project by numeric ID or encoded path', () {
      final byId = parse(_apk)!;
      expect([byId.packageName, byId.packageVersion, byId.fileName], ['mobile-preview', '1.2.3', 'app-debug.apk']);
      expect(parse('$_api/projects/studio%2Fmobile-workspace/packages/generic/mobile-preview/1.2.3/app-debug.apk'), isNotNull);
    });

    test('rejects other projects, hosts, endpoints and malformed paths', () {
      for (final url in [
        '$_api/projects/43/packages/generic/mobile-preview/1.2.3/app-debug.apk',
        'https://other.example.com/gitlab/api/v4/projects/42/packages/generic/p/1/app.apk',
        'http://example.com/gitlab/api/v4/projects/42/packages/generic/p/1/app.apk',
        '$_api/projects/42/packages/maven/p/1/app.apk',
        '$_api/projects/42/packages/generic/p/1',
        '$_api/projects/42/packages/generic/p/1/dir/app.apk',
        '$_api/projects/42/packages/generic/p/1/app.apk?private_token=x',
        'https://example.com/gitlab/studio/mobile-workspace/-/package_files/9/download',
        '$_api/projects/42/packages/generic/p/1/%C3%28.apk',
      ]) {
        expect(parse(url), isNull, reason: url);
      }
    });
  });

  test('release assets skip entries without a name or an absolute URL', () {
    final assets = ReleaseAssets.fromJson({
      'links': [
        {'id': 1, 'name': ' ok ', 'url': 'https://example.com/a', 'link_type': 'other'},
        {'id': 2, 'name': '', 'url': 'https://example.com/b'},
        {'id': 3, 'name': 'relative', 'url': '/c'},
        'not a map',
      ],
      'sources': [
        {'format': 'zip', 'url': 'https://example.com/a.zip'},
        {'format': '', 'url': 'https://example.com/b.zip'},
      ],
    });
    expect(assets.links.map((link) => link.name), ['ok']);
    expect(assets.sources.map((source) => source.format), ['zip']);
    expect(ReleaseAssets.fromJson(null).isEmpty, isTrue);
  });

  group('releasePackageFile', () {
    test('picks the newest exact package and file', () async {
      final fixture = _ReleaseFixture();
      addTearDown(fixture.api.close);
      final (package, file) =
          await fixture.api.releasePackageFile(42, parse(_apk)!, isCurrent: () => true);
      expect(package.id, 9);
      expect(file.id, 31);
      final query = fixture.adapter.requests.firstWhere((r) => _apiPath(r) == 'projects/42/packages').uri.queryParameters;
      expect(query, containsPair('package_type', 'generic'));
      expect(query, containsPair('package_name', 'mobile-preview'));
      expect(query, containsPair('package_version', '1.2.3'));
    });

    test('a missing package or file is invisible, a stale owner is cancelled', () async {
      final fixture = _ReleaseFixture()..packages = [_package(11, name: 'mobile-preview-extra')];
      addTearDown(fixture.api.close);
      await expectLater(fixture.api.releasePackageFile(42, parse(_apk)!, isCurrent: () => true),
          throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.invisible)));
      fixture
        ..packages = [_package(9)]
        ..files = [_file(32, 'SHA256SUMS')];
      await expectLater(fixture.api.releasePackageFile(42, parse(_apk)!, isCurrent: () => true),
          throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.invisible)));
      await expectLater(fixture.api.releasePackageFile(42, parse(_apk)!, isCurrent: () => false),
          throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.cancelled)));
    });
  });

  testWidgets('the release detail lists its assets with the action for each', (tester) async {
    final fixture = _ReleaseFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(MetadataPage(
      account: fixture.account, api: fixture.api, project: fixture.project, kind: MetadataKind.releases)));
    await settleNetworkWidgets(tester);
    expect(find.text('3 個附件'), findsOneWidget);

    await tester.tap(find.text('v1.2.3 preview'));
    await settleNetworkWidgets(tester);
    expect(find.text('附件'), findsOneWidget);
    expect(find.text('套件檔案 · 下載後核對 SHA-256'), findsOneWidget);
    expect(find.text('docs.example.org · 在瀏覽器開啟'), findsOneWidget);
    expect(find.text('不是 HTTPS 連結，無法開啟'), findsOneWidget);
    expect(find.text('原始碼（zip）'), findsOneWidget);
    expect(find.text('原始碼（tar.gz）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a package link resolves and opens the checked download sheet', (tester) async {
    final fixture = _ReleaseFixture();
    addTearDown(fixture.api.close);
    final downloader = _RecordingDownloader();
    final assets = ReleaseAssets.fromJson(_release()['assets']);
    await tester.pumpWidget(workspaceHost(Scaffold(body: ListView(children: [
      ReleaseAssetsSection(
        account: fixture.account, api: fixture.api, project: fixture.project,
        assets: assets, isCurrent: () => true, packageDownloader: downloader),
    ]))));
    await settleNetworkWidgets(tester);
    expect(releaseLinkAction(assets.links[0], account: fixture.account, project: fixture.project), ReleaseLinkAction.package);
    expect(releaseLinkAction(assets.links[1], account: fixture.account, project: fixture.project), ReleaseLinkAction.browser);
    expect(releaseLinkAction(assets.links[2], account: fixture.account, project: fixture.project), ReleaseLinkAction.blocked);

    await tester.tap(find.byKey(const ValueKey('release-link-0')));
    await settleNetworkWidgets(tester);
    final sheet = tester.widget<PackageDownloadSheet>(find.byType(PackageDownloadSheet));
    expect(sheet.package.id, 9);
    expect(sheet.file.id, 31);
    expect(downloader.file?.id, 31);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a vanished package explains itself and offers the browser', (tester) async {
    final fixture = _ReleaseFixture()..packages = [];
    addTearDown(fixture.api.close);
    final assets = ReleaseAssets.fromJson(_release()['assets']);
    await tester.pumpWidget(workspaceHost(Scaffold(body: ListView(children: [
      ReleaseAssetsSection(
        account: fixture.account, api: fixture.api, project: fixture.project,
        assets: assets, isCurrent: () => true),
    ]))));
    await tester.tap(find.byKey(const ValueKey('release-link-0')));
    await settleNetworkWidgets(tester);
    expect(find.textContaining('找不到這個套件檔案'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, '在瀏覽器開啟'), findsOneWidget);
    expect(find.byType(PackageDownloadSheet), findsNothing);
  });
}
