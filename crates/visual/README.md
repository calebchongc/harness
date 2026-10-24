# harness-visual

Fresh, deliberately small Luau-to-native-node runtime. It describes app-native UI;
it does not embed HTML, JavaScript, a browser, or arbitrary styled surfaces.

## Host API

```rust,ignore
use harness_visual::{Input, Visual};

let mut visual = Visual::new(include_str!("examples/dashboard.luau"))?;
let tree = visual.render()?;
// Render tree with native controls. Keep each control's optional handler ID.
let updated = visual.call(tree.children[3].handler.unwrap(), Input::Click)?;
```

`Visual` is `Send`: create, render and dispatch it on a worker, behind a mutex if
shared. Each successful render returns a plain, cloneable, serializable `Node`.
`call` invokes one callback and re-renders with the updated local state. Handler
IDs belong only to the latest render, never repeat within a visual, and become
invalid on the next render/dispatch (including failed rendering). Unknown IDs,
wrong event types, nonfinite input and out-of-range slider input return errors.
A handler or render error does not roll back mutations of Luau local state.

`check(script)` evaluates setup and validates the first render only. It **does
not** execute or validate all possible event handlers or future state branches.
The host must handle later errors too. Constructing a visual alone does not render.

## DSL

Scripts initialize local state and return a zero-argument render function.
See [`examples/dashboard.luau`](examples/dashboard.luau) for a complete worked
example exercised by the crate's tests.

| Constructor | Accepted properties / arguments |
| --- | --- |
| `ui.column{...}`, `ui.row{...}` | Dense child-node arrays, no layout properties |
| `ui.text('Text')`, `ui.text{text='Text'}` | Text or a finite numeric scalar |
| `ui.stat{label='Count', value='42'}` | Label and value become `Node.text = "Count: 42"` |
| `ui.chart{label='Trend', values={1,2}, labels={'a','b'}}` | Finite numbers; labels optional, matching values in length when present |
| `ui.button{label='Add', onClick=function() ... end}` | Optional click callback |
| `ui.toggle{label='Enabled', value=false, onChange=function(value) ... end}` | Boolean value and optional boolean callback |
| `ui.slider{label='Target', value=3, min=0, max=10, onChange=function(value) ... end}` | Finite numeric value/range and optional numeric callback |
| `ui.rule{}` | No properties |

Labels default to empty strings. Toggle `Node.value` is 0 or 1. Slider ranges
are inclusive; equal min/max is valid. Text, labels, stat values, and chart labels
accept strings or finite numeric scalars; they never invoke `tostring` metamethods.
Only columns/rows have children. Chart values live in `Node.values`, with optional
`Node.labels`; other labels live in `Node.text`. `Node.handler` is host-only data,
not a function or script-controlled numeric ID.

Unknown kinds/properties are errors, including CSS/style, background, font,
raw colors and arbitrary container options. Tables are validated with raw access;
metatables cannot synthesize nodes, hide extra fields, or execute while parsing.

## Sandbox and bounds

- Source: at most 64 KiB, text-only compilation.
- Luau VM memory: at most 16 MiB (including libraries and live state).
- Setup, each render, and each callback-plus-render: a 20 ms budget enforced by
  a Luau interrupt and host-side deadline checks. Interrupts are cooperative VM
  checkpoints, not hard real-time preemption of native library calls/compilation.
- Rendered tree: depth at most 24 (root depth 1), at most 512 nodes, at most
  8 KiB of combined UTF-8 text/labels, and at most 256 total chart values.
- Arrays must be dense, without extra named properties. NaN and infinity are
  rejected in numeric output and input. Slider bounds/value are validated.
- Only base functions plus table/string/math/UTF-8 libraries; no filesystem,
  network, `require`, code loading, output, OS/debug/package/coroutine/buffer
  libraries, or environment-changing functions. Libraries and built-in
  metatables are frozen via Luau sandboxing. Each visual has its own VM.
- Callback references are replaced, not accumulated, each render. Failed parsing
  discards partial handler sets. Old closures can be reclaimed by the VM's GC.

No external source was copied. This crate does not provide durable persistence,
background timers, arbitrary I/O, dynamic imports, or handler-wide static checking.
