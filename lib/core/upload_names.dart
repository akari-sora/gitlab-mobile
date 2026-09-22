final _uploadSecret = RegExp(r'^[0-9a-f]{32}$');

/// Secret and filename for `GET /projects/:id/uploads/:secret/:filename`.
///
/// `..` is rejected only when the filename segment is exactly that, so
/// `notes..png` stays a normal name. A leftover `%` is an incomplete escape
/// Dart rewrites as `%25`. Slashes cannot hide another segment.
bool projectUploadNamesOk(String secret, String filename) =>
    _uploadSecret.hasMatch(secret) &&
    filename.isNotEmpty &&
    filename != '.' &&
    filename != '..' &&
    !filename.contains('%') &&
    !filename.contains('/') &&
    !filename.contains('\\');
