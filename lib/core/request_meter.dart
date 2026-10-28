import 'dart:async';

/// Counts physical GitLab HTTP requests in the current asynchronous operation.
final class RequestMeter {
  RequestMeter({
    this.beforeRequest,
    this.onRequest,
    this.includeOAuthTokens = false,
  });

  /// Admission is checked before every physical send, including an OAuth
  /// replay, so an exhausted lease can be replaced before sending again.
  /// Transports await it only when present, then count synchronously at send.
  final Future<void> Function()? beforeRequest;

  /// Checks an optional execution fence and settles admission synchronously at
  /// the physical send, after cancellation and pacing checks. A rejected send
  /// must not consume a reservation or increment the count.
  final void Function()? onRequest;
  final bool includeOAuthTokens;
  int _count = 0;

  int get count => _count;

  void increment() {
    onRequest?.call();
    _count += 1;
  }

  static RequestMeter? get current =>
      Zone.current[#gitlabRequestMeter] as RequestMeter?;

  T run<T>(T Function() body) {
    return runZoned(
      body,
      zoneValues: <Object?, Object?>{#gitlabRequestMeter: this},
    );
  }

  Future<T> runAsync<T>(Future<T> Function() body) {
    return runZoned(
      body,
      zoneValues: <Object?, Object?>{#gitlabRequestMeter: this},
    );
  }
}
