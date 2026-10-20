import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/app_release.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../shared/package_download.dart' show hashPackageFile;

import '../../l10n/l10n.dart';
export '../../core/app_release.dart';

/// Where this build came from, which decides how it updates: from this
/// project's GitLab releases, through Google Play, or not at all (local and
/// iOS builds). The Android product flavor reaches Dart as [appFlavor].
enum UpdateChannel { gitlab, play, none }

UpdateChannel updateChannelFor(String? flavor, TargetPlatform platform) {
  if (platform != TargetPlatform.android) return UpdateChannel.none;
  return switch (flavor) {
    'gitlab' => UpdateChannel.gitlab,
    'play' => UpdateChannel.play,
    _ => UpdateChannel.none,
  };
}

UpdateChannel get currentUpdateChannel => updateChannelFor(appFlavor, defaultTargetPlatform);


/// Downloads [release]'s APK into [directory] (the app cache's `updates/`,
/// emptied first), re-reading the package file and checking the size and
/// SHA-256 GitLab records before the file gets its final name.
Future<File> downloadAppRelease(
  GitLabApi api,
  AppRelease release,
  Directory directory, {
  void Function(int received, int? total)? onProgress,
  Future<void>? cancel,
  Future<String> Function(File file) hash = hashPackageFile,
}) async {
  await clearUpdateDirectory(directory);
  await directory.create(recursive: true);
  final partial = File('${directory.path}/download.partial');
  final target = File('${directory.path}/gitlab-mobile-${release.versionCode}.apk');
  try {
    final fresh = await api.packageFileForDownload(updateProjectId, release.package, release.file,
      isCurrent: () => true);
    final sink = partial.openWrite();
    try {
      await api.downloadPackageFile(updateProjectId, release.package.id, fresh.id,
        sink: sink, fileName: release.file.name, onProgress: onProgress, cancel: cancel,
        maxBytes: GitLabApi.maxArtifactBytes);
    } finally {
      await sink.close();
    }
    if (await partial.length() != fresh.size) {
      throw ApiFailure(FailureKind.invalidResponse, title: l10n.updateFileVerifyFailed,
        detail: l10n.downloadSizeMismatchDeleted);
    }
    if ((await hash(partial)).toLowerCase() != fresh.sha256.toLowerCase()) {
      throw ApiFailure(FailureKind.invalidResponse, title: l10n.updateFileVerifyFailed,
        detail: l10n.downloadSha256MismatchDeleted);
    }
    return await partial.rename(target.path);
  } catch (error) {
    await clearUpdateDirectory(directory);
    if (error is ApiFailure) rethrow;
    if (error is FileSystemException) throw ApiFailure.artifactStorage;
    throw safeFailure(error);
  }
}

/// Removes every file an earlier update left behind.
Future<void> clearUpdateDirectory(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // The operating system may already have purged the cache.
  }
}
