import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Version name, build number, and the commit recorded for this binary.
class BuildInfo {
  const BuildInfo({
    required this.version,
    required this.buildNumber,
    required this.commit,
  });

  final String version;
  final String buildNumber;
  final String commit;

  /// `--dart-define=GITLAB_MOBILE_COMMIT`. Defaults to `dev` for local runs.
  static const String environmentCommit = String.fromEnvironment(
    'GITLAB_MOBILE_COMMIT',
    defaultValue: 'dev',
  );

  static const String unknownVersion = '未知';

  bool get isUnknown => version == unknownVersion;
}

/// Loads [BuildInfo] without touching the platform channel in widget tests.
typedef BuildInfoLoader = Future<BuildInfo> Function();

Future<BuildInfo> loadBuildInfo() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return BuildInfo(
      version: info.version,
      buildNumber: info.buildNumber,
      commit: BuildInfo.environmentCommit,
    );
  } catch (_) {
    return const BuildInfo(
      version: BuildInfo.unknownVersion,
      buildNumber: '',
      commit: BuildInfo.environmentCommit,
    );
  }
}

String _versionLine(BuildInfo info) {
  if (info.isUnknown) return '版本未知';
  return '版本 ${info.version} (${info.buildNumber}) · commit ${info.commit}';
}

String _copyText(BuildInfo info, TargetPlatform platform) {
  return 'GitLab Mobile ${info.version} (${info.buildNumber}) · ${info.commit} · ${_platformLabel(platform)}';
}

String _platformLabel(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.fuchsia => 'Fuchsia',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
  };
}

/// Version row on the 我的 tab. Loading shows 「版本 …」; a failed load shows
/// 「版本未知」.
class BuildInfoLine extends StatefulWidget {
  const BuildInfoLine({super.key, this.load = loadBuildInfo});

  final BuildInfoLoader load;

  @override
  State<BuildInfoLine> createState() => _BuildInfoLineState();
}

class _BuildInfoLineState extends State<BuildInfoLine> {
  late final Future<BuildInfo> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  Future<void> _copy(BuildInfo info) async {
    final messenger = ScaffoldMessenger.of(context);
    final platform = Theme.of(context).platform;
    await Clipboard.setData(ClipboardData(text: _copyText(info, platform)));
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('已複製')));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BuildInfo>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Text('版本 …', style: TextStyle(fontSize: 12));
        }
        final info = snapshot.data;
        if (snapshot.hasError || info == null || info.isUnknown) {
          return const Text('版本未知', style: TextStyle(fontSize: 12));
        }
        return Row(
          children: [
            Expanded(
              child: MergeSemantics(
                child: Text(_versionLine(info), style: const TextStyle(fontSize: 12)),
              ),
            ),
            MergeSemantics(
              child: Semantics(
                label: '複製版本資訊',
                button: true,
                child: IconButton(
                  tooltip: '複製版本資訊',
                  onPressed: () {
                    unawaited(_copy(info));
                  },
                  icon: const Icon(Icons.copy_outlined, size: 20),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
