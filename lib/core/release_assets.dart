import 'instance.dart';

/// Most links a release detail lists; GitLab paginates nothing here.
const releaseAssetMaximumLinks = 100;

/// One `assets.links` entry of a release.
final class ReleaseAssetLink {
  const ReleaseAssetLink({required this.id, required this.name, required this.url, required this.linkType});
  final int id;
  final String name;
  final Uri url;

  /// `other`, `runbook`, `image` or `package`; empty when GitLab omits it.
  final String linkType;
}

/// One `assets.sources` archive, such as `zip` or `tar.gz`.
final class ReleaseSource {
  const ReleaseSource({required this.format, required this.url});
  final String format;
  final Uri url;
}

final class ReleaseAssets {
  const ReleaseAssets({this.links = const [], this.sources = const []});

  /// Reads a release's `assets` object. Entries without a name or an absolute
  /// URL are skipped rather than failing the whole release.
  factory ReleaseAssets.fromJson(Object? assets) {
    if (assets is! Map<String, dynamic>) return const ReleaseAssets();
    final links = <ReleaseAssetLink>[];
    final rawLinks = assets['links'];
    if (rawLinks is List) {
      for (final value in rawLinks) {
        if (links.length >= releaseAssetMaximumLinks) break;
        if (value is! Map<String, dynamic>) continue;
        final name = value['name'], url = _absolute(value['url']);
        if (name is! String || name.trim().isEmpty || url == null) continue;
        final id = value['id'], type = value['link_type'];
        links.add(ReleaseAssetLink(
          id: id is int ? id : 0,
          name: name.trim(),
          url: url,
          linkType: type is String ? type : '',
        ));
      }
    }
    final sources = <ReleaseSource>[];
    final rawSources = assets['sources'];
    if (rawSources is List) {
      for (final value in rawSources) {
        if (value is! Map<String, dynamic>) continue;
        final format = value['format'], url = _absolute(value['url']);
        if (format is! String || format.isEmpty || url == null) continue;
        sources.add(ReleaseSource(format: format, url: url));
      }
    }
    return ReleaseAssets(links: links, sources: sources);
  }

  final List<ReleaseAssetLink> links;
  final List<ReleaseSource> sources;
  bool get isEmpty => links.isEmpty && sources.isEmpty;
}

Uri? _absolute(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value.trim());
  return uri != null && uri.hasScheme && uri.host.isNotEmpty ? uri : null;
}

/// A release link that names a generic package file of the release's own
/// project, so the app can fetch it through the Packages API and check the
/// SHA-256 GitLab records for it.
final class ReleasePackageLink {
  const ReleasePackageLink({required this.packageName, required this.packageVersion, required this.fileName});
  final String packageName, packageVersion, fileName;
}

/// Recognises `{api}/projects/{project}/packages/generic/{name}/{version}/{file}`
/// on [instance] when `{project}` is [projectId] or [projectPath]. Another
/// project, another host or any other endpoint is null.
ReleasePackageLink? parseReleasePackageLink(
  Uri uri, {
  required GitLabInstance instance,
  required int projectId,
  required String projectPath,
}) {
  try {
    if (!instance.allowsApi(uri)) return null;
    final prefix = instance.api(const []).pathSegments.length;
    final rest = uri.pathSegments.sublist(prefix);
    if (rest.length != 7 || rest[0] != 'projects' || rest[2] != 'packages' || rest[3] != 'generic') {
      return null;
    }
    final project = rest[1];
    if (project != '$projectId' && project.toLowerCase() != projectPath.toLowerCase()) return null;
    final name = rest[4], version = rest[5], file = rest[6];
    if (name.isEmpty || version.isEmpty || file.isEmpty || file.contains('/')) return null;
    return ReleasePackageLink(packageName: name, packageVersion: version, fileName: file);
  } catch (_) {
    // Escapes that are not UTF-8 make pathSegments throw.
    return null;
  }
}
