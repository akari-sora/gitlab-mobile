import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../l10n/l10n.dart';
import '../../shared/artifact_storage.dart' show formatByteCount;
import '../../shared/hub_ui.dart';
import '../../shared/workspace_ui.dart';
import 'read_cache_disk_coordinator.dart';
import 'read_cache_settings_store.dart';

/// What the device's offline cache is doing, read from the coordinator
/// snapshot. A pending cleanup notice outranks every other state.
enum OfflineCacheStatus {
  on,
  off,
  waiting,
  cleaning,
  keyUnavailable,
  settingUnavailable,
  cleanupPending,
}

OfflineCacheStatus offlineCacheStatus(
  ReadCacheDiskCoordinator cache,
  DiskBinding binding,
) {
  final device = cache.settingsSnapshot;
  if (device.deviceOffInFlight) return OfflineCacheStatus.cleaning;
  if (device.deviceOffPending || cache.notice(binding) != null) {
    return OfflineCacheStatus.cleanupPending;
  }
  switch (cache.setting) {
    case ReadCacheSettingsState.disabled:
      return OfflineCacheStatus.off;
    case ReadCacheSettingsState.unavailable:
      return OfflineCacheStatus.settingUnavailable;
    case ReadCacheSettingsState.enabled:
      break;
  }
  return switch (cache.state(binding.accountKey)) {
    ReadCacheDiskState.ready => OfflineCacheStatus.on,
    ReadCacheDiskState.cleaning => OfflineCacheStatus.cleaning,
    ReadCacheDiskState.unavailable => OfflineCacheStatus.keyUnavailable,
    ReadCacheDiskState.disabled => OfflineCacheStatus.off,
    ReadCacheDiskState.closed => OfflineCacheStatus.waiting,
  };
}

/// Status is always an icon plus a label.
(IconData, String) offlineCacheStatusLabel(OfflineCacheStatus status) =>
    switch (status) {
      OfflineCacheStatus.on => (Icons.check_circle_outline, l10n.offlineCacheStatusOn),
      OfflineCacheStatus.off => (Icons.cloud_off_outlined, l10n.offlineCacheStatusOff),
      OfflineCacheStatus.waiting => (Icons.schedule, l10n.offlineCacheStatusWaiting),
      OfflineCacheStatus.cleaning => (Icons.cleaning_services_outlined, l10n.offlineCacheStatusCleaning),
      OfflineCacheStatus.keyUnavailable => (Icons.lock_outline, l10n.offlineCacheStatusUnavailable),
      OfflineCacheStatus.settingUnavailable =>
        (Icons.error_outline, l10n.offlineCacheStatusSettingUnreadable),
      OfflineCacheStatus.cleanupPending =>
        (Icons.warning_amber_rounded, l10n.offlineCacheStatusCleanupPending),
    };

/// Runs [action] after the next frame, and asks for that frame: a notice can
/// arrive while the app is idle, when no frame would otherwise come.
void _afterFrame(VoidCallback action) {
  WidgetsBinding.instance
    ..addPostFrameCallback((_) => action())
    ..ensureVisualUpdate();
}

/// The size line. A confirmed device total is shown as is. Without one, the
/// indexed entry bytes are shown as an estimate, but only while no cleanup is
/// pending or failed; otherwise the size is unknown. Never a bare zero unless
/// the coordinator confirmed an empty device.
String offlineCacheSizeLabel(ReadCacheDiskCoordinator cache, DiskBinding binding) {
  final stats = cache.stats;
  final usage = stats.diskUsageBytes;
  if (usage != null) return l10n.offlineCacheSize(formatByteCount(usage));
  if (cache.deviceOffPending || cache.notice(binding) != null) {
    return l10n.offlineCacheSizeUnknown;
  }
  return l10n.offlineCacheSizeApprox(formatByteCount(stats.retainedBytes));
}

/// The failure shown when a device-wide clear is still unfinished.
ApiFailure _deviceCleanupPending(DiskClearResult result) =>
    ApiFailure.readCacheCleanup(ReadCacheCleanupState(
      operation: ReadCacheCleanupOperation.settingsClear,
      disposition: ReadCacheCleanupDisposition.diskClosed,
      code: ReadCacheCleanupCode.cleanupFailed,
      clearResult: result,
    ));

