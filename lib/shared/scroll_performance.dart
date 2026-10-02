import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Opt-in profile diagnostics. Emits only frame measurements, never route,
/// account, request, or content data. Disabled builds create no listener.
class ScrollPerformance extends StatefulWidget {
  const ScrollPerformance({super.key, required this.child});
  final Widget child;

  @override
  State<ScrollPerformance> createState() => _ScrollPerformanceState();
}

class _ScrollPerformanceState extends State<ScrollPerformance> {
  static const _activeTimeout = Duration(seconds: 20);
  static const _initialSettleDelay = Duration(milliseconds: 500);
  static const _settleQuietPeriod = Duration(milliseconds: 250);
  static const _maximumSettleDelay = Duration(milliseconds: 1200);

  final _samples = <_ScrollSample>[];
  _ScrollSample? _active;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings);
  }

  void _timings(List<FrameTiming> frames) {
    for (final sample in _samples) {
      var addedFrame = false;
      for (final frame in frames) {
        final start = frame.timestampInMicroseconds(FramePhase.vsyncStart);
        if (start >= sample.start &&
            (sample.end == null || start <= sample.end!)) {
          if (sample.frames.length < 4096) {
            sample.frames.add(frame);
            addedFrame = true;
          } else {
            sample.truncated = true;
          }
        }
      }
      if (addedFrame && sample.end != null) {
        sample.settleTimer?.cancel();
        sample.settleTimer = Timer(_settleQuietPeriod, () => _emit(sample));
      }
    }
  }

  bool _scroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final origin = notification.context;
    if (origin is Element &&
        origin.mounted &&
        !TickerMode.valuesOf(origin).enabled) {
      return false;
    }
    final now =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null &&
        _active == null &&
        origin != null) {
      final sample = _ScrollSample(
        ++_sequence,
        now,
        origin,
        notification.depth,
      );
      _active = sample;
      _samples.add(sample);
      sample.activeTimer = Timer(_activeTimeout, () {
        sample.truncated = true;
        _finish(sample);
      });
    } else if (notification is ScrollEndNotification) {
      final sample = _active;
      if (sample != null &&
          identical(notification.context, sample.origin) &&
          notification.depth == sample.depth) {
        _finish(sample);
      }
    }
    return false;
  }

  void _finish(_ScrollSample sample) {
    if (sample.end != null) return;
    sample.activeTimer?.cancel();
    sample.end =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    if (identical(_active, sample)) _active = null;
    // Flutter documents profile/debug timing delivery as approximately every
    // 100ms, not as a deadline. Use a conservative initial grace, then wait
    // for a short quiet period after a matching late batch, with a hard cap.
    // This reduces likely batch loss but cannot make the sample loss-proof.
    sample.settleTimer = Timer(_initialSettleDelay, () => _emit(sample));
    sample.settleDeadlineTimer = Timer(
      _maximumSettleDelay,
      () => _emit(sample),
    );
  }

  void _emit(_ScrollSample sample) {
    if (sample.emitted) return;
    sample.emitted = true;
    sample.settleTimer?.cancel();
    sample.settleDeadlineTimer?.cancel();
    _samples.remove(sample);
    debugPrint('[scroll_perf] ${jsonEncode(sample.summary())}');
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    for (final sample in _samples) {
      sample.activeTimer?.cancel();
      sample.settleTimer?.cancel();
      sample.settleDeadlineTimer?.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _scroll,
        child: widget.child,
      );
}

class _ScrollSample {
  _ScrollSample(this.sequence, this.start, this.origin, this.depth);
  final int sequence, start;
  final BuildContext origin;
  final int depth;
  int? end;
  Timer? activeTimer, settleTimer, settleDeadlineTimer;
  bool truncated = false;
  bool emitted = false;
  final frames = <FrameTiming>[];

  Map<String, Object> summary() {
    final totals = frames.map((f) => f.totalSpan.inMicroseconds).toList()
      ..sort();
    int maxOf(int Function(FrameTiming) duration) =>
        frames.fold(0, (n, f) => n > duration(f) ? n : duration(f));
    int missed(int budget) => frames
        .where(
          (f) =>
              f.buildDuration.inMicroseconds > budget ||
              f.rasterDuration.inMicroseconds > budget,
        )
        .length;
    return {
      'label': const String.fromEnvironment(
        'PERF_LABEL',
        defaultValue: 'profile',
      ),
      'sequence': sequence,
      'frames': frames.length,
      'truncated': truncated,
      'missed60': missed(16667),
      'missed120': missed(8333),
      'latency60': totals.where((n) => n > 16667).length,
      'max_total_us': totals.isEmpty ? 0 : totals.last,
      'p95_total_us': totals.isEmpty
          ? 0
          : totals[((totals.length - 1) * .95).round()],
      'avg_total_us': totals.isEmpty
          ? 0
          : totals.reduce((a, b) => a + b) ~/ totals.length,
      'max_build_us': maxOf((f) => f.buildDuration.inMicroseconds),
      'max_raster_us': maxOf((f) => f.rasterDuration.inMicroseconds),
    };
  }
}
