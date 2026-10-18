import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Links other apps hand to this one. On Android the native `LinkActivity`
/// forwards a tapped gitlab.com link, or the first https URL in text shared to
/// the app, to the launcher activity, where app_links reports it (the link the
/// app was started with included, once).
abstract interface class IncomingLinkSource {
  Stream<Uri> get links;
}

final class AppLinksSource implements IncomingLinkSource {
  AppLinksSource([AppLinks? links]) : _links = links ?? AppLinks();
  final AppLinks _links;
  @override
  Stream<Uri> get links => _links.uriLinkStream;
}

const linkChannel = MethodChannel('io.gitlabmobile/links');

/// Opens Android's "open by default" settings for this app, where the user
/// lets it handle gitlab.com links (Android 12 and later do not hand an
/// unverified domain to an app until the user allows it there).
Future<bool> openLinkSettings() async =>
    await linkChannel.invokeMethod<bool>('openByDefaultSettings') ?? false;

/// The longest link accepted from another app, matching the native side.
const incomingLinkMaxLength = 2048;

/// Whether [uri] is a web link the app may try to open. The OAuth callback
/// uses a custom scheme and belongs to the sign-in flow, not here.
bool isIncomingWebLink(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    uri.toString().length <= incomingLinkMaxLength;

/// Keeps the newest web link from another app until the signed-in shell takes
/// it. A link that arrives while signed out waits for the next sign-in. The
/// shell resolves it for the active account; a link for another instance is
/// explained, never opened under this account.
class IncomingLinks extends ChangeNotifier {
  IncomingLinks(this._source, {Future<bool> Function()? openSettings})
    : _openSettings = openSettings;

  /// Null where the platform has no way in (iOS, tests): nothing ever arrives.
  final IncomingLinkSource? _source;
  final Future<bool> Function()? _openSettings;
  StreamSubscription<Uri>? _subscription;
  Uri? _pending;
  bool _disposed = false;

  Uri? get pending => _pending;

  void start() {
    final source = _source;
    if (source == null || _subscription != null || _disposed) return;
    _subscription = source.links.listen(offer, onError: (Object _) {});
  }

  void offer(Uri uri) {
    if (_disposed || !isIncomingWebLink(uri)) return;
    _pending = uri;
    notifyListeners();
  }

  /// Whether the system lets the user choose which links this app opens.
  bool get canOpenSettings => _openSettings != null;

  /// Opens that system setting; false when it could not be shown.
  Future<bool> openSettings() async {
    final open = _openSettings;
    if (open == null) return false;
    try {
      return await open();
    } catch (_) {
      return false;
    }
  }

  /// Hands the waiting link over once.
  Uri? take() {
    final link = _pending;
    _pending = null;
    return link;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
