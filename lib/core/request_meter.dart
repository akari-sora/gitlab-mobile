import 'dart:async';

/// Counts physical GitLab HTTP requests in the current asynchronous operation.
final class RequestMeter {
  RequestMeter({this.beforeRequest});

  /// Optional admission for this operation only, before a physical API send.
  /// Rejected sends consume no request allowance. OAuth rotation is shared
  /// account work and is not metered by the API request counter.
  final void Function()? beforeRequest;
  int _count = 0;

  int get count => _count;

  void increment() {
    beforeRequest?.call();
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
