# Content references and local HTML design previews

Harness recognizes complete single-line `:codex-file-citation{path="/absolute/file" purpose="source"}` directives. `purpose` is optional (`source` or `output`). Valid references show a filename link; malformed/incomplete references and references inside code, HTML tags/blocks, existing links, or escaped examples remain literal Markdown. The stored transcript is unchanged. Parsing maps rewritten byte ranges back to the original source, including task markers after references and incremental streaming. Filename labels are display text; Copy Link retains the full literal destination.

Complete Codex `visualize` content references (`\uE200visualize\uE202{"path":"/absolute/design.html","mode":"wide"}\uE201`, with actual private-use characters rather than those escapes) show **Preview · filename**. Only absolute `.html`/`.htm` paths and the optional `wide` mode are accepted. Arbitrary Markdown HTML remains literal.

## File access and ownership

Clicking a Preview opens a new session-owned native Browser tab. Source reads use `WorkspaceFilesClient` with the originating chat's target/device, including remote chats; they never fall back to reading the desktop host's filesystem. **Reload** rereads the file and destroys the old native page first. **Open source file** uses normal session-owned file navigation. Closing the tab cancels pending delivery and destroys its content and widget state. Errors do not navigate externally.

Harness's existing engine file RPC accepts workspace-relative paths only. The GUI therefore resolves absolute references against the source chat's cwd (including Windows source paths viewed on another OS), preserving `%`, `#` and other literal filename punctuation. Outside-workspace previews are explicitly refused. Put a self-contained export inside the chat's workspace; this feature does not widen engine filesystem authorization or follow symlinks itself. Ordinary Markdown and relative composer file mentions keep their existing behavior.

## Isolation and compatibility

Each preview uses a fresh ephemeral native context, separate from ordinary website tabs and login data. The in-memory wrapper contains a scripts-only `srcdoc` iframe with an opaque origin. An inherited CSP allows inline script/style and embedded data/blob images but denies network requests, external libraries, relative assets, forms, workers, and filesystem URLs. Native policy denies external navigation, popups and downloads. Preview-specific native delegates cancel file-upload panels and deny media permissions. WebRTC, DNS prefetch and speculative preconnect/prefetch are disabled natively because CSP alone does not cover every networking mechanism; hosts without those switches fail closed. No host tools, engine IPC, filesystem bridge, login profiles, or model messaging APIs are installed. HTML must be self-contained. The final wrapper is bounded to 900,000 UTF-16 units and 950,000 UTF-8 bytes, with the JSON-encoded body separately capped at 3,900,000 bytes (below the Linux helper's framed-command bound).

The optional independent compatibility subset provides:

- Previous/next navigation for `.viz-carousel > section[data-variant]`.
- `new Tweak({container, onChange})`, `addSelect(object, key, {label, options})`, `addToggle(object, key, {label})`, `refresh()` and `dispose()`. Controls use native inputs in per-panel shadow trees; changes update the supplied object before calling `onChange`.
- `window.openai.widgetState` and async `setWidgetState(object)`. State is JSON, bounded to **64 KiB encoded UTF-8**, copied on input/read/events, and local to that document. Successful updates dispatch `openai:set_globals` with `detail.globals.widgetState`; controls refresh after application listeners. Invalid updates leave state unchanged. Reload/close discard it; nothing is written to the transcript or sent to a model.

This is not a full Apps SDK or Codex plugin host. No proprietary plugin assets or Luau/GPU changes are included. Substantial parser/runtime adaptations retain Zeron's MIT attribution in `THIRD_PARTY_NOTICES.md`.

## Platform and verification gates

macOS and Linux native hosts are implemented. macOS requires WebKit's native peer-connection/DNS-prefetch preferences and feature toggles (macOS 13.3 or newer); Linux requires the WebKitGTK `enable-webrtc` and `enable-dns-prefetching` settings plus feature toggles (WebKitGTK 2.42 or newer). Both disable native speculative preconnect/prefetch features and verify those toggles took effect. A missing or ineffective setting produces an error rather than a less isolated preview. Native behavior must be checked on the release platforms, not inferred from JavaScript tests.

**Windows has no native Browser host in this Harness baseline.** It retains its existing external-web-link behavior and refuses HTML previews explicitly; executable content is never handed to the default browser. Full Windows design-preview parity requires a separate WebView2 host port and native isolation verification. Source-file links remain available within the existing file RPC policy.

Fast runtime checks (no build):

```sh
node --test crates/ui/tests/visualize-runtime.test.mjs
```

Rust/parser/document tests (coordinate the shared compile slot first):

```sh
cargo test --locked -p harness-ui --lib markdown::content_reference -- --test-threads=1
cargo test --locked -p harness-ui --lib browser::document -- --test-threads=1
cargo test --locked -p harness-ui --lib workspace_links -- --test-threads=1
cargo test --locked -p harness-ui --lib markdown::parser -- --test-threads=1
```

Real native-host isolation fixture (not a stub DOM):

```sh
cargo build --locked -p harness-ui --example browser-fixture --features browser-fixture
HARNESS_HTML_PREVIEW_FIXTURE_ONLY=1 bash scripts/run-macos-browser-fixture.sh \
  target/debug/examples/browser-fixture /tmp/harness-html-preview
test -f /tmp/harness-html-preview/result.txt
# Linux (with native runtime/dependencies installed):
HARNESS_HTML_PREVIEW_FIXTURE_ONLY=1 xvfb-run -a -s '-screen 0 1280x800x24' \
  target/debug/examples/browser-fixture /tmp/harness-linux-html-preview
test -f /tmp/harness-linux-html-preview/result.txt
```

The fixture executes controls and scripts inside the actual opaque frame, tests parent/storage/host-API isolation, blocks HTTP/file fetches and navigation/popups, checks native WebRTC disabling, and verifies fresh widget state after reconstructing the native page and teardown on close. A loopback sink independently counts escaped network attempts, including preconnect, preload, CSS, beacon and subresource requests. It excludes only the exact built-in Harness daemon discovery probe, whose Host/header bytes differ from WebKit's requests; empty connects and all other requests still fail the fixture. Its status-only `postMessage` relay is compiled **only** with `browser-fixture`; production wrappers have no message listener. The synthetic fixture bypasses source-file RPC; existing file-client routing tests and shell ownership tests cover that separate boundary.
