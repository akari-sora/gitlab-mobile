import 'dart:typed_data';

import 'failure.dart';
import 'gitlab_api.dart';
import 'models.dart';

final class ReaderOwner {
  const ReaderOwner({
    required this.accountKey,
    required this.generation,
    required this.instanceKey,
    required this.projectId,
    required this.sha,
    required this.subPath,
    this.snapshotId,
  });
  final String accountKey;
  final int generation;
  final String instanceKey;
  final int projectId;
  final String sha;
  final String? snapshotId;
  final String subPath;
}

final class ReaderCapabilities {
  const ReaderCapabilities({
    required this.edit,
    required this.history,
    required this.blame,
    required this.refresh,
    required this.ai,
    required this.webFallback,
    required this.share,
  });
  final bool edit;
  final bool history;
  final bool blame;
  final bool refresh;
  final bool ai;
  final bool webFallback;
  final bool share;
}

enum RepositoryEntryState {
  available,
  pending,
  tooLarge,
  binary,
  missing,
  mismatch,
  symlink,
  submodule,
  unsupportedType,
}

abstract interface class RepositoryReader {
  ReaderOwner get owner;
  ReaderCapabilities get capabilities;
  Future<ApiPage<Json>> tree(String path, {Uri? next});
  Future<String> text(String path);
  Future<Uint8List> bytes(String path, {int maxBytes = 10 * 1024 * 1024});
  Future<RepositoryEntryState> entryState(String path);
}

/// Wraps exactly the online repository screen's existing calls and query.
final class OnlineRepositoryReader implements RepositoryReader {
  OnlineRepositoryReader({required this.api, required this.owner});
  final GitLabApi api;
  @override
  final ReaderOwner owner;
  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities(
    edit: true,
    history: true,
    blame: true,
    refresh: true,
    ai: true,
    webFallback: true,
    share: true,
  );

  void _checkOwner() {
    if (api.instance.key != owner.instanceKey ||
        !api.isReadCacheBound ||
        api.readCacheAccountKey != owner.accountKey ||
        api.readCacheGeneration != owner.generation) {
      throw const ApiFailure(FailureKind.cancelled);
    }
  }

  @override
  Future<ApiPage<Json>> tree(String path, {Uri? next}) async {
    _checkOwner();
    final page = await api.records(
      ['projects', '${owner.projectId}', 'repository', 'tree'],
      query: {'ref': owner.sha, 'path': path, 'per_page': '50'},
      next: next,
    );
    _checkOwner();
    return page;
  }

  @override
  Future<String> text(String path) async {
    _checkOwner();
    final value = await api.textFile(owner.projectId, owner.sha, path);
    _checkOwner();
    return value;
  }

  @override
  Future<Uint8List> bytes(
    String path, {
    int maxBytes = 10 * 1024 * 1024,
  }) async {
    _checkOwner();
    final value = await api.rawFileBytes(
      '${owner.projectId}',
      owner.sha,
      path,
      maxBytes: maxBytes,
    );
    _checkOwner();
    return value;
  }

  @override
  Future<RepositoryEntryState> entryState(String path) async {
    _checkOwner();
    return RepositoryEntryState.available;
  }
}
