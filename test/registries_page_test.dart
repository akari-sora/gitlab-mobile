import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/registry_models.dart';
import 'package:gitlab_mobile/features/workspace/registries_page.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = Project(
  id: 42,
  name: 'Mobile',
  path: 'studio/mobile',
  visibility: 'private',
  defaultBranch: 'main',
);

Account _account(GitLabApi api, {int id = 7, String username = 'developer'}) =>
    Account(
      instance: api.instance,
      user: GitLabUser(id: id, username: username, name: username),
      token: 'synthetic-test-token',
    );

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  builder: (context, value) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: value!,
  ),
  home: child,
);

String _apiPath(RequestOptions request) {
  final segments = request.uri.pathSegments;
  return segments.skip(segments.indexOf('v4') + 1).join('/');
}

Map<String, Object?> _package({
  String name = 'mobile-kit',
  String type = 'npm',
}) => {
  'id': 11,
  'name': name,
  'version': '1.2.3',
  'package_type': type,
  'status': 'default',
  'created_at': '2026-10-01T08:00:00Z',
  '_links': {'delete_api_path': '/api/v4/projects/42/packages/11'},
};

Map<String, Object?> _file() => {
  'id': 91,
  'package_id': 11,
  'file_name': 'mobile-kit-1.2.3.tgz',
  'size': 1536,
  'file_sha256':
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'created_at': '2026-10-01T08:01:00Z',
};

Map<String, Object?> _repository() => {
  'id': 22,
  'name': 'app',
  'path': 'studio/mobile/app',
  'location': 'registry.example.com/studio/mobile/app',
  'project_id': 42,
  'tags_count': 1,
  'size': 4096,
  'created_at': '2026-10-01T09:00:00Z',
  'status': null,
};

Map<String, Object?> _tag({bool detail = false}) => {
  'name': 'v1.2.3',
  'path': 'studio/mobile/app:v1.2.3',
  'location': 'registry.example.com/studio/mobile/app:v1.2.3',
  if (detail) ...{
    'digest':
        'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    'revision':
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    'created_at': '2026-10-01T09:10:00Z',
    'total_size': 8192,
  },
};

final class RegistryFixture {
  RegistryFixture({this.access = 40});
  final int access;
  bool packageExists = true;
  bool fileExists = true;
  bool tagExists = true;
  bool repositoryExists = true;
  final requests = <RequestOptions>[];
  late final adapter = FakeAdapter(respond);
  late final api = testApi(adapter);

  FutureOr<ResponseBody> respond(RequestOptions request) {
    requests.add(request);
    final path = _apiPath(request);
    final method = request.method;
    if (path == 'projects/42/packages' && method == 'GET') {
      final type = request.uri.queryParameters['package_type'];
      return jsonResponse(
        packageExists
            ? [_package(type: type == 'terraform_module' ? type! : 'npm')]
            : <Object>[],
      );
    }
    if (path == 'projects/42/packages/11') {
      if (method == 'DELETE') {
        packageExists = false;
        fileExists = false;
        return ResponseBody.fromString('', 204);
      }
      return packageExists
          ? jsonResponse(_package())
          : jsonResponse({}, status: 404);
    }
    if (path == 'projects/42/packages/11/package_files' && method == 'GET') {
      return jsonResponse(fileExists ? [_file()] : <Object>[]);
    }
    if (path == 'projects/42/packages/11/package_files/91' &&
        method == 'DELETE') {
      fileExists = false;
      return ResponseBody.fromString('', 204);
    }
    if (path == 'projects/42/registry/repositories' && method == 'GET') {
      return jsonResponse(repositoryExists ? [_repository()] : <Object>[]);
    }
    if (path == 'registry/repositories/22' && method == 'GET') {
      return repositoryExists
          ? jsonResponse(_repository())
          : jsonResponse({}, status: 404);
    }
    if (path == 'projects/42/registry/repositories/22') {
      if (method == 'DELETE') {
        repositoryExists = false;
        tagExists = false;
        return ResponseBody.fromString('', 202);
      }
    }
    if (path == 'projects/42/registry/repositories/22/tags' &&
        method == 'GET') {
      return jsonResponse(tagExists ? [_tag()] : <Object>[]);
    }
    if (path == 'projects/42/registry/repositories/22/tags/v1.2.3') {
      if (method == 'DELETE') {
        tagExists = false;
        return ResponseBody.fromString('', 204);
      }
      return tagExists
          ? jsonResponse(_tag(detail: true))
          : jsonResponse({}, status: 404);
    }
    if (path == 'projects/42/members/all/7' && method == 'GET') {
      return jsonResponse({
        'id': 7,
        'username': 'developer',
        'access_level': access,
      });
    }
    return jsonResponse({}, status: 404);
  }
}

