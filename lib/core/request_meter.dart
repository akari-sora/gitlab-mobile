import 'dart:async';

/// Counts physical GitLab HTTP requests in the current asynchronous operation.
final class RequestMeter {
  int _count = 0;

  int get count => _count;

  void increment() {
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
