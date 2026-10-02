/// An instance includes its installation subpath, not only its hostname.
final class GitLabInstance {
  GitLabInstance._(this.base);
  final Uri base;

  factory GitLabInstance.parse(String input) {
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('請輸入 HTTPS GitLab 網址，不含帳密、查詢或片段。');
    }
    // Reject ambiguous paths before Uri normalization can hide traversal.
    final rawPath =
        RegExp(
          r'^https://[^/]+(.*)$',
          caseSensitive: false,
        ).firstMatch(text.contains('://') ? text : 'https://$text')?.group(1) ??
        '';
    if (rawPath.contains('\\') ||
        RegExp(r'%(2f|5c|2e)', caseSensitive: false).hasMatch(rawPath) ||
        rawPath.split('/').any((s) => s == '.' || s == '..') ||
        rawPath.contains('//')) {
      throw const FormatException('實例路徑不可包含相對路徑或編碼分隔符。');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return GitLabInstance._(
      Uri(
        scheme: 'https',
        host: uri.host.toLowerCase(),
        port: uri.port == 443 ? null : uri.port,
        pathSegments: segments,
      ),
    );
  }

  String get key => base.toString().replaceFirst(RegExp(r'/$'), '');
  List<String> get _prefix => [
    ...base.pathSegments.where((s) => s.isNotEmpty),
    'api',
    'v4',
  ];

  /// Each logical segment is encoded once. A project namespace or file path
  /// can contain slashes while still being ONE endpoint parameter.
  Uri api(List<String> segments, [Map<String, String>? query]) => Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.port == 443 ? null : base.port,
    pathSegments: [..._prefix, ...segments],
    queryParameters: query,
  );

  /// GraphQL has a separate endpoint, including an installation subpath.
  /// It must not broaden the REST continuation/redirect allowlist.
  Uri get graphQL => Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.port == 443 ? null : base.port,
    pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      'api',
      'graphql',
    ],
  );

  bool allowsGraphQL(Uri uri) => uri == graphQL;

  /// `/oauth/{name}` on this instance, never a third-party host.
  Uri oauth(String name, [Map<String, String>? query]) => Uri(
    scheme: 'https',
    host: base.host,
    port: base.port == 443 ? null : base.port,
    pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      'oauth',
      name,
    ],
    queryParameters: query,
  );

  bool sameOrigin(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == base.host &&
      uri.port == base.port &&
      uri.userInfo.isEmpty;

  bool allowsApi(Uri uri) {
    if (!sameOrigin(uri) || uri.hasFragment) return false;
    final p = uri.pathSegments;
    if (p.length <= _prefix.length) return false;
    for (var i = 0; i < _prefix.length; i++) {
      if (p[i] != _prefix[i]) return false;
    }
    if (p.any((s) => s == '.' || s == '..')) return false;
    return !uri.queryParameters.keys.any(
      (k) => const [
        'access_token',
        'private_token',
        'token',
      ].contains(k.toLowerCase()),
    );
  }

  /// Safe browser fallback. Never attaches an API credential or source URL.
  Uri projectWeb(String path) => Uri(
    scheme: 'https',
    host: base.host,
    port: base.port == 443 ? null : base.port,
    pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ...path.split('/'),
    ],
  );

  @override
  bool operator ==(Object other) => other is GitLabInstance && key == other.key;
  @override
  int get hashCode => key.hashCode;
  @override
  String toString() => key;
}
