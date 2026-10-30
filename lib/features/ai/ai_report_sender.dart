import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/ai_report.dart';

enum AiReportRoute { form, mail, share }

/// Why the developer's form did not take a report: [status] is the HTTP
/// status it answered with, or null when no answer came.
final class AiReportPostFailure implements Exception {
  /// The form answered [status], or the report never left the device
  /// (offline, no connection, a failed TLS handshake).
  const AiReportPostFailure([this.status]) : mayHaveArrived = false;

  /// The exchange broke off after the report may have been sent (a timeout
  /// or a reset while waiting for the answer): the form may have it.
  const AiReportPostFailure.uncertain() : status = null, mayHaveArrived = true;

  final int? status;

  /// Whether the form may have the report although no answer said so.
  final bool mayHaveArrived;
}

/// Sends a report from inside the app, to the developer's form. When the
/// form does not take it, [offerFallback] shows why and asks; only a yes
/// hands the report to [fallback] (mail, then the share sheet). Null when
/// nothing was handed over: the user declined, or [fallback] gave up.
Future<AiReportRoute?> sendAiReportInApp({
  required AiReportFormFields fields,
  required Future<bool> Function(AiReportPostFailure failure) offerFallback,
  required Future<AiReportRoute?> Function() fallback,
  Future<void> Function(AiReportFormFields fields) post = postAiReport,
}) async {
  AiReportPostFailure failure;
  try {
    await post(fields);
    return AiReportRoute.form;
  } on AiReportPostFailure catch (error) {
    failure = error;
  } on Object {
    // Whatever went wrong, the user hears that the report did not go.
    failure = const AiReportPostFailure();
  }
  if (!await offerFallback(failure)) return null;
  return fallback();
}

/// Posts [fields] to the developer's Google Form through a client of its
/// own: no cookies, and nothing of the GitLab or AI provider clients (their
/// credentials or headers). Redirects are not followed: Google sends a form
/// that needs sign-in to the sign-in page, so only a 2xx answer counts as
/// taken, and its body (a confirmation page) is not read. Throws
/// [AiReportPostFailure] otherwise, and when the whole exchange takes longer
/// than [timeout]. [adapter] replaces the network in tests.
Future<void> postAiReport(
  AiReportFormFields fields, {
  HttpClientAdapter? adapter,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final endpoint = aiReportFormEndpoint;
  if (endpoint.scheme != 'https') throw const AiReportPostFailure();
  final dio = Dio(
    BaseOptions(
      connectTimeout: timeout,
      sendTimeout: timeout,
      receiveTimeout: timeout,
    ),
  );
  if (adapter != null) dio.httpClientAdapter = adapter;
  // Each phase has the timeout, and so does the whole exchange.
  final cancel = CancelToken();
  final deadline = Timer(timeout, cancel.cancel);
  try {
    final response = await dio.requestUri<ResponseBody>(
      endpoint,
      data: fields.form,
      cancelToken: cancel,
      options: Options(
        method: 'POST',
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        persistentConnection: false,
        validateStatus: (status) => status != null,
        headers: const {'User-Agent': 'Mergeline/1.0 AI report'},
      ),
    );
    final status = response.statusCode ?? 0;
    await _release(response.data);
    if (status < 200 || status >= 300) throw AiReportPostFailure(status);
  } on AiReportPostFailure {
    rethrow;
  } on DioException catch (error) {
    // Only a failure to connect proves the report never left the device. A
    // connection closed while waiting for the answer is a connectionError
    // too, but without a socket error behind it, and the body may be out.
    switch (error.type) {
      case DioExceptionType.connectionError when error.error is SocketException:
      case DioExceptionType.connectionTimeout:
        throw const AiReportPostFailure();
      default:
        throw const AiReportPostFailure.uncertain();
    }
  } on Object {
    throw const AiReportPostFailure.uncertain();
  } finally {
    deadline.cancel();
    dio.close(force: true);
  }
}

Future<void> _release(ResponseBody? body) async {
  try {
    await body?.stream.listen((_) {}).cancel();
  } on Object {
    return;
  }
}

/// The fallback route: hands [body] to the mail app, or to the share sheet
/// when no mail app takes it.
Future<AiReportRoute> sendAiReport({
  required String subject,
  required String body,
  Rect? sharePositionOrigin,
  Future<bool> Function(Uri uri)? launch,
  Future<void> Function(String text, String subject, Rect? origin)? share,
}) async {
  final mailto = aiReportMailto(subject, body);
  if (mailto != null) {
    try {
      final launched = await (launch ?? _launchMail)(mailto);
      if (launched) return AiReportRoute.mail;
    } catch (_) {
      // The share sheet below is the fallback for an unavailable mail app.
    }
  }

  await (share ?? _shareText)(body, subject, sharePositionOrigin);
  return AiReportRoute.share;
}

Future<bool> _launchMail(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<void> _shareText(String text, String subject, Rect? origin) async {
  // Text only, so nothing is copied into share_plus's cache. The subject
  // fills in when the user picks a mail app from the sheet.
  await SharePlus.instance.share(
    ShareParams(text: text, subject: subject, sharePositionOrigin: origin),
  );
}
