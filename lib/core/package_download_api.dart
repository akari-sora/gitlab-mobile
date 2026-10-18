part of 'gitlab_api.dart';

const _packageDownloadPageSize = 100;
const _packageDownloadMaximumRows = 200;
const _packageDownloadMaximumPages = 10;
final _packageDownloadSha256 = RegExp(r'^[0-9a-f]{64}$');

extension PackageDownloadApi on GitLabApi {
  /// Re-reads the package and its files before a download so a stale list row
  /// cannot select a different server object after an account or package change.
  Future<RegistryPackageFile> packageFileForDownload(
    int project,
    RegistryPackage expectedPackage,
    RegistryPackageFile expectedFile, {
    required bool Function() isCurrent,
  }) async {
    if (project <= 0 || expectedPackage.id <= 0 || expectedFile.id <= 0) {
      throw const ApiFailure(FailureKind.validation);
    }
    _requirePackageDownloadOwner(isCurrent);
    final package = await record([
      'projects',
      '$project',
      'packages',
      '${expectedPackage.id}',
    ]);
    _requirePackageDownloadOwner(isCurrent);

    final freshPackage = _parseDownloadPackage(package);
    if (freshPackage.id != expectedPackage.id) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    if (freshPackage.type.isEmpty) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    if (freshPackage.name != expectedPackage.name ||
        freshPackage.type != expectedPackage.type ||
        freshPackage.version != expectedPackage.version) {
      throw const ApiFailure(FailureKind.conflict);
    }

    final path = [
      'projects',
      '$project',
      'packages',
      '${expectedPackage.id}',
      'package_files',
    ];
    final issued = <String>{};
    final seenIds = <int>{};
    RegistryPackageFile? selected;
    Uri? next;
    var inspected = 0, pages = 0;
    while (true) {
      pages++;
      if (pages > _packageDownloadMaximumPages) {
        throw const ApiFailure(FailureKind.unsupported);
      }
      _requirePackageDownloadOwner(isCurrent);
      final page = await records(
        path,
        query: const {'per_page': '$_packageDownloadPageSize'},
        next: next,
      );
      _requirePackageDownloadOwner(isCurrent);
      if (page.items.length > _packageDownloadPageSize) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      for (final value in page.items) {
        inspected++;
        if (inspected > _packageDownloadMaximumRows) {
          throw const ApiFailure(FailureKind.unsupported);
        }
        final file = _parseDownloadFile(value);
        if (!seenIds.add(file.id)) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
        if (file.id == expectedFile.id) selected = file;
      }
      if (selected != null) break;
      next = page.next;
      if (next == null) break;
      if (inspected >= _packageDownloadMaximumRows) {
        throw const ApiFailure(FailureKind.unsupported);
      }
      if (!issued.add(next.toString())) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
    }
    _requirePackageDownloadOwner(isCurrent);
    final file = selected;
    if (file == null) {
      throw const ApiFailure(FailureKind.conflict);
    }
    if (file.size < 0 || file.size > GitLabApi.maxArtifactBytes) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    if (!_packageDownloadSha256.hasMatch(file.sha256)) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    if (file.name != expectedFile.name ||
        file.size != expectedFile.size ||
        file.sha256 != expectedFile.sha256) {
      throw const ApiFailure(FailureKind.conflict);
    }
    return file;
  }

  /// Finds the generic package file a release link names. GitLab serves the
  /// newest package and file when a name was published more than once, so the
  /// highest IDs win. The download then re-reads both through
  /// [packageFileForDownload] and checks the file's SHA-256.
  Future<(RegistryPackage, RegistryPackageFile)> releasePackageFile(
    int project,
    ReleasePackageLink link, {
    required bool Function() isCurrent,
  }) async {
    if (project <= 0) throw const ApiFailure(FailureKind.validation);
    RegistryPackage? package;
    await _boundedPackagePages(
      ['projects', '$project', 'packages'],
      {
        'package_type': 'generic',
        'package_name': link.packageName,
        'package_version': link.packageVersion,
      },
      isCurrent,
      (value) {
        final candidate = _parseDownloadPackage(value);
        if (candidate.type == 'generic' &&
            candidate.name == link.packageName &&
            candidate.version == link.packageVersion &&
            candidate.id > (package?.id ?? 0)) {
          package = candidate;
        }
      },
    );
    final found = package;
    if (found == null) throw const ApiFailure(FailureKind.invisible);
    RegistryPackageFile? file;
    await _boundedPackagePages(
      ['projects', '$project', 'packages', '${found.id}', 'package_files'],
      const {},
      isCurrent,
      (value) {
        final candidate = _parseDownloadFile(value);
        if (candidate.name == link.fileName && candidate.id > (file?.id ?? 0)) {
          file = candidate;
        }
      },
    );
    final selected = file;
    if (selected == null) throw const ApiFailure(FailureKind.invisible);
    _requirePackageDownloadOwner(isCurrent);
    return (found, selected);
  }

