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

/// How many lines of [text] GitLab would read as quick actions: after the same
/// CR handling as [neutralizeForGitLabDraft], the lines that start with `/`.
int quickActionLineCount(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '')
    .split('\n')
    .where((line) => line.startsWith('/'))
    .length;
