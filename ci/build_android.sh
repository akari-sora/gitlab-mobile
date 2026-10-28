#!/usr/bin/env bash
set -euo pipefail
# These are compile-time options. Environment variables cannot opt a build in:
# a release configuration must pass each enabled option on the command line.
ai_assistant=false
ai_background=false
flavor=gitlab
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ai-assistant|--ai-background|--flavor)
      option="$1"
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$option" >&2; exit 1; }
      case "$option" in
        --ai-assistant) ai_assistant="$2" ;;
        --ai-background) ai_background="$2" ;;
        --flavor) flavor="$2" ;;
      esac
      shift 2
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
case "$ai_assistant:$ai_background" in
  false:false|true:false|true:true) ;;
  *) printf '%s\n' 'Invalid AI flags (background requires the assistant).' >&2; exit 1 ;;
esac
case "$flavor" in
  gitlab) ;;
  play)
    if [ "$ai_assistant" != false ] || [ "$ai_background" != false ]; then
      printf '%s\n' 'Play AI flags must remain off.' >&2
      exit 1
    fi
    ;;
  *) printf 'Unknown flavor: %s\n' "$flavor" >&2; exit 1 ;;
esac
export MR7_AI_ASSISTANT="$ai_assistant" MR7_AI_BACKGROUND="$ai_background"
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

# Normal local builds require the shared external PKCS12 identity and build
# GITLAB_MOBILE_BUILD_TYPE (debug by default). In CI, protected refs receive the
# historical stable key and build release; other pipelines use an explicitly
# enabled ephemeral key that signing.properties restricts to debug builds.
signing_properties="${GITLAB_MOBILE_SIGNING_PROPERTIES:-$HOME/.config/gitlab-mobile/android-signing/signing.properties}"
BUILD_TYPE="${GITLAB_MOBILE_BUILD_TYPE:-debug}"
case "$BUILD_TYPE" in
  debug|profile|release) ;;
  *) printf '%s\n' "Unknown GITLAB_MOBILE_BUILD_TYPE: $BUILD_TYPE" >&2; exit 1 ;;
esac
PREVIEW_SIGNING="Managed GitLab Mobile PKCS12 identity ($BUILD_TYPE build)"
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
  python3 tool/android_signing.py write-ci-properties \
    --properties "$signing_properties" --keystore "$signing_dir/gitlab-mobile-ci.p12" \
    --mode stable-legacy-release
  BUILD_TYPE=release
  PREVIEW_SIGNING='Stable legacy CI identity (Android debug certificate), GitLab channel release build; not a Play or production release'
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
  BUILD_TYPE=debug
  PREVIEW_SIGNING='Ephemeral CI debug identity (debug build only); not update-compatible or a production release'
else
  printf '%s\n' "Stable Android signing identity is missing: $signing_properties" >&2
  printf '%s\n' 'Run: python3 tool/android_signing.py init' >&2
  exit 1
fi
export GITLAB_MOBILE_SIGNING_PROPERTIES="$signing_properties"
export PREVIEW_SIGNING
# The GitLab distribution channel. The project's pipeline IID only grows, so
# CI builds carry a monotonic versionCode that in-app updates compare.
export GITLAB_MOBILE_FLAVOR="$flavor"
# (Expanded with +"..." below: macOS bash 3.2 treats an empty array as unset.)
build_number_args=()
if [ -n "${CI_PIPELINE_IID:-}" ]; then
  build_number_args=(--build-number="$CI_PIPELINE_IID")
fi
export BUILD_TYPE
# No --no-pub: that also skips regenerating GeneratedPluginRegistrant, and the
# one `pub get` wrote above lists dev-only plugins (integration_test) that a
# release build does not link. The lockfile is already resolved, so the build's
# own pub step must leave it byte-for-byte unchanged.
lock_before="$(sha256sum pubspec.lock)"
flutter build apk "--$BUILD_TYPE" --flavor "$GITLAB_MOBILE_FLAVOR" ${build_number_args[@]+"${build_number_args[@]}"} \
  --target lib/main.dart \
  --dart-define=GITLAB_MOBILE_COMMIT="${CI_COMMIT_SHORT_SHA:-local}" \
  --dart-define=MERGELINE_AI_ASSISTANT="$MR7_AI_ASSISTANT" \
  --dart-define=MERGELINE_AI_BACKGROUND="$MR7_AI_BACKGROUND"