/// Retries a pending cleanup from the settings surfaces. While a device-wide
/// turn-off is unfinished it repeats that whole device sweep (every account,
/// unknown leftovers, final confirmation); one account's clear can never
/// complete it. Otherwise it is a settings clear of the signed-in account
/// (m-10): the coordinator reopens the same session only after the clear
/// completes, and a failure keeps the cache closed.
Future<void> retryOfflineCacheCleanup(
  BuildContext context,
  ReadCacheDiskCoordinator cache,
  DiskBinding binding, {
  VoidCallback? onDone,
}) async {
  ApiFailure? failure;
  final DiskClearResult result;
  if (cache.deviceOffPending) {
    result = await cache.retryDeviceOff();
    // A confirmed empty device resolves this account's pending notice too.
    if (result.complete) cache.supersedeNotice(binding);
  } else {
    result = await cache.clear(
      binding,
      ReadCacheCleanupOperation.settingsClear,
      onFailure: (value) => failure = value,
    );
  }
  onDone?.call();
  if (!context.mounted) return;
  if (result.complete) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.offlineCacheCleared)),
    );
    return;
  }
  showFailure(
    context,
    failure ?? _deviceCleanupPending(result),
    onRetryCleanup: () => unawaited(
      retryOfflineCacheCleanup(context, cache, binding, onDone: onDone),
    ),
  );
}

/// The 我的 › 儲存與快取 row. It keeps its own status current from the
/// coordinator's notices and after the settings page closes.
class ReadCacheSettingsEntry extends StatefulWidget {
  const ReadCacheSettingsEntry({
    super.key,
    required this.cache,
    required this.binding,
  });
  final ReadCacheDiskCoordinator cache;
  final DiskBinding binding;
  @override
  State<ReadCacheSettingsEntry> createState() => _ReadCacheSettingsEntryState();
}

class _ReadCacheSettingsEntryState extends State<ReadCacheSettingsEntry> {
  void Function()? _cancel;

  @override
  void initState() {
    super.initState();
    _cancel = widget.cache.subscribe(_changed);
  }

  @override
  void didUpdateWidget(covariant ReadCacheSettingsEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cache, widget.cache)) {
      _cancel?.call();
      _cancel = widget.cache.subscribe(_changed);
    }
  }

  @override
  void dispose() {
    _cancel?.call();
    super.dispose();
  }

  // Called synchronously inside the coordinator; rebuild on the next frame.
  void _changed(ReadCacheNotice _) => _afterFrame(() {
    if (mounted) setState(() {});
  });

  @override
  Widget build(BuildContext context) {
    final (_, label) = offlineCacheStatusLabel(
      offlineCacheStatus(widget.cache, widget.binding),
    );
    return HubRow(
      key: const ValueKey('read-cache-row'),
      leading: const IconTile(Icons.offline_pin_outlined, color: HubColors.teal),
      title: l10n.offlineCacheLabel,
      subtitle: label,
      chevron: true,
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ReadCacheSettingsPage(
            cache: widget.cache,
            binding: widget.binding,
          ),
        ));
        if (mounted) setState(() {});
      },
    );
  }
}

/// Device switch, aggregated size and clear for the encrypted offline cache.
/// Every value comes from the coordinator snapshot; this page never writes
/// the preference or touches files itself.
class ReadCacheSettingsPage extends StatefulWidget {
  const ReadCacheSettingsPage({
    super.key,
    required this.cache,
    required this.binding,
  });
  final ReadCacheDiskCoordinator cache;

  /// The signed-in account's verified binding (account key and generation).
  final DiskBinding binding;
  @override
  State<ReadCacheSettingsPage> createState() => _ReadCacheSettingsPageState();
}

const _noClear = DiskClearResult(
  keyGoneConfirmed: false,
  directoryGoneConfirmed: false,
  markerDurable: false,
  complete: false,
);

class _ReadCacheSettingsPageState extends State<ReadCacheSettingsPage> {
  void Function()? _cancel;
  bool _busy = false;

  ReadCacheDiskCoordinator get _cache => widget.cache;

  @override
  void initState() {
    super.initState();
    _cancel = _cache.subscribe((_) => _afterFrame(() {
      if (mounted) setState(() {});
    }));
  }

