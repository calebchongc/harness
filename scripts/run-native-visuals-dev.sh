#!/usr/bin/env bash
# An isolated, synthetic chat using the production Harness shell and visual renderer.
# Does not replace the installed app or connect to its data/IPC port.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"
cd "$ROOT"
APP="$ROOT/target/visuals-dev/Harness Visuals Dev.app"
CONTENTS="$APP/Contents"
if pgrep -f -x "$CONTENTS/MacOS/harness-visuals" >/dev/null 2>&1; then
  echo "Harness Visuals Dev is already open; quit that dev app before rebuilding." >&2
  exit 1
fi
cargo build -p harness-ui --example visuals-fixture --features appshots-fixture -j "${CARGO_BUILD_JOBS:-6}"
TARGET_DIR="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "$TARGET_DIR/debug/examples/visuals-fixture" "$CONTENTS/MacOS/harness-visuals"
python3 - "$CONTENTS/Info.plist" <<'PY'
import pathlib, plistlib, re, sys
version = re.search(r'^version = "([^"]+)"', pathlib.Path('Cargo.toml').read_text(), re.M).group(1)
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'harness.codegraff.visuals.dev',
        'CFBundleName': 'Harness Visuals Dev',
        'CFBundleDisplayName': 'Harness Visuals Dev',
        'CFBundleExecutable': 'harness-visuals',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': '1',
        'NSHighResolutionCapable': True,
    }, output)
PY
codesign --force --sign - --identifier harness.codegraff.visuals.dev "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
open -n --env "HARNESS_VISUALS_DATA=$ROOT/target/visuals-dev/data" "$APP" --args "$@"
echo "Opened Harness Visuals Dev — synthetic data, isolated from the installed app."
