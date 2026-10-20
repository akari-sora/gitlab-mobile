import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/failure.dart';
import '../core/models.dart';

/// Resolved root directory for downloaded job artifacts and attachments. Tests point it to a
/// process temp directory instead of waiting on that call.
Future<Directory> Function() artifactStorageRoot = _defaultArtifactRoot;

Future<Directory> _defaultArtifactRoot() {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return Future<Directory>.value(Directory.systemTemp);
  }
  return getTemporaryDirectory();
}

/// Path segment for [account]. A fixed-length digest so a long installation
/// path cannot exceed the 255-byte directory-component limit.
String artifactAccountSegment(Account account) =>
    sha256.convert(utf8.encode(account.key)).toString().substring(0, 32);

int _artifactAttempt = 0;

/// `<temporary>/artifacts/<account>/<project>-<job>/<attempt>/`.
///
/// Each call is one attempt. Cleanup of that directory cannot truncate another
/// attempt, account, or instance that happens to reuse the same numeric ids.
/// The operating system may purge this cache directory at any time.
Future<Directory> jobArtifactDirectory(Account account, int projectId, int jobId) async {
  final root = await artifactStorageRoot();
  final attempt = ++_artifactAttempt;
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final directory = Directory(
    '${root.path}/artifacts/${artifactAccountSegment(account)}/$projectId-$jobId/$stamp-$attempt',
  );
  await directory.create(recursive: true);
  return directory;
}

int _attachmentAttempt = 0;

/// `<temporary>/attachments/<account>/<project>/<attempt>/`.
///
/// Attempt-scoped isolated staging directory for project uploads downloads.
Future<Directory> attachmentAttemptDirectory(Account account, int projectId) async {
  final root = await artifactStorageRoot();
  final attempt = ++_attachmentAttempt;
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final directory = Directory(
    '${root.path}/attachments/${artifactAccountSegment(account)}/$projectId/$stamp-$attempt',
  );
  await directory.create(recursive: true);
  return directory;
}

Future<void>? _mediaStartup;
int _mediaAttempt = 0;
final _mediaAccountGenerations = <String, int>{};
final _mediaRemovingAccounts = <String>{};
final _mediaCleanups = <String, Set<Future<void> Function()>>{};

int markdownMediaAccountGeneration(Account account) => _mediaAccountGenerations[account.key] ?? 0;

/// Account removal first cancels/disposes live players, then removes their files.
void Function() registerMarkdownMediaCleanup(Account account, Future<void> Function() cleanup) {
  final callbacks = _mediaCleanups.putIfAbsent(account.key, () => {});
  callbacks.add(cleanup);
  return () {
    callbacks.remove(cleanup);
    if (callbacks.isEmpty) _mediaCleanups.remove(account.key);
  };
}

/// Runs once at launch, before any view can create a new playback file.
/// A failed cleanup is retried before a download, so old media is never reused.
Future<void> clearStaleMarkdownMedia() => _mediaStartup ??= () async {
  final root = await artifactStorageRoot();
  final directory = Directory('${root.path}/media');
  if (directory.existsSync()) removeArtifactDirectory(directory);
}().catchError((Object error, StackTrace stack) {
  _mediaStartup = null;
  Error.throwWithStackTrace(error, stack);
});

/// Each card owns a separate attempt; disposing it cannot delete another card.
Future<Directory> markdownMediaDirectory(Account account, {int? generation}) async {
  final expected = generation ?? markdownMediaAccountGeneration(account);
  await clearStaleMarkdownMedia();
  final root = await artifactStorageRoot();
  if (_mediaRemovingAccounts.contains(account.key) ||
      expected != markdownMediaAccountGeneration(account)) {
    throw const ApiFailure(FailureKind.cancelled);
  }
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final directory = Directory(
    '${root.path}/media/${artifactAccountSegment(account)}/$stamp-${++_mediaAttempt}',
  );
  directory.createSync(recursive: true);
  return directory;
}

@visibleForTesting
void resetMarkdownMediaStartup() {
  _mediaStartup = null;
  _mediaAccountGenerations.clear();
  _mediaRemovingAccounts.clear();
  _mediaCleanups.clear();
}

/// Sanitizes an attachment filename, preventing path traversal and reserved names.
String attachmentDownloadFileName(String name, {String fallback = 'attachment.bin'}) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  if (base.isEmpty ||
      base == '.' ||
      base == '..' ||
      base == '.partial' ||
      base == _artifactPartialName ||
      base.contains('\u0000')) {
    return fallback;
  }
  return base;
}

