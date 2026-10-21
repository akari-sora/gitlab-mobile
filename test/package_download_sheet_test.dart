import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/registry_models.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';
import 'package:gitlab_mobile/shared/package_download.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _package = RegistryPackage(
  id: 12,
  name: 'mobile-kit',
  version: '1.2.3',
  type: 'generic',
  status: 'default',
  createdAt: '',
  canDelete: false,
);

RegistryPackageFile _file({
  int size = 7,
  String? sha,
  String name = 'SHA256SUMS',
}) => RegistryPackageFile(
  id: 34,
  name: name,
  size: size,
  createdAt: '',
  sha256: sha ?? sha256.convert(utf8.encode('payload')).toString(),
);

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
  token: 'synthetic-test-token',
);

Map<String, Object?> _packageJson() => {
  'id': 12,
  'name': 'mobile-kit',
  'version': '1.2.3',
  'package_type': 'generic',
  'status': 'default',
};

Map<String, Object?> _fileJson(RegistryPackageFile file) => {
  'id': file.id,
  'file_name': file.name,
  'size': file.size,
  'file_sha256': file.sha256,
};

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

GitLabApi _downloadApi(
  RegistryPackageFile file, {
  List<int> bytes = const [112, 97, 121, 108, 111, 97, 100],
}) => testApi(
  FakeAdapter((request) {
    return switch (_apiPath(request)) {
      'projects/8/packages/12' => jsonResponse(_packageJson()),
      'projects/8/packages/12/package_files' => jsonResponse([_fileJson(file)]),
      'projects/8/packages/12/package_files/34/download' => ResponseBody(
        Stream.value(Uint8List.fromList(bytes)),
        200,
        headers: {
          Headers.contentLengthHeader: ['${bytes.length}'],
        },
      ),
      _ => jsonResponse({}, status: 404),
    };
  }),
);

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

final class _ControlledDownloader implements PackageDownloader {
  _ControlledDownloader(this.future);

  final Future<File> future;
  int calls = 0;
  bool cancelled = false;

  @override
  Future<File> download({
    required int projectId,
    required RegistryPackage package,
    required RegistryPackageFile file,
    required Account account,
    required bool Function() isCurrent,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  }) async {
    calls++;
    onProgress?.call(3, file.size);
    if (cancel != null) unawaited(cancel.then((_) => cancelled = true));
    return future;
  }
}

final class _SequenceDownloader implements PackageDownloader {
  _SequenceDownloader(this.file);
  final File file;
  int calls = 0;

  @override
  Future<File> download({
    required int projectId,
    required RegistryPackage package,
    required RegistryPackageFile file,
    required Account account,
    required bool Function() isCurrent,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  }) async {
    calls++;
    if (calls == 1) throw const ApiFailure(FailureKind.network);
    onProgress?.call(file.size, file.size);
    return this.file;
  }
}

final class _GatedSharer implements ArtifactSharer {
  final started = Completer<void>();
  final release = Completer<void>();
  int calls = 0;

  @override
  Future<ShareOutcome> share(String path, {Rect? sharePositionOrigin}) async {
    calls++;
    started.complete();
    await release.future;
    return ShareOutcome.success;
  }
}

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  builder: (context, value) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: value!,
  ),
  home: Scaffold(body: child),
);

/// PackageDownloadSheet removes a finished attempt directory without awaiting
/// it, so teardown can race that removal.
Future<void> _removeAttempt(Directory attempt) async {
  try {
    await attempt.delete(recursive: true);
  } on PathNotFoundException {
    // Already removed by the sheet.
  }
}

