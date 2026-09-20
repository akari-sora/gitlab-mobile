import 'instance.dart';

const paginationKeys = {'page', 'id_after', 'page_token', 'pagination', 'cursor'};
const _falseDefaults = {
  'membership', 'starred', 'simple', 'owned', 'imported', 'include_hidden',
  'statistics', 'with_custom_attributes', 'with_issues_enabled',
  'with_merge_requests_enabled', 'repository_checksum_failed', 'wiki_checksum_failed',
};

/// Retain immutable caller filters and copy only the server-provided cursor.
Uri checkedPageUri(GitLabInstance instance, Uri current, Uri candidate) {
  final next = candidate.hasScheme ? candidate : current.resolveUri(candidate);
  if (!instance.allowsApi(next) || next.path != current.path ||
      next.userInfo.isNotEmpty || next.hasFragment ||
      next.queryParametersAll.values.any((values) => values.length != 1)) {
    throw const FormatException('Unsafe pagination target');
  }
  for (final entry in current.queryParameters.entries) {
    if (paginationKeys.contains(entry.key)) { continue; }
    final supplied = next.queryParameters[entry.key];
    if (supplied == entry.value) { continue; }
    if (supplied == null && (entry.value.isEmpty ||
        (_falseDefaults.contains(entry.key) && entry.value == 'false'))) {
      continue;
    }
    throw const FormatException('Pagination changed resource scope');
  }
  for (final key in _falseDefaults) {
    if (!current.queryParameters.containsKey(key) && next.queryParameters.containsKey(key) &&
        next.queryParameters[key] != 'false') {
      throw const FormatException('Pagination added a scope filter');
    }
  }
  for (final key in const ['search', 'ref', 'path', 'scope', 'state', 'labels']) {
    if (!current.queryParameters.containsKey(key) && (next.queryParameters[key]?.isNotEmpty ?? false)) {
      throw const FormatException('Pagination added a resource filter');
    }
  }
  final query = <String, String>{
    for (final entry in current.queryParameters.entries)
      if (!paginationKeys.contains(entry.key)) entry.key: entry.value,
    for (final entry in next.queryParameters.entries)
      if (paginationKeys.contains(entry.key)) entry.key: entry.value,
  };
  final normalized = current.replace(queryParameters: query);
  if (normalized == current) { throw const FormatException('Non-progressing pagination'); }
  final page = int.tryParse(query['page'] ?? '');
  final now = int.tryParse(current.queryParameters['page'] ?? '1');
  if (query.containsKey('page') && (page == null || page < 1 || (now != null && page <= now))) {
    throw const FormatException('Non-progressing pagination');
  }
  if (!const ['page', 'id_after', 'page_token', 'cursor'].any(query.containsKey)) {
    throw const FormatException('Pagination cursor missing');
  }
  return normalized;
}

Uri? nextPageUri({required GitLabInstance instance, required Uri current,
    required Map<String, List<String>> headers}) {
  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name && entry.value.isNotEmpty) { return entry.value.join(','); }
    }
    return null;
  }
  final link = header('link');
  if (link != null) {
    for (final match in RegExp(r'<([^>]+)>\s*;\s*rel="?([^";,]+)"?').allMatches(link)) {
      if (match.group(2)?.trim().split(' ').contains('next') ?? false) {
        return checkedPageUri(instance, current, Uri.parse(match.group(1)!));
      }
    }
  }
  final page = int.tryParse(header('x-next-page') ?? '');
  if (page == null || page <= 0) { return null; }
  return checkedPageUri(instance, current,
    current.replace(queryParameters: {...current.queryParameters, 'page': '$page'}));
}