Future<void> _settle(WidgetTester tester) => settleNetworkWidgets(tester);

void main() {
  test('registry models parse useful fields and format sizes', () {
    final package = RegistryPackage.fromJson(
      Map<String, dynamic>.from(_package()),
    );
    final file = RegistryPackageFile.fromJson(
      Map<String, dynamic>.from(_file()),
    );
    final repository = ContainerRepository.fromJson(
      Map<String, dynamic>.from(_repository()),
    );
    final tag = ContainerTag.fromJson(
      Map<String, dynamic>.from(_tag(detail: true)),
    );

    expect(package.identity, 'mobile-kit@1.2.3');
    expect(package.canDelete, isTrue);
    expect(file.sha256, startsWith('aaaaaaaa'));
    expect(repository.tagsCount, 1);
    expect(tag.digest, startsWith('sha256:'));
    expect(packageTypeLabel('terraform_module'), 'Terraform Module');
    expect(registryBytes(1536), '1.5 KiB');
    expect(() => RegistryPackage.fromJson({'id': 0}), throwsFormatException);
  });

  testWidgets(
    'package search is explicit and package file delete is fresh-read guarded',
    (tester) async {
      final fixture = RegistryFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _host(
          RegistriesPage(
            account: _account(fixture.api),
            api: fixture.api,
            project: _project,
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('mobile-kit'), findsOneWidget);
      final initialPackageReads = fixture.requests
          .where((request) => _apiPath(request) == 'projects/42/packages')
          .length;

      await tester.enterText(find.byType(SearchBar).first, 'mobile');
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        fixture.requests.where(
          (request) => _apiPath(request) == 'projects/42/packages',
        ),
        hasLength(initialPackageReads),
        reason: 'typing alone must not send a request',
      );
      await tester.tap(find.byTooltip('搜尋').first);
      await _settle(tester);
      final searchRequest = fixture.requests.lastWhere(
        (request) => _apiPath(request) == 'projects/42/packages',
      );
      expect(searchRequest.uri.queryParameters['package_name'], 'mobile');
      expect(searchRequest.uri.queryParameters['include_versionless'], 'true');

      await tester.tap(find.text('mobile-kit'));
      await _settle(tester);
      expect(find.text('mobile-kit@1.2.3'), findsOneWidget);
      expect(find.text('mobile-kit-1.2.3.tgz'), findsOneWidget);
      expect(find.textContaining('1.5 KiB'), findsOneWidget);
      expect(find.textContaining('不會把 App Token'), findsOneWidget);

      await tester.tap(find.byTooltip('刪除 mobile-kit-1.2.3.tgz'));
      await _settle(tester);
      expect(find.widgetWithText(FilledButton, '確認'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '確認'))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'mobile-kit-1.2.3.tgz',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await _settle(tester);
      expect(fixture.fileExists, isFalse);
      expect(find.text('此套件沒有可顯示的檔案'), findsOneWidget);
      expect(
        fixture.requests.where(
          (request) =>
              request.method == 'DELETE' &&
              _apiPath(request).endsWith('/package_files/91'),
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Terraform tab uses the documented package_type filter', (
    tester,
  ) async {
    final fixture = RegistryFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        RegistriesPage(
          account: _account(fixture.api),
          api: fixture.api,
          project: _project,
          initialIndex: 2,
        ),
      ),
    );
    await _settle(tester);
    final terraform = fixture.requests.where(
      (request) =>
          _apiPath(request) == 'projects/42/packages' &&
          request.uri.queryParameters['package_type'] == 'terraform_module',
    );
    expect(terraform, isNotEmpty);
    expect(find.text('Terraform'), findsOneWidget);
  });

  testWidgets(
    'package deletion requires exact identity and verifies readback',
    (tester) async {
      final fixture = RegistryFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        _host(
          RegistriesPage(
            account: _account(fixture.api),
            api: fixture.api,
            project: _project,
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('mobile-kit'));
      await _settle(tester);
      await tester.tap(find.byTooltip('刪除套件'));
      await _settle(tester);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'mobile-kit@1.2.3',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await _settle(tester);
      expect(fixture.packageExists, isFalse);
      expect(find.text('尚無套件'), findsOneWidget);
      expect(
        fixture.requests.where(
          (request) =>
              request.method == 'DELETE' &&
              _apiPath(request) == 'projects/42/packages/11',
        ),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'container repository and tag show useful detail and verify typed delete',
    (tester) async {
      final fixture = RegistryFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(
          RegistriesPage(
            account: _account(fixture.api),
            api: fixture.api,
            project: _project,
            initialIndex: 1,
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('studio/mobile/app'), findsOneWidget);
      expect(find.textContaining('目前已載入頁面'), findsOneWidget);

      await tester.tap(find.text('studio/mobile/app'));
      await _settle(tester);
      expect(
        find.textContaining('registry.example.com/studio/mobile/app'),
        findsWidgets,
      );
      expect(find.text('v1.2.3'), findsOneWidget);
      expect(find.byTooltip('刪除 Container repository'), findsOneWidget);

      await tester.tap(find.text('v1.2.3'));
      await _settle(tester);
      expect(find.textContaining('sha256:bbbb'), findsOneWidget);
      expect(find.text('8.0 KiB'), findsOneWidget);
      await tester.tap(find.byTooltip('刪除標籤'));
      await _settle(tester);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'v1.2.3',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await _settle(tester);
      expect(fixture.tagExists, isFalse);
      expect(find.text('這個 repository 沒有標籤'), findsOneWidget);
      expect(
        fixture.requests.where(
          (request) =>
              request.method == 'DELETE' &&
              _apiPath(request).endsWith('/tags/v1.2.3'),
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('container destructive controls are hidden below Maintainer', (
    tester,
  ) async {
    final fixture = RegistryFixture(access: 30);
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        ContainerRepositoryPage(
          account: _account(fixture.api),
          api: fixture.api,
          project: _project,
          repositoryId: 22,
          initialPath: 'studio/mobile/app',
        ),
      ),
    );
    await _settle(tester);
    expect(find.byTooltip('刪除 Container repository'), findsNothing);
    expect(find.textContaining('Maintainer'), findsOneWidget);
  });

  testWidgets('container repository deletion is role checked and read back', (
    tester,
  ) async {
    final fixture = RegistryFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        RegistriesPage(
          account: _account(fixture.api),
          api: fixture.api,
          project: _project,
          initialIndex: 1,
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('studio/mobile/app'));
    await _settle(tester);
    await tester.tap(find.byTooltip('刪除 Container repository'));
    await _settle(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'studio/mobile/app',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await _settle(tester);
    expect(fixture.repositoryExists, isFalse);
    expect(find.text('尚無 Container 映像'), findsOneWidget);
    expect(
      fixture.requests.where(
        (request) =>
            request.method == 'DELETE' &&
            _apiPath(request) == 'projects/42/registry/repositories/22',
      ),
      hasLength(1),
    );
  });

  testWidgets('registry tabs remain usable at 320dp and 2x text', (
    tester,
  ) async {
    final fixture = RegistryFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        RegistriesPage(
          account: _account(fixture.api),
          api: fixture.api,
          project: _project,
        ),
        textScale: 2,
      ),
    );
    await _settle(tester);
    for (final tab in ['Container', 'Terraform', '套件']) {
      final target = find.widgetWithText(Tab, tab);
      await tester.ensureVisible(target);
      await tester.pump();
      await tester.tap(target);
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: 'tab $tab');
    }
  });

  testWidgets(
    '404 includes account, instance, resource, retry and switch actions',
    (tester) async {
      final adapter = FakeAdapter((_) => jsonResponse({}, status: 404));
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        _host(
          PackageDetailPage(
            account: _account(api),
            api: api,
            project: _project,
            packageId: 404,
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('無法開啟此資源'), findsOneWidget);
      expect(
        find.textContaining('實例：https://example.com/gitlab'),
        findsOneWidget,
      );
      expect(find.text('App 帳號：@developer'), findsOneWidget);
      expect(find.textContaining('套件 #404'), findsOneWidget);
      expect(find.text('重新整理'), findsOneWidget);
      expect(find.text('切換帳號'), findsOneWidget);
    },
  );

  for (final testCase in [
    (
      name: 'package',
      index: 0,
      oldLabel: 'old-package',
      newLabel: 'new-package',
    ),
    (
      name: 'container',
      index: 1,
      oldLabel: 'studio/mobile/old-container',
      newLabel: 'studio/mobile/new-container',
    ),
    (
      name: 'Terraform',
      index: 2,
      oldLabel: 'old-module',
      newLabel: 'new-module',
    ),
  ]) {
    testWidgets(
      '${testCase.name} list clears and reloads when only the API owner changes',
      (tester) async {
        bool isTarget(RequestOptions request) {
          final path = _apiPath(request);
          if (testCase.index == 1) {
            return path == 'projects/42/registry/repositories';
          }
          if (path != 'projects/42/packages') return false;
          final type = request.uri.queryParameters['package_type'];
          return testCase.index == 2
              ? type == 'terraform_module'
              : type == null;
        }

        ResponseBody response(String label) => testCase.index == 1
            ? jsonResponse([
                {..._repository(), 'path': label, 'location': label},
              ])
            : jsonResponse([
                _package(
                  name: label,
                  type: testCase.index == 2 ? 'terraform_module' : 'npm',
                ),
              ]);

        final pending = Completer<ResponseBody>();
        final oldApi = testApi(
          FakeAdapter(
            (request) => isTarget(request)
                ? response(testCase.oldLabel)
                : jsonResponse(<Object>[]),
          ),
        );
        final newApi = testApi(
          FakeAdapter(
            (request) =>
                isTarget(request) ? pending.future : jsonResponse(<Object>[]),
          ),
        );
        addTearDown(oldApi.close);
        addTearDown(newApi.close);

        await tester.pumpWidget(
          _host(
            RegistriesPage(
              account: _account(oldApi),
              api: oldApi,
              project: _project,
              initialIndex: testCase.index,
            ),
          ),
        );
        await _settle(tester);
        expect(find.text(testCase.oldLabel), findsOneWidget);

        await tester.pumpWidget(
          _host(
            RegistriesPage(
              account: _account(newApi),
              api: newApi,
              project: _project,
              initialIndex: testCase.index,
            ),
          ),
        );
        await tester.pump();
        expect(find.text(testCase.oldLabel), findsNothing);

        pending.complete(response(testCase.newLabel));
        await _settle(tester);
        expect(find.text(testCase.newLabel), findsOneWidget);
        expect(find.text(testCase.oldLabel), findsNothing);
      },
    );
  }

  testWidgets('late package detail response cannot replace a new account API', (
    tester,
  ) async {
    final oldDetail = Completer<ResponseBody>();
    final oldAdapter = FakeAdapter((request) {
      if (_apiPath(request) == 'projects/42/packages/11') {
        return oldDetail.future;
      }
      return jsonResponse(<Object>[]);
    });
    final newAdapter = FakeAdapter((request) {
      if (_apiPath(request) == 'projects/42/packages/11') {
        return jsonResponse(_package(name: 'new-account-package'));
      }
      return jsonResponse(<Object>[]);
    });
    final oldApi = testApi(oldAdapter);
    final newApi = testApi(newAdapter);
    addTearDown(oldApi.close);
    addTearDown(newApi.close);

    await tester.pumpWidget(
      _host(
        PackageDetailPage(
          account: _account(oldApi),
          api: oldApi,
          project: _project,
          packageId: 11,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      _host(
        PackageDetailPage(
          account: _account(newApi, id: 8, username: 'new-user'),
          api: newApi,
          project: _project,
          packageId: 11,
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('new-account-package'), findsOneWidget);
    oldDetail.complete(jsonResponse(_package(name: 'old-account-package')));
    await _settle(tester);
    expect(find.text('new-account-package'), findsOneWidget);
    expect(find.text('old-account-package'), findsNothing);
  });
}
