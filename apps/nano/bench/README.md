# harness-nano against the GPUI app: resources

`resource.py` runs the GPUI app's UI-only replay
(`crates/ui/examples/macos-resource-profile.rs`) and harness-nano's
(`src/profile.zig`) on the same made-up transcript replay
(`make_replay.py`), one after the other, never together, and samples each
with `scripts/macos-resource-stat.c` (CPU time, resident size, physical
footprint, idle wakeups) every 500 ms. Both draw offscreen with real
CoreText and Metal at 1320 by 880, 2x; no window, engine or account.

```bash
# The GPUI profiler (once):
CARGO_TARGET_DIR=$HOME/.cargo/shared-target CARGO_INCREMENTAL=0 \
  scripts/heavy-build.sh cargo build --profile app-dev -p harness-ui \
  --features resource-profile --example macos-resource-profile
# nano's:
zig build -Doptimize=ReleaseFast --fork=$HOME/nanoui
python3 bench/resource.py --runs 2
```

The last results are in `docs/performance/nano-gpui-offscreen.json`.
