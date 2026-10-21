final _sensitiveBasenames = <RegExp>[
  RegExp(r'^\.env(?:\..*)?$', caseSensitive: false),
  RegExp(r'.*\.(?:pem|key|p12|pfx|jks|keystore|kdbx)$', caseSensitive: false),
  RegExp(r'^id_(?:rsa|dsa|ecdsa|ed25519).*$', caseSensitive: false),
  RegExp(
    r'^\.(?:npmrc|pypirc|netrc|git-credentials|dockercfg)$',
    caseSensitive: false,
  ),
  RegExp(r'^kubeconfig$', caseSensitive: false),
  RegExp(r'.*\.kubeconfig$', caseSensitive: false),
  RegExp(r'^credentials(?:\.json)?$', caseSensitive: false),
  RegExp(r'^secrets\..*$', caseSensitive: false),
  RegExp(r'.*secret.*\.ya?ml$', caseSensitive: false),
  RegExp(r'^terraform\.tfstate.*$', caseSensitive: false),
  RegExp(r'.*\.tfvars$', caseSensitive: false),
  RegExp(r'^(?:key|signing)\.properties$', caseSensitive: false),
  RegExp(r'.*\.mobileprovision$', caseSensitive: false),
];

bool isSensitiveRepositoryPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final basename = normalized.split('/').last;
  if (normalized.toLowerCase() == '.docker/config.json' ||
      normalized.toLowerCase().endsWith('/.docker/config.json')) {
    return true;
  }
  return _sensitiveBasenames.any((pattern) => pattern.hasMatch(basename));
}

bool isValidRepositoryPath(String path) {
  if (path.length > 1024 ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains('\u0000')) {
    return false;
  }
  return !path.split('/').contains('..');
}

bool isFullCommitSha(String value) =>
    RegExp(r'^[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?$').hasMatch(value);
