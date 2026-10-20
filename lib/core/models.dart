import 'instance.dart';

import 'failure.dart';
import '../l10n/l10n.dart';
export 'test_report.dart';


Map<String, dynamic> objectJson(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected object');
  }
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
  const GitLabUser({
    required this.id,
    required this.username,
    required this.name,
  });
  factory GitLabUser.fromJson(Map<String, dynamic> j) => GitLabUser(
    id: requiredInt(j, 'id'),
    username: requiredString(j, 'username'),
    name: optionalString(j, 'name') ?? requiredString(j, 'username'),
  );
  final int id;
  final String username;
  final String name;
  Map<String, Object> toJson() => {
    'id': id,
    'username': username,
    'name': name,
  };
}

sealed class AccountCredential {
  String get accessToken;
}

final class PatCredential implements AccountCredential {
  const PatCredential(this.token);
  final String token;
  @override
  String get accessToken => token;
}

final class OAuthCredential implements AccountCredential {
  const OAuthCredential({
    required this.accessToken,
    required this.refreshToken,
    required this.clientId,
    this.expiresAt,
  });
  @override
  final String accessToken;
  final String refreshToken;
  final String clientId;
  final DateTime? expiresAt;

  factory OAuthCredential.fromTokenResponse(
    Map<String, dynamic> json, {
    required String clientId,
  }) {
    final access = requiredString(json, 'access_token');
    final refresh = requiredString(json, 'refresh_token');
    _rejectBlankToken(access);
    _rejectBlankToken(refresh);
    final expiresIn = json['expires_in'];
    DateTime? expiresAt;
    if (expiresIn is int && expiresIn > 0) {
      expiresAt = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
    }
    return OAuthCredential(
      accessToken: access,
      refreshToken: refresh,
      clientId: clientId,
      expiresAt: expiresAt,
    );
  }

  OAuthCredential replacedBy(OAuthCredential next) => OAuthCredential(
    accessToken: next.accessToken,
    refreshToken: next.refreshToken,
    clientId: clientId,
    expiresAt: next.expiresAt,
  );
}

void _rejectBlankToken(String value) {
  if (value.trim().isEmpty || RegExp(r'\s').hasMatch(value)) {
    throw InputFormatException(l10n.tokenCannotBeBlank);
  }
}

final class Account {
  Account({
    required this.instance,
    required this.user,
    String? token,
    AccountCredential? credential,
  }) : credential =
           credential ?? PatCredential(token ?? (throw ArgumentError('token')));
  final GitLabInstance instance;
  final GitLabUser user;
  final AccountCredential credential;
  // Deliberately excluded from toString and diagnostic output.
  String get token => credential.accessToken;
  String get key => '${instance.key}#${user.id}';
  Map<String, Object> toSecureJson() {
    final base = <String, Object>{
      'instance': instance.key,
      'user': user.toJson(),
    };
    return switch (credential) {
      PatCredential(:final token) => {...base, 'kind': 'pat', 'token': token},
      OAuthCredential(
        :final accessToken,
        :final refreshToken,
        :final clientId,
        :final expiresAt,
      ) =>
        {
          ...base,
          'kind': 'oauth',
          'access_token': accessToken,
          'refresh_token': refreshToken,
          'client_id': clientId,
          if (expiresAt != null)
            'expires_at': expiresAt.toUtc().toIso8601String(),
        },
    };
  }

  factory Account.fromSecureJson(Map<String, dynamic> j) {
    final instance = GitLabInstance.parse(requiredString(j, 'instance'));
    final user = GitLabUser.fromJson(objectJson(j['user']));
    final kind = optionalString(j, 'kind') ?? 'pat';
    if (kind == 'oauth') {
      final expires = optionalString(j, 'expires_at');
      return Account(
        instance: instance,
        user: user,
        credential: OAuthCredential(
          accessToken: requiredString(j, 'access_token'),
          refreshToken: requiredString(j, 'refresh_token'),
          clientId: requiredString(j, 'client_id'),
          expiresAt: expires == null ? null : DateTime.parse(expires).toUtc(),
        ),
      );
    }
    if (kind != 'pat') throw const FormatException('Unsupported account store');
    return Account(
      instance: instance,
      user: user,
      token: requiredString(j, 'token'),
    );
  }
  @override
  String toString() => 'Account(${instance.key}, userId: ${user.id})';
}

String? _markedForDeletionOn(Map<String, dynamic> json) {
  final value = optionalString(json, 'marked_for_deletion_on');
  if (value == null || value.isEmpty) return null;
  return value;
}

final class Project {
  const Project({
    required this.id,
    required this.name,
    required this.path,
    this.description,
    this.visibility,
    this.defaultBranch,
    this.archived,
    this.markedForDeletionOn,
  });
  factory Project.fromJson(Map<String, dynamic> j) => Project(
    id: requiredInt(j, 'id'),
    name: requiredString(j, 'name'),
    path: requiredString(j, 'path_with_namespace'),
    description: optionalString(j, 'description'),
    visibility: optionalString(j, 'visibility'),
    defaultBranch: optionalString(j, 'default_branch'),
    archived: j['archived'] as bool?,
    markedForDeletionOn: _markedForDeletionOn(j),
  );
  final int id;
  final String name;
  final String path;
  final String? description;
  final String? visibility;
  final String? defaultBranch;
  final bool? archived;
  final String? markedForDeletionOn;
  String get visibilityLabel => switch (visibility) {
    'private' => l10n.visibilityPrivate,
    'internal' => l10n.visibilityInternal,
    'public' => l10n.visibilityPublic,
    null => l10n.visibilityUnknown,
    _ => l10n.visibilityOther,
  };
}

final class TreeEntry {
  const TreeEntry({required this.name, required this.path, required this.type});
  factory TreeEntry.fromJson(Map<String, dynamic> j) => TreeEntry(
    name: requiredString(j, 'name'),
    path: requiredString(j, 'path'),
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