/// Deletes archives and attachments left behind for [account], including completed downloads.
/// Filesystem checks stay synchronous so account removal is not left waiting
/// on a plugin or an I/O future the widget test clock will not complete.
/// Lookup and deletion failures of that account directory propagate so the
/// account is not removed while its archives remain. The `share_plus` cache
/// is removed best-effort and cannot abort removal.
Future<void> clearAccountArtifacts(Account account) async {
  _mediaAccountGenerations[account.key] = markdownMediaAccountGeneration(account) + 1;
  _mediaRemovingAccounts.add(account.key);
  try {
    await _clearAccountArtifacts(account);
  } finally {
    _mediaRemovingAccounts.remove(account.key);
  }
}

Future<void> _clearAccountArtifacts(Account account) async {
  for (final cleanup in [...?_mediaCleanups[account.key]]) {
    await cleanup();
  }
  final Directory root;
  try {
    root = await artifactStorageRoot();
  } on Object {
    throw ApiFailure.artifactCleanup;
  }
  final directory = Directory('${root.path}/artifacts/${artifactAccountSegment(account)}');
  if (directory.existsSync()) {
    try {
      removeArtifactDirectory(directory);
    } on FileSystemException {
      throw ApiFailure.artifactCleanup;
    }
  }
  final attachmentsDir = Directory('${root.path}/attachments/${artifactAccountSegment(account)}');
  if (attachmentsDir.existsSync()) {
    try {
      removeArtifactDirectory(attachmentsDir);
    } on FileSystemException {
      throw ApiFailure.artifactCleanup;
    }
  }
  final mediaDir = Directory('${root.path}/media/${artifactAccountSegment(account)}');
  if (mediaDir.existsSync()) {
    try {
      removeArtifactDirectory(mediaDir);
    } on FileSystemException {
      throw ApiFailure.artifactCleanup;
    }
  }
  // share_plus is not account-scoped. A failure here must not keep the account.
  _deleteSharePlusDirectory(root);
}

/// share_plus copies the archive into `<cache>/share_plus/` and does not
/// delete it. Dismissed, unavailable, and failed shares delete that copy
/// immediately. A successful share leaves it until the app resumes after
/// leaving the foreground, so the receiving app can finish reading it.
/// Lookup can throw [MissingPlatformDirectoryException], which is not a
/// [FileSystemException], so every error here is ignored.
/// [serial] is the share that owns the folder when the caller decided to
/// delete it. The cache-root lookup awaits, and a newer share may start (and
/// plant its own copy) meanwhile, so ownership is re-checked after the await.
/// A null serial deletes unconditionally.
Future<void> _discardSharePlusCopies([int? serial]) async {
  try {
    final root = await artifactStorageRoot();
    if (serial != null && serial != _shareSerial) return;
    _deleteSharePlusDirectory(root);
  } on Object {
    return;
  }
}

void _deleteSharePlusDirectory(Directory root) {
  try {
    removeArtifactDirectory(Directory('${root.path}/share_plus'));
  } on Object {
    return;
  }
}

/// Deletes one account's artifact directory. Tests replace it to inject a
/// failure: a read-only directory does not stop deletion for root (the CI
/// runner), so permissions cannot simulate that path portably.
@visibleForTesting
void Function(Directory directory) removeArtifactDirectory =
    (directory) => directory.deleteSync(recursive: true);

Future<File> promoteArtifactFile(File partial, File target) async {
  if (target.existsSync()) await target.delete();
  return partial.rename(target.path);
}

const artifactPartialName = '.download.partial';
const _artifactPartialName = artifactPartialName;

IOSink openArtifactSink(File file) => file.openWrite();

/// Throttles archive progress to one notification per 100 ms, plus completion.
final class ArtifactProgress {
  ArtifactProgress({DateTime Function()? clock, (int, int?) initial = (0, null)})
      : _clock = clock ?? DateTime.now,
        value = ValueNotifier<(int, int?)>(initial);
  final DateTime Function() _clock;
  final ValueNotifier<(int, int?)> value;
  DateTime? _last;

  void report(int received, int? total, {bool completed = false}) {
    final now = _clock();
    final last = _last;
    if (!completed && last != null && now.difference(last) < const Duration(milliseconds: 100)) {
      return;
    }
    _last = now;
    final current = value.value;
    value.value = (received, total ?? current.$2);
  }