  @override
  void dispose() {
    _cancel?.call();
    super.dispose();
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    var result = ReadCacheSettingChangeResult.storageUnavailable;
    try {
      result = await _cache.setEnabledResult(enabled);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    void say(String Function() text, {bool retry = false}) =>
        messenger.showSnackBar(SnackBar(
          content: LiveText(text),
          action: retry
              ? RetryCleanupSnackAction(onPressed: () => unawaited(_retryCleanup()))
              : null,
        ));
    switch ((enabled, result)) {
      // A new setting never opens the cache now: it waits for a verified
      // activation after a fresh start-up decision.
      case (true, ReadCacheSettingChangeResult.complete):
        say(() => l10n.offlineCacheStatusWaiting);
      // Refused before anything was written: the last turn-off is unfinished.
      case (true, ReadCacheSettingChangeResult.cleanupPending):
        showFailure(context, _deviceCleanupPending(_noClear),
          onRetryCleanup: () => unawaited(_retryCleanup()));
      case (true, ReadCacheSettingChangeResult.storageUnavailable):
        say(() => l10n.offlineCacheTurnOnFailed);
      case (false, ReadCacheSettingChangeResult.complete):
        say(() => l10n.offlineCacheTurnedOff);
      // The device sweep is unfinished, whatever happened to the preference.
      case (false, ReadCacheSettingChangeResult.cleanupPending):
        say(() => l10n.offlineCacheTurnOffUnconfirmed, retry: true);
      // Cleared for certain, but "off" was not saved.
      case (false, ReadCacheSettingChangeResult.storageUnavailable):
        say(() => l10n.offlineCacheOffNotSaved);
    }
  }

  Future<void> _retryCleanup() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    await retryOfflineCacheCleanup(
      context,
      _cache,
      widget.binding,
      onDone: () {
        if (mounted) setState(() => _busy = false);
      },
    );
  }

  Future<void> _clear() async {
    if (_busy) return;
    final confirmed = await confirmAction(
      context,
      l10n.offlineCacheClearConfirmTitle,
      l10n.offlineCacheClearConfirmDetail,
    );
    if (!confirmed || !mounted) return;
    await _retryCleanup();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final device = _cache.settingsSnapshot;
    final on = device.setting == ReadCacheSettingsState.enabled;
    // Turning on waits until the last turn-off's device sweep is confirmed.
    final onBlocked = !on && (device.deviceOffPending || device.deviceOffInFlight);
    final status = offlineCacheStatus(_cache, widget.binding);
    final (icon, label) = offlineCacheStatusLabel(status);
    final notice = _cache.notice(widget.binding);
    final warning = switch (status) {
      OfflineCacheStatus.cleanupPending ||
      OfflineCacheStatus.keyUnavailable ||
      OfflineCacheStatus.settingUnavailable => true,
      _ => false,
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.storageAndCacheLabel)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          HubSection(
            children: [
              SwitchListTile(
                key: const ValueKey('read-cache-switch'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                secondary: const Icon(Icons.offline_pin_outlined),
                title: Text(l10n.offlineCacheLabel),
                subtitle: Text(l10n.offlineCacheDescription),
                value: on,
                onChanged: _busy || !_cache.configured || device.deviceOffInFlight || onBlocked
                    ? null
                    : (value) => unawaited(_setEnabled(value)),
              ),
              if (onBlocked)
                ListTile(
                  key: const ValueKey('read-cache-on-blocked'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: Icon(Icons.info_outline, color: theme.colorScheme.error),
                  title: Text(l10n.offlineCacheOnNeedsCleanup),
                  trailing: TextButton(
                    key: const ValueKey('read-cache-retry-device-off'),
                    onPressed: _busy || device.deviceOffInFlight
                        ? null
                        : () => unawaited(_retryCleanup()),
                    child: Text(l10n.offlineCacheRetryCleanup),
                  ),
                ),
              ListTile(
                key: const ValueKey('read-cache-status'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(
                  icon,
                  color: warning ? theme.colorScheme.error : theme.colorScheme.primary,
                ),
                title: Text(label),
              ),
              ListTile(
                key: const ValueKey('read-cache-size'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: const Icon(Icons.data_usage),
                title: Text(offlineCacheSizeLabel(_cache, widget.binding)),
              ),
            ],
          ),
          if (notice != null)
            FailureNotice(
              notice.failure,
              onRetryCleanup: _busy ? null : () => unawaited(_retryCleanup()),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const ValueKey('read-cache-clear'),
                onPressed: _busy || !_cache.configured
                    ? null
                    : () => unawaited(_clear()),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(l10n.offlineCacheClearAction),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
