import 'instance.dart';

/// Reads the server's next link, but never trusts it with credentials until the
/// origin, installation prefix, endpoint, and immutable filters are checked.
Uri? nextPageUri({required GitLabInstance instance, required Uri current,
  required Map<String, List<String>> headers}) {
  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name && entry.value.isNotEmpty) return entry.value.join(',');
    }
    return null;
  }
  final link = header('link');
  Uri? next;
  if (link != null) {
    for (final match in RegExp(r'<([^>]+)>\s*;\s*rel="?([^";,]+)"?').allMatches(link)) {
      if (match.group(2)?.trim() == 'next') {
        next = Uri.tryParse(match.group(1)!);
        break;
      }
    }
  }
  // No total and no header => do not guess a page number from item count.
  if (next == null) {
    final page = int.tryParse(header('x-next-page') ?? '');
    if (page == null || page <= 0) return null;
    next = current.replace(queryParameters: {...current.queryParameters, 'page': '$page'});
  }
  if (!next.hasScheme) next = current.resolveUri(next);
  if (!instance.allowsApi(next) || next.path != current.path || next == current) {
    throw const FormatException('Unsafe pagination target');
  }
  final nowPage = int.tryParse(current.queryParameters['page'] ?? '1');
  final nextPage = int.tryParse(next.queryParameters['page'] ?? '');
  if (nowPage != null && nextPage != null && nextPage <= nowPage) {
    throw const FormatException('Non-progressing pagination');
  }
  for (final key in const ['membership', 'starred', 'search', 'order_by', 'sort', 'simple', 'ref', 'path']) {
    if (next.queryParameters[key] != current.queryParameters[key]) {
      throw const FormatException('Pagination changed resource scope');
    }
  }
  return next;
}
