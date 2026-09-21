#!/usr/bin/env bash
set -euo pipefail
export GRADLE_USER_HOME="${CI_PROJECT_DIR:-$(pwd)}/.gradle-user"
export GRADLE_OPTS='-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2 -Dorg.gradle.jvmargs=-Xmx3g'
if [ ! -d android ]; then
  tar -xzf ci-output/native-templates.tar.gz
fi
if [ -f ci-output/pubspec.lock ]; then
  cp ci-output/pubspec.lock pubspec.lock
fi
flutter pub get --enforce-lockfile
dart run flutter_launcher_icons
flutter build apk --debug --no-pub
mkdir -p artifacts
short_sha="${CI_COMMIT_SHORT_SHA:-local}"
cp build/app/outputs/flutter-apk/app-debug.apk "artifacts/gitlab-mobile-${short_sha}-debug.apk"
python3 - <<'PY'
import json, os, pathlib, subprocess
flutter = json.loads(subprocess.check_output(['flutter', '--version', '--machine'], text=True))
metadata = {
    'kind': 'development-preview',
    'signing': 'Android debug key; not a production release',
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
