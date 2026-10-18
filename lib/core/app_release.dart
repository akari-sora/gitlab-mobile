import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'failure.dart';
import 'gitlab_api.dart';
import 'instance.dart';
import 'registry_models.dart';
import 'release_assets.dart';

// Plain Dart, so the public smoke (tool/public_smoke.dart) runs the same
// release discovery against GitLab.com that the gitlab flavor uses.

/// The app's own project on GitLab.com, which publishes the gitlab channel.
final updateInstance = GitLabInstance.parse('https://gitlab.com');
const updateProjectId = 86648389;
const updateProjectPath = 'aa22396584/gitlab-mobile';

/// Newest releases inspected for a gitlab-channel release build.
const updateReleaseScan = 10;
const _metadataMaximumBytes = 64 * 1024;
final _releaseApk = RegExp(r'^gitlab-mobile-[0-9a-f]{8,40}-release\.apk$');
final _sha256 = RegExp(r'^[0-9a-f]{64}$');

/// A published gitlab-channel release build and the package file of its APK.
final class AppRelease {
  const AppRelease({
    required this.tag,
    required this.versionName,
    required this.versionCode,
    required this.commit,
    required this.package,
    required this.file,
    this.webUrl,
  });
  final String tag, versionName, commit;
  final int versionCode;
  final RegistryPackage package;
  final RegistryPackageFile file;
  final Uri? webUrl;

  String get label => '$versionName ($versionCode)';
}

/// The newest release that links a gitlab-channel release APK together with
/// its `build-metadata.json`, read anonymously. The metadata names the
/// versionCode; it is downloaded within a small budget and checked against
/// the SHA-256 GitLab records for it. Older debug previews are skipped.
Future<AppRelease?> latestAppRelease(GitLabApi api, {bool Function()? isCurrent}) async {
  bool current() => isCurrent?.call() ?? true;
  final releases = await api.records(['projects', '$updateProjectId', 'releases'],
    query: const {'per_page': '$updateReleaseScan', 'order_by': 'released_at', 'sort': 'desc'});
  for (final release in releases.items.take(updateReleaseScan)) {
    if (!current()) throw const ApiFailure(FailureKind.cancelled);
    final assets = ReleaseAssets.fromJson(release['assets']);
    ReleasePackageLink? apk, metadata;
    for (final link in assets.links) {
      final parsed = parseReleasePackageLink(link.url,
        instance: updateInstance, projectId: updateProjectId, projectPath: updateProjectPath);
      if (parsed == null) continue;
      if (_releaseApk.hasMatch(parsed.fileName)) apk ??= parsed;
      if (parsed.fileName == 'build-metadata.json') metadata ??= parsed;
    }
    if (apk == null || metadata == null ||
        apk.packageName != metadata.packageName || apk.packageVersion != metadata.packageVersion) {
      continue;
    }
    final facts = await _readMetadata(api, metadata, current);
    if (facts == null) continue;
    final (package, file) = await api.releasePackageFile(updateProjectId, apk, isCurrent: current);
    if (file.size <= 0 || file.size > GitLabApi.maxArtifactBytes || !_sha256.hasMatch(file.sha256)) continue;
    final tag = release['tag_name'];
    final links = release['_links'];
    final web = links is Map ? Uri.tryParse('${links['self'] ?? ''}') : null;
    return AppRelease(
      tag: tag is String ? tag : '',
      versionName: facts.versionName,
      versionCode: facts.versionCode,
      commit: facts.commit,
      package: package,
      file: file,
      webUrl: web != null && web.hasScheme ? web : null,
    );
  }
  return null;
}

Future<({String versionName, int versionCode, String commit})?> _readMetadata(
    GitLabApi api, ReleasePackageLink link, bool Function() current) async {
  final (package, file) = await api.releasePackageFile(updateProjectId, link, isCurrent: current);
  if (file.size <= 0 || file.size > _metadataMaximumBytes || !_sha256.hasMatch(file.sha256)) return null;
  final collected = _Collect();
  final sink = IOSink(collected);
  await api.downloadPackageFile(updateProjectId, package.id, file.id,
    sink: sink, fileName: link.fileName, maxBytes: _metadataMaximumBytes);
  await sink.close();
  final bytes = collected.bytes.takeBytes();
  if (bytes.length != file.size || sha256.convert(bytes).toString() != file.sha256.toLowerCase()) {
    throw const ApiFailure(FailureKind.invalidResponse, title: '更新資訊驗證失敗',
      detail: 'build-metadata.json 的大小或 SHA-256 與 GitLab 記錄不一致。');
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  final code = json['version_code'], name = json['version_name'], commit = json['commit'];
  if (json['channel'] != 'gitlab' || json['build_type'] != 'release' ||
      code is! int || code <= 0 || name is! String || name.isEmpty) {
    return null;
  }
  return (versionName: name, versionCode: code, commit: commit is String ? commit : '');
}

final class _Collect implements StreamConsumer<List<int>> {
  final bytes = BytesBuilder(copy: false);
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(bytes.add);
  @override
  Future<void> close() async {}
}
