#!/usr/bin/env bash
set -euo pipefail
export GRADLE_USER_HOME="${CI_PROJECT_DIR:-$(pwd)}/.gradle-user"
export GRADLE_OPTS='-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2 -Dorg.gradle.jvmargs=-Xmx3g -Djava.net.preferIPv4Stack=true -Dsun.net.client.defaultConnectTimeout=30000 -Dsun.net.client.defaultReadTimeout=60000'
if [ ! -d android ]; then
  tar -xzf ci-output/native-templates.tar.gz
fi
if [ -f ci-output/pubspec.lock ]; then
  cp ci-output/pubspec.lock pubspec.lock
fi
flutter pub get --enforce-lockfile
dart run flutter_launcher_icons
python3 tool/android_signing.py configure android/app/build.gradle.kts

# Normal local builds require the shared external PKCS12 identity. CI may use
# the historical stable debug key, or an explicitly enabled ephemeral key, for
# this debug-only preview job. Both CI paths are converted/generated as PKCS12
# and restricted to the debug build type by signing.properties.
signing_properties="${GITLAB_MOBILE_SIGNING_PROPERTIES:-$HOME/.config/gitlab-mobile/android-signing/signing.properties}"
PREVIEW_SIGNING='Managed GitLab Mobile PKCS12 identity (debug build)'
if [ -f "$signing_properties" ]; then
  python3 tool/android_signing.py verify --properties "$signing_properties"
elif [ -n "${GITLAB_MOBILE_SIGNING_PROPERTIES:-}" ]; then
  printf '%s\n' "Explicit Android signing properties are missing: $signing_properties" >&2
  exit 1
elif [ "${CI:-}" = 'true' ] && [ -n "${ANDROID_DEBUG_KEYSTORE_B64:-}" ]; then
  signing_dir="${CI_PROJECT_DIR:-$(pwd)}/.ci-signing"
  mkdir -p "$signing_dir"
  chmod 700 "$signing_dir"
  printf '%s' "$ANDROID_DEBUG_KEYSTORE_B64" | base64 -d > "$signing_dir/legacy-debug.keystore"
  chmod 600 "$signing_dir/legacy-debug.keystore"
  export GITLAB_MOBILE_CI_KEYSTORE_PASSWORD='android'
  keytool -importkeystore -noprompt \
    -srckeystore "$signing_dir/legacy-debug.keystore" \
    -srcstorepass:env GITLAB_MOBILE_CI_KEYSTORE_PASSWORD \
    -srcalias androiddebugkey -srckeypass:env GITLAB_MOBILE_CI_KEYSTORE_PASSWORD \
    -destkeystore "$signing_dir/gitlab-mobile-ci.p12" -deststoretype PKCS12 \
    -deststorepass:env GITLAB_MOBILE_CI_KEYSTORE_PASSWORD \
    -destkeypass:env GITLAB_MOBILE_CI_KEYSTORE_PASSWORD
  signing_properties="$signing_dir/signing.properties"
  export GITLAB_MOBILE_ALLOW_DEBUG_ONLY_SIGNING='1'
  python3 tool/android_signing.py write-ci-properties \
    --properties "$signing_properties" --keystore "$signing_dir/gitlab-mobile-ci.p12" \
    --mode stable-legacy-debug
  PREVIEW_SIGNING='Stable legacy CI debug identity (debug build only); not a production release'
elif [ "${CI:-}" = 'true' ] && [ "${GITLAB_MOBILE_ALLOW_EPHEMERAL_DEBUG_SIGNING:-}" = '1' ]; then
  signing_dir="${CI_PROJECT_DIR:-$(pwd)}/.ci-signing"
  mkdir -p "$signing_dir"
  chmod 700 "$signing_dir"
  export GITLAB_MOBILE_CI_KEYSTORE_PASSWORD='android'
  keytool -genkeypair -noprompt -keystore "$signing_dir/gitlab-mobile-ci.p12" \
    -storetype PKCS12 -storepass:env GITLAB_MOBILE_CI_KEYSTORE_PASSWORD \
    -keypass:env GITLAB_MOBILE_CI_KEYSTORE_PASSWORD -alias androiddebugkey \
    -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=GitLab Mobile CI Debug'
  chmod 600 "$signing_dir/gitlab-mobile-ci.p12"
  signing_properties="$signing_dir/signing.properties"
  export GITLAB_MOBILE_ALLOW_DEBUG_ONLY_SIGNING='1'
  python3 tool/android_signing.py write-ci-properties \
    --properties "$signing_properties" --keystore "$signing_dir/gitlab-mobile-ci.p12" \
    --mode ephemeral-debug
  PREVIEW_SIGNING='Ephemeral CI debug identity (debug build only); not update-compatible or a production release'
else
  printf '%s\n' "Stable Android signing identity is missing: $signing_properties" >&2
  printf '%s\n' 'Run: python3 tool/android_signing.py init' >&2
  exit 1
fi
export GITLAB_MOBILE_SIGNING_PROPERTIES="$signing_properties"
export PREVIEW_SIGNING
flutter build apk --debug --no-pub --dart-define=GITLAB_MOBILE_COMMIT="${CI_COMMIT_SHORT_SHA:-local}"
mkdir -p artifacts
short_sha="${CI_COMMIT_SHORT_SHA:-local}"
cp build/app/outputs/flutter-apk/app-debug.apk "artifacts/gitlab-mobile-${short_sha}-debug.apk"
python3 - <<'PY'
import json, os, pathlib, subprocess
flutter = json.loads(subprocess.check_output(['flutter', '--version', '--machine'], text=True))
metadata = {
    'kind': 'development-preview',
    'signing': os.environ.get('PREVIEW_SIGNING', 'Android debug key; not a production release'),
    'commit': os.environ.get('CI_COMMIT_SHA'),
    'pipeline_url': os.environ.get('CI_PIPELINE_URL'),
    'job_url': os.environ.get('CI_JOB_URL'),
    'flutter_version': flutter.get('frameworkVersion'),
    'flutter_revision': flutter.get('frameworkRevision'),
    'dart_version': flutter.get('dartSdkVersion'),
    'device_acceptance': 'NOT_RUN',
}
pathlib.Path('artifacts/build-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
(cd artifacts && sha256sum *.apk build-metadata.json > SHA256SUMS)