  Future<void> _boundedPackagePages(
    List<String> path,
    Map<String, String> query,
    bool Function() isCurrent,
    void Function(Map<String, dynamic> value) visit,
  ) async {
    final issued = <String>{};
    Uri? next;
    var inspected = 0, pages = 0;
    while (true) {
      if (++pages > _packageDownloadMaximumPages) {
        throw const ApiFailure(FailureKind.unsupported);
      }
      _requirePackageDownloadOwner(isCurrent);
      final page = await records(
        path,
        query: {...query, 'per_page': '$_packageDownloadPageSize'},
        next: next,
      );
      _requirePackageDownloadOwner(isCurrent);
      if (page.items.length > _packageDownloadPageSize) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      for (final value in page.items) {
        if (++inspected > _packageDownloadMaximumRows) {
          throw const ApiFailure(FailureKind.unsupported);
        }
        visit(value);
      }
      next = page.next;
      if (next == null) return;
      if (!issued.add(next.toString())) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
    }
  }

  Future<ArtifactDownload> downloadPackageFile(
    int project,
    int package,
    int file, {
    required IOSink sink,
    required String fileName,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
    int maxBytes = GitLabApi.maxArtifactBytes,
  }) {
    final result = Completer<ArtifactDownload>();
    runZonedGuarded(
      () {
        _downloadPackageFile(
          project,
          package,
          file,
          sink: sink,
          fileName: fileName,
          onProgress: onProgress,
          cancel: cancel,
          maxBytes: maxBytes,
        ).then(
          (value) {
            if (!result.isCompleted) result.complete(value);
          },
          onError: (Object error, StackTrace stack) {
            if (!result.isCompleted) {
              result.completeError(_artifactEscape(error), stack);
            }
          },
        );
      },
      (Object error, StackTrace stack) {
        if (!result.isCompleted) {
          result.completeError(_artifactEscape(error), stack);
        }
      },
    );
    return result.future;
  }

  Future<ArtifactDownload> _downloadPackageFile(
    int project,
    int package,
    int file, {
    required IOSink sink,
    required String fileName,
    required void Function(int received, int? total)? onProgress,
    required Future<void>? cancel,
    required int maxBytes,
  }) async {
    final safeName = _singlePathSegment(fileName);
    if (project <= 0 ||
        package <= 0 ||
        file <= 0 ||
        safeName == null ||
        safeName != fileName ||
        maxBytes <= 0 ||
        maxBytes > GitLabApi.maxArtifactBytes) {
      throw const ApiFailure(FailureKind.validation);
    }
    if (_closed) throw const ApiFailure(FailureKind.cancelled);
    final until = _retryAt;
    if (until != null && DateTime.now().isBefore(until)) {
      throw ApiFailure(FailureKind.rateLimited, status: 429, retryAt: until);
    }
    final uri = instance.api([
      'projects',
      '$project',
      'packages',
      '$package',
      'package_files',
      '$file',
      'download',
    ]);
    if (!instance.allowsApi(uri)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final token = CancelToken();
    _requests.add(token);
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          if (!token.isCancelled) token.cancel('package download aborted');
        }),
      );
    }
    try {
      final first = await _artifactResponse(uri, token, authenticated: true);
      final downloaded = await _consumeArtifact(
        response: first,
        requestUri: uri,
        allowRedirect: true,
        allowRefresh: true,
        token: token,
        job: file,
        sink: sink,
        maxBytes: maxBytes,
        onProgress: onProgress,
      );
      return ArtifactDownload(
        fileName: fileName,
        bytesWritten: downloaded.bytesWritten,
        contentType: downloaded.contentType,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel ||
          _closed ||
          token.isCancelled) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    } on ApiFailure {
      rethrow;
    } catch (_) {
      if (_closed || token.isCancelled) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      rethrow;
    } finally {
      _requests.remove(token);
    }
  }

  void _requirePackageDownloadOwner(bool Function() isCurrent) {
    if (_closed || !isCurrent()) {
      throw const ApiFailure(FailureKind.cancelled);
    }
  }
}

RegistryPackage _parseDownloadPackage(Map<String, dynamic> value) {
  if (value['package_type'] is! String ||
      (value['version'] != null && value['version'] is! String)) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  try {
    return RegistryPackage.fromJson(value);
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

RegistryPackageFile _parseDownloadFile(Map<String, dynamic> value) {
  if (value['size'] is! int || value['file_sha256'] is! String) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  try {
    return RegistryPackageFile.fromJson(value);
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}