if [ "$(sha256sum pubspec.lock)" != "$lock_before" ]; then
  printf '%s\n' 'flutter build changed pubspec.lock; the committed lockfile is enforced.' >&2
  exit 1
fi
mkdir -p artifacts
short_sha="${CI_COMMIT_SHORT_SHA:-local}"
cp "build/app/outputs/flutter-apk/app-$GITLAB_MOBILE_FLAVOR-$BUILD_TYPE.apk" "artifacts/gitlab-mobile-${short_sha}-$BUILD_TYPE.apk"
python3 - <<'PY'
import hashlib, json, os, pathlib, re, subprocess, sys
sys.path.insert(0, 'ci')
from mr7_attestation import source_digests
flutter = json.loads(subprocess.check_output(['flutter', '--version', '--machine'], text=True))
version = re.search(r'^version:\s*([^+\s]+)\+(\d+)\s*$', pathlib.Path('pubspec.yaml').read_text(), re.M)
if version is None:
    raise SystemExit('pubspec.yaml has no name+code version')
apk = pathlib.Path('artifacts') / f"gitlab-mobile-{os.environ.get('CI_COMMIT_SHORT_SHA', 'local')}-{os.environ['BUILD_TYPE']}.apk"
metadata = {
    'kind': 'development-preview',
    'signing': os.environ.get('PREVIEW_SIGNING', 'Android debug key; not a production release'),
    'channel': os.environ['GITLAB_MOBILE_FLAVOR'],
    'build_type': os.environ['BUILD_TYPE'],
    'ai_assistant': os.environ['MR7_AI_ASSISTANT'] == 'true',
    'ai_background': os.environ['MR7_AI_BACKGROUND'] == 'true',
    'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
    'package': None,
    'debuggable': None,
    'certificate_sha256': None,
    'entrypoint': 'lib/main.dart',
    'version_name': version.group(1),
    'version_code': int(os.environ.get('CI_PIPELINE_IID') or version.group(2)),
    'commit': os.environ.get('CI_COMMIT_SHA'),
    'pipeline_url': os.environ.get('CI_PIPELINE_URL'),
    'job_url': os.environ.get('CI_JOB_URL'),
    'flutter_version': flutter.get('frameworkVersion'),
    'flutter_revision': flutter.get('frameworkRevision'),
    'dart_version': flutter.get('dartSdkVersion'),
    'device_acceptance': 'NOT_RUN',
}
metadata.update(source_digests(require_clean=True))
if metadata['ai_assistant']:
    # Record facts read from the exact APK; publication independently rechecks them.
    sdk = pathlib.Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or '')
    aapt = sorted((sdk / 'build-tools').glob('*/aapt2'))
    signers = sorted((sdk / 'build-tools').glob('*/apksigner'))
    if not aapt or not signers:
        raise SystemExit('AI-on build requires Android SDK aapt2 and apksigner')
    badging = subprocess.check_output([str(aapt[-1]), 'dump', 'badging', str(apk)], text=True)
    header = next((line for line in badging.splitlines() if line.startswith('package: ')), '')
    values = dict(re.findall(r"(\w+)='([^']*)'", header))
    expected_package = {'gitlab': 'io.gitlabmobile.gitlab_mobile', 'play': 'app.mergeline'}[metadata['channel']]
    if values.get('name') != expected_package:
        raise SystemExit('APK package does not match build flavor')
    signing = subprocess.check_output([str(signers[-1]), 'verify', '--verbose', '--print-certs', str(apk)], text=True)
    certificates = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F:]+)\s*$', signing, re.M)
    if len(certificates) != 1 or not re.fullmatch(r'[0-9a-f]{64}', certificates[0].replace(':', '').lower()):
        raise SystemExit('Expected exactly one APK signing certificate')
    metadata.update(package=values['name'],
                    debuggable=bool(re.search(r'^application-debuggable$', badging, re.M)),
                    certificate_sha256=certificates[0].replace(':', '').lower())
pathlib.Path('artifacts/build-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
(cd artifacts && sha256sum *.apk build-metadata.json > SHA256SUMS)
