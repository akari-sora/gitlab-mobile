import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Wire selection only. The session retains all scope, permit and stop checks.
abstract interface class Mr7SessionTransport {
  String get gitLabToken;
  DateTime get serverTime;
  int get setupWrites;
  int get projectId;
  void bindSession({
    required int userId,
    required String namespace,
    required void Function(RequestOptions) beforeAdditionalRead,
  });
  Future<ResponseBody> send(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancellation, {
    required bool observation,
  });
  void close();
}
