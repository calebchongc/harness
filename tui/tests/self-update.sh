#!/bin/sh
# Offline test of harness-tui's self-update against a fake release served from file://.
#   tui/tests/self-update.sh
set -eu
wrapper=$(cd "$(dirname "$0")/.." && pwd)/bin/harness-tui
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
os=$(uname -s | tr '[:upper:]' '[:lower:]'); case "$os" in darwin) os=macos ;; esac
arch=$(uname -m); case "$arch" in arm64) arch=aarch64 ;; esac
fail() { echo "FAIL: $*" >&2; exit 1; }

# A client install: the real wrapper plus stub binaries (a bridge that listens, a TUI that echoes).
install_client() { # dir label
  mkdir -p "$1/bin" "$1/libexec"
  cp "$wrapper" "$1/bin/harness-tui"
  ln -sf harness-tui "$1/bin/graff-tui"
  cat >"$1/libexec/harness-tui-bridge" <<'PY'
#!/usr/bin/env python3
import socket, sys, time
host, port = sys.argv[1].rsplit(":", 1)
s = socket.socket(); s.bind((host, int(port))); s.listen(); time.sleep(30)
PY
  printf '#!/bin/sh\necho "%s $*"\n' "$2" >"$1/libexec/harness-tui"
  chmod +x "$1/bin/harness-tui" "$1/libexec/harness-tui-bridge" "$1/libexec/harness-tui"
}

# A fake release 0.2.200 whose client's wrapper just reports itself.
release() { # base good-checksum?
  name=harness-tui-0.2.200-$os-$arch
  mkdir -p "$1/latest/download" "$1/download/v0.2.200" "$1/stage/$name/bin" "$1/stage/$name/libexec"
  echo '{"version":"0.2.200"}' >"$1/latest/download/manifest.json"
  printf '#!/bin/sh\necho "new $*"\n' >"$1/stage/$name/bin/harness-tui"
  chmod +x "$1/stage/$name/bin/harness-tui"
  ln -sf harness-tui "$1/stage/$name/bin/graff-tui"
  : >"$1/stage/$name/libexec/harness-tui-bridge"
  tar -C "$1/stage" -czf "$1/download/v0.2.200/$name.tar.gz" "$name"
  sum=$({ shasum -a 256 "$1/download/v0.2.200/$name.tar.gz" 2>/dev/null || sha256sum "$1/download/v0.2.200/$name.tar.gz"; } | awk '{print $1}')
  [ "$2" = good ] || sum=0000000000000000000000000000000000000000000000000000000000000000
  echo "$sum  $name.tar.gz" >"$1/download/v0.2.200/$name.tar.gz.sha256"
}

run() { # home -> stdout of graff-tui --version
  HOME=$1 HARNESS_TUI_RELEASES=file://$tmp/rel "$1/.local/bin/graff-tui" --version 2>"$1/err"
}

setup() { # home
  rm -rf "$1"; mkdir -p "$1/.local/bin"
  install_client "$1/.harness/tui/0.2.100" current
  ln -s "$1/.harness/tui/0.2.100/bin/graff-tui" "$1/.local/bin/graff-tui"
}

# 1. A newer release installs, the link moves, and the new client runs.
rm -rf "$tmp/rel"; release "$tmp/rel" good
h=$tmp/h1; setup "$h"
out=$(run "$h"); [ "$out" = "new --version" ] || fail "update: got '$out'"
[ "$(readlink "$h/.local/bin/graff-tui")" = "$h/.harness/tui/0.2.200/bin/graff-tui" ] || fail "link not moved"
[ -f "$h/.harness/tui/.last-update-check" ] || fail "no stamp after update"
ls "$h/.harness/tui" | grep -q '^\.install-' && fail "work dir left behind"

# 2. A bad checksum keeps the current client, and leaves no stamp so the next start retries.
rm -rf "$tmp/rel"; release "$tmp/rel" bad
h=$tmp/h2; setup "$h"
out=$(run "$h"); [ "$out" = "current --version" ] || fail "bad checksum: got '$out'"
[ ! -e "$h/.harness/tui/0.2.200" ] || fail "bad tarball installed"
[ ! -e "$h/.harness/tui/.last-update-check" ] || fail "stamp after a failed update"
grep -q "Couldn't update graff tui" "$h/err" || fail "no notice on failure"

# 3. A recent check skips the lookup entirely.
rm -rf "$tmp/rel"; release "$tmp/rel" good
h=$tmp/h3; setup "$h"; touch "$h/.harness/tui/.last-update-check"
out=$(run "$h"); [ "$out" = "current --version" ] || fail "fresh stamp: got '$out'"

# 4. The opt-out.
h=$tmp/h4; setup "$h"
out=$(HARNESS_TUI_AUTO_UPDATE=0 run "$h"); [ "$out" = "current --version" ] || fail "opt-out: got '$out'"

# 5. A client outside ~/.harness/tui (an unpacked tarball, a dev build) is left alone.
h=$tmp/h5; setup "$h"; install_client "$tmp/elsewhere/0.2.100" elsewhere
out=$(HOME=$h HARNESS_TUI_RELEASES=file://$tmp/rel "$tmp/elsewhere/0.2.100/bin/harness-tui" --version 2>/dev/null)
[ "$out" = "elsewhere --version" ] || fail "unmanaged: got '$out'"

echo "self-update: all 5 cases pass"
