String _string(Map<String, dynamic> json, String key) =>
    json[key] is String ? json[key] as String : '';
int _integer(Map<String, dynamic> json, String key) =>
    json[key] is int ? json[key] as int : 0;

/// A package returned by the project Packages API.
final class RegistryPackage {
  const RegistryPackage({
    required this.id,
    required this.name,
    required this.version,
    required this.type,
    required this.status,
    required this.createdAt,
    required this.canDelete,
  });

  factory RegistryPackage.fromJson(Map<String, dynamic> json) {
    final id = _integer(json, 'id');
    final name = _string(json, 'name');
    if (id <= 0 || name.isEmpty) throw const FormatException('Invalid package');
    final links = json['_links'];
    return RegistryPackage(
      id: id,
      name: name,
      version: _string(json, 'version'),
      type: _string(json, 'package_type'),
      status: _string(json, 'status'),
      createdAt: _string(json, 'created_at'),
      canDelete:
          links is Map<String, dynamic> &&
          _string(links, 'delete_api_path').isNotEmpty,
    );
  }

  final int id;
  final String name, version, type, status, createdAt;
  final bool canDelete;
  String get identity => '$name@${version.isEmpty ? 'versionless' : version}';
}

final class RegistryPackageFile {
  const RegistryPackageFile({
    required this.id,
    required this.name,
    required this.size,
    required this.createdAt,
    required this.sha256,
  });

  factory RegistryPackageFile.fromJson(Map<String, dynamic> json) {
    final id = _integer(json, 'id');
    final name = _string(json, 'file_name');
    if (id <= 0 || name.isEmpty) {
      throw const FormatException('Invalid package file');
    }
    return RegistryPackageFile(
      id: id,
      name: name,
      size: _integer(json, 'size'),
      createdAt: _string(json, 'created_at'),
      sha256: _string(json, 'file_sha256'),
    );
  }

  final int id, size;
  final String name, createdAt, sha256;
}

final class ContainerRepository {
  const ContainerRepository({
    required this.id,
    required this.name,
    required this.path,
    required this.location,
    required this.createdAt,
    required this.status,
    required this.tagsCount,
    required this.size,
  });

  factory ContainerRepository.fromJson(Map<String, dynamic> json) {
    final id = _integer(json, 'id');
    final path = _string(json, 'path');
    if (id <= 0 || path.isEmpty) {
      throw const FormatException('Invalid registry repository');
    }
    return ContainerRepository(
      id: id,
      name: _string(json, 'name'),
      path: path,
      location: _string(json, 'location'),
      createdAt: _string(json, 'created_at'),
      status: _string(json, 'status'),
      tagsCount: _integer(json, 'tags_count'),
      size: _integer(json, 'size'),
    );
  }

  final int id, tagsCount, size;
  final String name, path, location, createdAt, status;
}

final class ContainerTag {
  const ContainerTag({
    required this.name,
    required this.path,
    required this.location,
    required this.digest,
    required this.revision,
    required this.createdAt,
    required this.size,
  });

  factory ContainerTag.fromJson(Map<String, dynamic> json) {
    final name = _string(json, 'name');
    if (name.isEmpty) throw const FormatException('Invalid registry tag');
    return ContainerTag(
      name: name,
      path: _string(json, 'path'),
      location: _string(json, 'location'),
      digest: _string(json, 'digest'),
      revision: _string(json, 'revision'),
      createdAt: _string(json, 'created_at'),
      size: _integer(json, 'total_size'),
    );
  }

  final String name, path, location, digest, revision, createdAt;
  final int size;
}

String packageTypeLabel(String type) => switch (type) {
  'composer' => 'Composer',
  'conan' => 'Conan',
  'generic' => 'Generic',
  'golang' => 'Go',
  'helm' => 'Helm',
  'maven' => 'Maven',
  'npm' => 'npm',
  'nuget' => 'NuGet',
  'pypi' => 'PyPI',
  'terraform_module' => 'Terraform Module',
  '' => '未知類型',
  _ => type,
};

String registryBytes(int bytes) {
  if (bytes <= 0) return '大小未知';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble(), unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 10 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