  void dispose() => value.dispose();
}

enum ShareOutcome { success, dismissed, unavailable }

int _shareSerial = 0;
// Created lazily in the caller's zone: a future made in another zone (a test
// tearDown) would schedule its continuations there and never run here.
Future<void>? _shareCleanup;
_ShareCopyWatch? _shareCopyWatch;

/// Hands [path] to [sharer] and then decides what happens to the plugin copy
/// in `<cache>/share_plus`. Only the newest share owns that folder: an older
/// share that completes later must not delete a copy planted by a newer one
/// (the plugin replaces the folder when a share starts). A dismissed,
/// unavailable or failed share deletes the copy at once. A successful share
/// keeps it until the app resumes after leaving the foreground, so the
/// receiving app can finish reading the `content://` stream; a later share
/// supersedes that hold.
Future<void> shareDownloadedArtifact(
  ArtifactSharer sharer,
  String path, {
  Rect? sharePositionOrigin,
}) async {
  final serial = ++_shareSerial;
  _disarmShareCopyWatch();
  ShareOutcome? outcome;
  try {
    outcome = await sharer.share(path, sharePositionOrigin: sharePositionOrigin);
  } catch (error, stack) {
    await _cleanupAfterShare(serial, null);
    Error.throwWithStackTrace(error, stack);
  }
  await _cleanupAfterShare(serial, outcome);
}

/// Cleanup steps run one at a time, in completion order.
Future<void> _cleanupAfterShare(int serial, ShareOutcome? outcome) {
  final previous = _shareCleanup ?? Future<void>.value();
  final step = previous.then((_) async {
    if (serial != _shareSerial) return;
    if (outcome == ShareOutcome.success) {
      _armShareCopyWatch(serial);
      return;
    }
    await _discardSharePlusCopies(serial);
  });
  _shareCleanup = step.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  return step;
}

/// At most one watcher is registered; it is not owned by any sheet, so a
/// sheet that closes before the app comes back does not cancel the cleanup.
void _armShareCopyWatch(int serial) {
  final existing = _shareCopyWatch;
  if (existing != null) {
    existing.serial = serial;
    return;
  }
  final watch = _ShareCopyWatch(serial);
  final state = WidgetsBinding.instance.lifecycleState;
  watch.departed = _leftForeground(state);
  _shareCopyWatch = watch;
  WidgetsBinding.instance.addObserver(watch);
}

void _disarmShareCopyWatch() {
  final watch = _shareCopyWatch;
  if (watch == null) return;
  WidgetsBinding.instance.removeObserver(watch);
  _shareCopyWatch = null;
}

bool _leftForeground(AppLifecycleState? state) =>
    state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.hidden;

@visibleForTesting
void resetArtifactShareCleanup() {
  _disarmShareCopyWatch();
  _shareSerial = 0;
  _shareCleanup = null;
}

final class _ShareCopyWatch extends WidgetsBindingObserver {
  _ShareCopyWatch(this.serial);
  int serial;
  var departed = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_leftForeground(state)) {
      departed = true;
      return;
    }
    if (state != AppLifecycleState.resumed || !departed) return;
    _disarmShareCopyWatch();
    unawaited(_discardSharePlusCopies(serial));
  }
}

abstract interface class ArtifactSharer {
  Future<ShareOutcome> share(String path, {Rect? sharePositionOrigin});
}

final class SystemArtifactSharer implements ArtifactSharer {
  const SystemArtifactSharer();
  @override
  Future<ShareOutcome> share(String path, {Rect? sharePositionOrigin}) async {
    final result = await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], sharePositionOrigin: sharePositionOrigin),
    );
    return switch (result.status) {
      ShareResultStatus.success => ShareOutcome.success,
      ShareResultStatus.dismissed => ShareOutcome.dismissed,
      ShareResultStatus.unavailable => ShareOutcome.unavailable,
    };
  }
}

Future<void> deleteAttemptFiles(Directory? directory, File? partial) async {
  if (partial != null && partial.existsSync()) {
    try {
      await partial.delete();
    } on FileSystemException {
      // A cancelled attempt may already have removed the temp file.
    }
  }
  if (directory != null && directory.existsSync()) {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // The cache directory can disappear while cleanup is in progress.
    }
  }
}

String formatByteCount(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final shown = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$shown ${units[unit]}';
}
