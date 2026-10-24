# harness-nano

Harness's desktop app on [nanoui](https://github.com/justrach/nanoui), in Zig.

It's a new window over the same engine the GPUI app runs. The engine (the
Harness daemon, or `harness headless`) keeps the workspaces, sessions and
agents; harness-nano talks to it over the engine's local WebSocket RPC
(`crates/rpc`). Both apps can be open on one engine at once.

HTTPS goes through [http-zig](https://github.com/justrach/http-zig), the HTTP/2
client codegraff uses. For now it fetches the newest release's manifest.

## What it does

- Sidebar: your spaces and their chats, newest first, with each chat's status
  (working, waiting for you, errored). **Add folder** adds a space on this
  device.
- Chat: the transcript as it streams in, with Markdown replies (code
  highlighted, with a Copy button), reasoning, and each tool call with how it
  went.
- Composer: Return sends, Shift-Return starts a new line, **Stop** interrupts a
  running turn. A new chat picks its agent and model.

Not there yet: answering an agent's questions, diffs, changing an existing
chat's agent or model, the message queue, starting an engine when none is
running, Linux and Windows.

## Build and run

You need Zig 0.17.0 and, on macOS, Xcode or the Command Line Tools.

```sh
cd apps/nano
zig build test          # unit tests
zig build run           # build and open the window
sh scripts/bundle.sh    # release build as zig-out/Harness Nano.app
open "zig-out/Harness Nano.app"
```

An engine has to be running. With Harness open, its daemon already is, so
harness-nano shows your chats. Otherwise start one with `harness headless`.

harness-nano connects to `127.0.0.1:27664`. Set `HARNESS_IPC_PORT` to use
another engine.

## Trying it against a throwaway engine

To keep your own chats out of it, run a second engine with its own port, data
and home:

```sh
dir=$(mktemp -d)
HARNESS_IPC_PORT=27990 HARNESS_DATA_DIR="$dir/data" HOME="$dir/home" \
  /Applications/Harness.app/Contents/MacOS/harness headless &
HARNESS_IPC_PORT=27990 HARNESS_NANO_HARNESS=mock zig build run
```

`HARNESS_NANO_HARNESS` sets the agent new chats start with. The engine's
`mock` agent replies without a model or an account.

nanoui's flags render the window offscreen, with no window on screen, for
checks and screenshots:

```sh
HARNESS_IPC_PORT=27990 zig-out/bin/harness-nano --nanoui-snapshot=/tmp/nano.png \
  --nanoui-wait=3 --nanoui-script="click:Ask anything;type:Hello;key:enter;live:8"
```

## Layout

| File | |
|---|---|
| `src/ws.zig` | WebSocket client for the engine's socket. It sends no `Origin` header, which the engine refuses. |
| `src/rpc.zig` | The RPC frames: calls, replies, streams, cancel. |
| `src/engine.zig` | The connection: a reader thread, messages handed to the UI thread, reconnecting every 2 s. |
| `src/workspace.zig` | Spaces, chats, sessions, agents and models, each list replaced whole. |
| `src/transcript.zig` | A chat's transcript: resets and deltas, checked as `apply_transcript_frame` checks them. |
| `src/app.zig` | The state, and the calls the GPUI app makes to open a chat, create one and send. |
| `src/view*.zig`, `src/theme.zig` | The window, in Harness's Codegraff Light and Dark colors. |
| `src/markdown.zig`, `markdown_html.zig`, `highlight.zig` | nanoterm's Markdown parser and code highlighting, unchanged. |
| `src/release.zig` | The newest release, over HTTP/2. |
