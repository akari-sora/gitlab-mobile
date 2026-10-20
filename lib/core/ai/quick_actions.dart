String neutralizeForGitLabDraft(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '');
  final result = normalized
      .split('\n')
      .map((line) => line.startsWith('/') ? ' $line' : line)
      .join('\n');
  if (result.split('\n').any((line) => line.startsWith('/'))) {
    throw StateError('Quick-action neutralization failed');
  }
  return result;
}
