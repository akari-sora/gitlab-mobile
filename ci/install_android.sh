#!/usr/bin/env bash
set -euo pipefail
: "${FLUTTER_HOME:?Source ci/install_flutter.sh first}"
ROOT="${CI_PROJECT_DIR:-$(pwd)}"
export ANDROID_HOME="$ROOT/.android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
TOOLS_REVISION=15859902
TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
TOOLS_HOME="$ANDROID_HOME/cmdline-tools/$TOOLS_REVISION"
python3 "$ROOT/ci/install_android_tools.py" --ensure-network || true
if [ ! -x "$TOOLS_HOME/bin/sdkmanager" ]; then
  python3 "$ROOT/ci/install_android_tools.py" \
    --output-dir "$ANDROID_HOME/cmdline-tools" \
    --tools-revision "$TOOLS_REVISION" \
    --expected-sha256 "$TOOLS_SHA256" \
    --primary-url "https://dl.google.com/android/repository/commandlinetools-linux-${TOOLS_REVISION}_latest.zip" \
    --fallback-url "https://redirector.gvt1.com/edgedl/android/repository/commandlinetools-linux-${TOOLS_REVISION}_latest.zip"
fi
export PATH="$TOOLS_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
export JAVA_OPTS="-Djava.net.preferIPv4Stack=true -Dsun.net.client.defaultConnectTimeout=30000 -Dsun.net.client.defaultReadTimeout=60000"
export _JAVA_OPTIONS="-Djava.net.preferIPv4Stack=true -Dsun.net.client.defaultConnectTimeout=30000 -Dsun.net.client.defaultReadTimeout=60000"
java -version
compile_sdk="$(python3 - <<'PY'
import os, pathlib, re
source = pathlib.Path(os.environ['FLUTTER_HOME']) / 'packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt'
text = source.read_text()
match = re.search(r'compileSdkVersion\s*:\s*Int\s*=\s*(\d+)', text)
if not match:
    raise SystemExit('Cannot determine pinned Flutter compileSdkVersion; review SDK template')
print(match.group(1))
PY
)"
printf 'Installing Android API %s for the pinned Flutter SDK\n' "$compile_sdk"
# sdkmanager exits after consuming its prompts; avoid treating yes's SIGPIPE as failure.
set +o pipefail
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses > /tmp/gitlab-mobile-android-licenses.log
license_status=${PIPESTATUS[1]}
set -o pipefail
if [ "$license_status" -ne 0 ]; then
  cat /tmp/gitlab-mobile-android-licenses.log
  exit "$license_status"
fi
for attempt in 1 2 3; do
  if timeout 300 sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-$compile_sdk" "build-tools;36.0.0"; then
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    printf 'sdkmanager failed (attempt %s/3), retrying in 5s...\n' "$attempt" >&2
    sleep 5
  else
    printf 'sdkmanager failed after 3 attempts\n' >&2
    exit 1
  fi
done
flutter config --android-sdk "$ANDROID_HOME"
