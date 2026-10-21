import '../../core/ai/redaction.dart';
import '../../core/models.dart';
import '../auth/session_controller.dart';
import 'ai_stores.dart';

typedef GitLabCredentialReader = AccountCredential? Function();

/// Live, conversation-scoped known secrets used by the redaction boundary.
///
/// [refresh] must run before every redaction. Provider keys come only from the
/// process-wide settings owner and are copied when its secret-set revision
/// changes. GitLab credentials are read on every call because OAuth refresh
/// updates the active API in place without changing the session generation.
/// Values are retained for this object's lifetime so rotated and deleted
/// secrets remain redacted from later turns in the same conversation.
final class KnownSecretsLive implements KnownSecretsSource {
  KnownSecretsLive(
    SessionController session,
    this._settings, {
    GitLabCredentialReader? readGitLabCredential,
  }) : _readGitLabCredential =
           readGitLabCredential ?? (() => session.api?.credential);

  final AiSettingsController _settings;
  final GitLabCredentialReader _readGitLabCredential;
  final Set<String> _known = <String>{};
  int _settingsSecretSetId = -1;
  int _revision = 0;

  @override
  Iterable<String> get current => Set<String>.unmodifiable(_known);

  int get revision => _revision;

  Future<void> refresh() => Future<void>.sync(() {
    final before = _known.length;
    final secretSetId = _settings.secretSetId;
    if (_settingsSecretSetId != secretSetId) {
      _known.addAll(_settings.knownProviderKeys.values);
      _settingsSecretSetId = secretSetId;
    }

    final credential = _readGitLabCredential();
    if (credential != null) {
      _known.add(credential.accessToken);
      if (credential case OAuthCredential(:final refreshToken)) {
        _known.add(refreshToken);
      }
    }
    if (_known.length != before) _revision += 1;
  });
}