void main() {
  late Directory root;
  late Future<Directory> Function() originalRoot;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('gitlab-package-download-');
    originalRoot = artifactStorageRoot;
    artifactStorageRoot = () async => root;
  });

  tearDown(() async {
    if (root.existsSync()) {
      for (final entry in root.listSync()) {
        await entry.delete(recursive: true);
      }
    }
    resetArtifactShareCleanup();
  });

  tearDownAll(() async {
    artifactStorageRoot = originalRoot;
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('download verifies size and sha256 before atomic promotion', () async {
    final file = _file();
    final api = _downloadApi(file);
    addTearDown(api.close);
    final result = await DefaultPackageDownloader(api: api).download(
      projectId: 8,
      package: _package,
      file: file,
      account: _account(api),
      isCurrent: () => true,
    );

    expect(result.uri.pathSegments.last, 'SHA256SUMS');
    expect(await result.readAsString(), 'payload');
    expect(
      File('${result.parent.path}/$artifactPartialName').existsSync(),
      isFalse,
    );
  });

  test('a valid empty package file is downloaded and verified', () async {
    final file = _file(
      size: 0,
      sha: sha256.convert(const <int>[]).toString(),
      name: 'empty.txt',
    );
    final api = _downloadApi(file, bytes: const []);
    addTearDown(api.close);
    final result = await DefaultPackageDownloader(api: api).download(
      projectId: 8,
      package: _package,
      file: file,
      account: _account(api),
      isCurrent: () => true,
    );
    expect(await result.length(), 0);
  });

  test('size and checksum mismatch delete every attempt file', () async {
    for (final mismatch in ['size', 'sha']) {
      final file = mismatch == 'size'
          ? _file(size: 8)
          : _file(sha: List.filled(64, '0').join());
      final api = _downloadApi(file);
      await expectLater(
        DefaultPackageDownloader(api: api).download(
          projectId: 8,
          package: _package,
          file: file,
          account: _account(api),
          isCurrent: () => true,
        ),
        throwsA(
          isA<ApiFailure>().having((error) => error.title, 'title', '套件檔案驗證失敗'),
        ),
      );
      api.close();
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    }
  });

  test('storage failure is explicit and does not begin a download', () async {
    final file = _file();
    final api = _downloadApi(file);
    addTearDown(api.close);
    await expectLater(
      DefaultPackageDownloader(
        api: api,
        attemptDirectory: (_, _) async =>
            throw const FileSystemException('synthetic storage failure'),
      ).download(
        projectId: 8,
        package: _package,
        file: file,
        account: _account(api),
        isCurrent: () => true,
      ),
      throwsA(_failure(FailureKind.network)),
    );
  });

  testWidgets('failure can retry into verified success', (tester) async {
    final api = _downloadApi(_file());
    addTearDown(api.close);
    final attempt = Directory.systemTemp.createTempSync(
      'package-sheet-success-',
    );
    final saved = File('${attempt.path}/SHA256SUMS')
      ..writeAsStringSync('payload');
    final downloader = _SequenceDownloader(saved);
    addTearDown(() async {
      await _removeAttempt(attempt);
    });
    await tester.pumpWidget(
      _host(
        PackageDownloadSheet(
          account: _account(api),
          api: api,
          projectId: 8,
          projectPath: 'studio/mobile',
          package: _package,
          file: _file(),
          isCurrent: () => true,
          downloader: downloader,
        ),
      ),
    );
    await pumpUntil(
      tester,
      () => find.text('無法連線').evaluate().isNotEmpty,
      description: 'first attempt failure',
    );
    expect(find.text('無法連線'), findsOneWidget);
    await tester.tap(find.text('重新整理'));
    await pumpUntil(
      tester,
      () => find.textContaining('已驗證並下載').evaluate().isNotEmpty,
      description: 'retry success',
    );
    expect(find.textContaining('已驗證並下載'), findsOneWidget);
    expect(downloader.calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

  testWidgets('cancel closes the sheet and signals the downloader', (
    tester,
  ) async {
    final api = _downloadApi(_file());
    addTearDown(api.close);
    final gate = Completer<File>();
    final downloader = _ControlledDownloader(gate.future);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => PackageDownloadSheet(
                account: _account(api),
                api: api,
                projectId: 8,
                projectPath: 'studio/mobile',
                package: _package,
                file: _file(),
                isCurrent: () => true,
                downloader: downloader,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(downloader.cancelled, isTrue);
    gate.completeError(const ApiFailure(FailureKind.cancelled));
    await tester.pumpAndSettle();
    expect(find.byType(PackageDownloadSheet), findsNothing);
  });

  testWidgets('owner change closes sheet and deletes a stale completed file', (
    tester,
  ) async {
    final api = _downloadApi(_file());
    addTearDown(api.close);
    final gate = Completer<File>();
    final downloader = _ControlledDownloader(gate.future);
    final owner = ChangeNotifier();
    var current = true;
    final attempt = Directory.systemTemp.createTempSync('package-sheet-stale-');
    final stale = File('${attempt.path}/SHA256SUMS')
      ..writeAsStringSync('payload');
    addTearDown(() async {
      owner.dispose();
      await _removeAttempt(attempt);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => PackageDownloadSheet(
                account: _account(api),
                api: api,
                projectId: 8,
                projectPath: 'studio/mobile',
                package: _package,
                file: _file(),
                isCurrent: () => current,
                ownerChanges: owner,
                downloader: downloader,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    current = false;
    owner.notifyListeners();
    await tester.pumpAndSettle();
    gate.complete(stale);
    await tester.pumpAndSettle();
    expect(find.byType(PackageDownloadSheet), findsNothing);
    await pumpUntil(
      tester,
      () => !stale.existsSync(),
      description: 'stale completed download cleanup',
    );
    expect(stale.existsSync(), isFalse);
  });

  testWidgets(
    'owner change during share suppresses stale success and cleans file',
    (tester) async {
      final api = _downloadApi(_file());
      addTearDown(api.close);
      final owner = ChangeNotifier();
      var current = true;
      final attempt = Directory.systemTemp.createTempSync(
        'package-sheet-share-',
      );
      final saved = File('${attempt.path}/SHA256SUMS')
        ..writeAsStringSync('payload');
      final sharer = _GatedSharer();
      addTearDown(() async {
        if (!sharer.release.isCompleted) sharer.release.complete();
        owner.dispose();
        await _removeAttempt(attempt);
      });
      await tester.pumpWidget(
        _host(
          PackageDownloadSheet(
            account: _account(api),
            api: api,
            projectId: 8,
            projectPath: 'studio/mobile',
            package: _package,
            file: _file(),
            isCurrent: () => current,
            ownerChanges: owner,
            downloader: _ControlledDownloader(Future.value(saved)),
            sharer: sharer,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('開啟／分享'));
      await sharer.started.future;
      current = false;
      owner.notifyListeners();
      sharer.release.complete();
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () => !saved.existsSync(),
        description: 'stale shared download cleanup',
      );
      expect(saved.existsSync(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity replacement fences a pending share from the new attempt',
    (tester) async {
      final api = _downloadApi(_file());
      addTearDown(api.close);
      final firstDirectory = Directory.systemTemp.createTempSync(
        'package-share-old-',
      );
      final secondDirectory = Directory.systemTemp.createTempSync(
        'package-share-new-',
      );
      final first = File('${firstDirectory.path}/SHA256SUMS')
        ..writeAsStringSync('payload');
      final second = File('${secondDirectory.path}/SHA256SUMS')
        ..writeAsStringSync('payload');
      final firstDownloader = _ControlledDownloader(Future.value(first));
      final secondDownloader = _ControlledDownloader(Future.value(second));
      final sharer = _GatedSharer();
      final identity = ValueNotifier<int>(12);
      addTearDown(() async {
        if (!sharer.release.isCompleted) sharer.release.complete();
        identity.dispose();
        await _removeAttempt(firstDirectory);
        await _removeAttempt(secondDirectory);
      });
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder<int>(
            valueListenable: identity,
            builder: (context, packageId, _) => PackageDownloadSheet(
              account: _account(api),
              api: api,
              projectId: 8,
              projectPath: 'studio/mobile',
              package: RegistryPackage(
                id: packageId,
                name: 'mobile-kit-$packageId',
                version: '1.2.3',
                type: 'generic',
                status: 'default',
                createdAt: '',
                canDelete: false,
              ),
              file: _file(),
              isCurrent: () => true,
              downloader: packageId == 12 ? firstDownloader : secondDownloader,
              sharer: sharer,
            ),
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => find.textContaining('已驗證並下載').evaluate().isNotEmpty,
        description: 'old identity success',
      );
      await tester.tap(find.text('開啟／分享'));
      await sharer.started.future;
      identity.value = 13;
      await pumpUntil(
        tester,
        () => secondDownloader.calls == 1,
        description: 'new identity attempt',
      );
      sharer.release.complete();
      await pumpUntil(
        tester,
        () => find.textContaining('已驗證並下載').evaluate().isNotEmpty,
        description: 'new identity success',
      );
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isTrue);
      expect(find.byType(PackageDownloadSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sheet fits 320dp at 2x text without overflow', (tester) async {
    final api = _downloadApi(_file());
    addTearDown(api.close);
    final gate = Completer<File>();
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.completeError(const ApiFailure(FailureKind.cancelled));
      }
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        PackageDownloadSheet(
          account: _account(api),
          api: api,
          projectId: 8,
          projectPath: 'studio/mobile',
          package: _package,
          file: _file(),
          isCurrent: () => true,
          downloader: _ControlledDownloader(gate.future),
        ),
        textScale: 2,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('package-download-progress')), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
