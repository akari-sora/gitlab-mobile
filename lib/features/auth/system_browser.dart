import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/failure.dart';
import '../../core/oauth.dart';

/// RFC 8252 system browser: the OS browser plus this app's custom-scheme callback.
final class SystemAuthorizationBrowser implements AuthorizationBrowser {
  SystemAuthorizationBrowser({
    AppLinks? links,
    Future<bool> Function(Uri uri)? launch,
  }) : _links = links ?? AppLinks(),
       _launch =
           launch ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final AppLinks _links;
  final Future<bool> Function(Uri uri) _launch;

  @override
  Future<Uri> authenticate({
    required Uri authorizationUrl,
    required Uri callbackUrl,
  }) async {
    final pending = Completer<Uri>();
    bool matches(Uri uri) =>
        uri.scheme == callbackUrl.scheme && uri.host == callbackUrl.host;
    final subscription = _links.uriLinkStream.listen((uri) {
      if (matches(uri) && !pending.isCompleted) pending.complete(uri);
    });
    try {
      final initial = await _links.getInitialLink();
      if (initial != null && matches(initial) && !pending.isCompleted) {
        pending.complete(initial);
      } else {
        final opened = await _launch(authorizationUrl);
        if (!opened) throw const ApiFailure(FailureKind.network);
      }
      return await pending.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          throw const ApiFailure(FailureKind.network);
        },
      );
    } finally {
      await subscription.cancel();
    }
  }
}
