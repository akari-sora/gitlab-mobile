import 'instance.dart';

Map<String, dynamic> objectJson(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException('Expected object');
  return value;
}
int requiredInt(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value is! int || value <= 0) throw FormatException('Missing $key');
  return value;
}
String requiredString(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value is! String || value.isEmpty) throw FormatException('Missing $key');
  return value;
}
String? optionalString(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $key');
  return value;
}

final class GitLabUser {
  const GitLabUser({required this.id, required this.username, required this.name});
  factory GitLabUser.fromJson(Map<String, dynamic> j) => GitLabUser(
    id: requiredInt(j, 'id'), username: requiredString(j, 'username'),
    name: optionalString(j, 'name') ?? requiredString(j, 'username'),
  );
  final int id;
  final String username;
  final String name;
  Map<String, Object> toJson() => {'id': id, 'username': username, 'name': name};
}

final class Account {
  const Account({required this.instance, required this.user, required this.token});
  final GitLabInstance instance;
  final GitLabUser user;
  // This is deliberately excluded from toString and diagnostic output.
  final String token;
  String get key => '${instance.key}#${user.id}';
  Map<String, Object> toSecureJson() => {
    'instance': instance.key, 'user': user.toJson(), 'token': token,
  };
  factory Account.fromSecureJson(Map<String, dynamic> j) => Account(
    instance: GitLabInstance.parse(requiredString(j, 'instance')),
    user: GitLabUser.fromJson(objectJson(j['user'])),
    token: requiredString(j, 'token'),
  );
  @override
  String toString() => 'Account(${instance.key}, userId: ${user.id})';
}

final class Project {
  const Project({required this.id, required this.name, required this.path,
    this.description, this.visibility, this.defaultBranch, this.archived});
  factory Project.fromJson(Map<String, dynamic> j) => Project(
    id: requiredInt(j, 'id'), name: requiredString(j, 'name'),
    path: requiredString(j, 'path_with_namespace'),
    description: optionalString(j, 'description'),
    visibility: optionalString(j, 'visibility'),
    defaultBranch: optionalString(j, 'default_branch'),
    archived: j['archived'] as bool?,
  );
  final int id;
  final String name;
  final String path;
  final String? description;
  final String? visibility;
  final String? defaultBranch;
  final bool? archived;
  String get visibilityLabel => switch (visibility) {
    'private' => '私有', 'internal' => '內部', 'public' => '公開',
    null => '可見性未知', _ => '其他可見性',
  };
}

final class TreeEntry {
  const TreeEntry({required this.name, required this.path, required this.type});
  factory TreeEntry.fromJson(Map<String, dynamic> j) => TreeEntry(
    name: requiredString(j, 'name'), path: requiredString(j, 'path'),
    type: requiredString(j, 'type'),
  );
  final String name;
  final String path;
  final String type;
  bool get isDirectory => type == 'tree';
  bool get isTextCandidate => type == 'blob';
}

final class ApiPage<T> {
  const ApiPage(this.items, {this.next});
  final List<T> items;
  final Uri? next;
}
