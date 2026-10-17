# Native visuals — interactive output in Harness desktop

## Product direction

**Harness is the workspace where agents turn an answer into something you can use.**

The first step is interactive output inside a conversation: explore a scenario, compare alternatives, and adjust assumptions without asking the model to rewrite a paragraph for every change. Graff supplies the reasoning and tools; Harness supplies a consistent, native interface across agents.

Lead with a concrete job rather than “AI-generated UI”: “Compare three rollout plans, adjust the expected traffic, and see the capacity trade-off.” A useful demo starts with a question, produces a small interactive model, changes one assumption, then explains the decision. It should distinguish synthetic examples from measured results.

This is complementary to building real products. Project previews, browser inspection, and screenshot feedback remain the right workflow for editing a website or application. Native visuals are small conversational tools, not a replacement IDE, browser, or general application platform.

## Scope

This implementation is deliberately small and independently implemented, inspired by [Zeron's native visuals](https://github.com/zeronsh/zeron/pull/900), not a wholesale port of its renderer or GPU stack.

- An agent publishes a titled Luau script with `show_visual` in an active Harness turn, including Graff turns using Harness MCP.
- The script produces themed native rows, columns, text, statistics, bar charts, buttons, toggles, sliders, and rules.
- Scripts have no filesystem, process, network, module-loading, or application API access. Both initial rendering and interactions run away from the UI thread with memory, time, tree, and payload limits.
- The title and bounded source are explicit conversation content and synchronize with the transcript. Do not embed secrets or private context that should not be part of the conversation.
- Interaction state is local and temporary. Reopening a conversation, eviction from the bounded resident cache, or restarting the app resets it to the script's initial state. Changing a control does not send a model request or run a shell command.

Not included: arbitrary HTML/CSS, asset loading, 3D, shaders, animation loops, persistent/shared control state, automatic screenshot feedback to the model, or mobile visual rendering. Current mobile decoders show a title-only notice to open the visual in Harness desktop; older mobile versions skip the part while retaining the rest of the conversation.

Use matching desktop UI and engine versions, as shipped together by Harness. Older desktops reading synced documents safely skip visuals, but an older UI attached directly to a newer engine can reject the new typed RPC part. Mixed-version desktop UI/engine connections are not compatibility-negotiated. The isolated development demo below does not affect installed-app data.

## Agent authoring

Call `show_visual` with a human-readable `title` and a `script` string. The tool is only available with a chat context and publishes into that chat's active turn. It does not select a destination supplied by the agent. Source is limited to 64 KiB and the title to 200 characters. The script returns a render function; state belongs in locals outside that function:

```lua
local traffic = 50
return function()
    return ui.column{
        ui.text('Illustrative capacity scenario — not a benchmark'),
        ui.chart{
            label='Requests per second',
            values={traffic, traffic * 1.5, traffic * 2},
            labels={'Current', 'Growth', 'Peak'},
        },
        ui.slider{
            label='Baseline requests per second', value=traffic, min=1, max=100,
            onChange=function(value) traffic = value end,
        },
    }
end
```

The host owns colors, fonts, spacing, and control appearance. Unknown nodes and styling properties are errors, not silently ignored CSS. Arrays must be dense; numbers must be finite. Limits per render are 512 nodes, depth 24, 8 KiB aggregate text, and 256 aggregate chart values. Each sandbox has a 16 MiB memory budget and a 20 ms execution deadline. Luau interrupts are cooperative: native library calls and compilation also receive post-call deadline checks, not hard real-time preemption.

Initial validation checks setup and the first render, not every possible event path. An interaction that errors or exceeds a limit becomes a visible unavailable state rather than an app capability escalation. Scripts must keep both rendering and handlers small and deterministic. A successful publication acknowledges durable conversation publication, not proof that every handler works or that every client can render the visual.

## Run the isolated preview

On macOS:

```sh
bash scripts/run-native-visuals-dev.sh
```

This builds and opens `target/visuals-dev/Harness Visuals Dev.app` with its own bundle identity and local data. The production shell displays a synthetic capacity-planning conversation. It does not replace the installed app, use its engine port, or send a model request. Try **Capacity**, **Efficiency mode**, **Save scenario**, and **Reset**.

For a reproducible capture with assertions on the same interaction dispatch used by the controls:

```sh
cargo run -p harness-ui --example visuals-fixture --features appshots-fixture -- \
  --capture target/visuals-dev/captures
```

The fixture checks that the slider changes chart data, the toggle changes estimated cost, and the button changes the saved-state label, then saves native-window before/after images and exits. Add `--light` to exercise the light theme. The dev renderer uses a fixed-height, internally scrolling card so interactive changes do not invalidate transcript row measurements. Only eight sandboxes remain resident per transcript; evicted visuals restart when viewed again. Charts show at most twelve directly labeled values at once and explicitly disclose truncation.
