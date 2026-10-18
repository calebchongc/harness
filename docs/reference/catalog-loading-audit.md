# Catalog-loading integrity audit

This is a bounded, source-based audit of model/agent startup plus adjacent mobile host/folder/ref loading. It is not an exhaustive UI audit or a runtime reproduction of every finding. The independent findings below were checked against the PR's `v0.2.127` base; unrelated desktop and folder-browser changes are deliberately excluded from the model-catalog fix.

## Addressed by this PR

- Preserve a saved model ID and effort while host metadata is missing; never display or send a different catalog's first row as that saved selection.
- Offer only live or execution-device-cached agent/model rows. Loading, unavailable, and successful empty catalogs are not interchangeable.
- Unknown harness IDs must not inherit another harness's model list or options.
- Keep cached rows stable across reachability changes, refresh on reconnection, and scope metadata to the execution device so a host change cannot show the old host's catalog.
- Preserve offline queuing for an unverified saved selection, but block new-session dispatch when a live response positively rules out its agent or model. Explain the unavailable selection and require an explicit replacement.
- Keep new-session Send disabled until an unconfigured composer has a real model, and keep search honest while catalogs are still loading.

## Separate follow-ups identified

These are code-path findings, not claims that they caused the reported iOS model flash.

### iOS: stale folder-browser replies can cross device boundaries

`apps/ios/Harness/Views/SpaceView.swift`, `NewSpaceSheet.load(path:)`, assigns asynchronous folder results without verifying the request's device, cancellation, or a request generation. Switching device tabs while a request is pending can display one host's folder listing under another host. `create()` then combines the currently selected device with that stale path. Rapid navigation can similarly publish responses out of order.

The same flow changes `currentIsRepo` before navigation succeeds and does not reset it when changing devices. A failed navigation or device switch can therefore pair a folder with another folder's Git metadata.

A separate fix should bind listings and Git metadata to a device/request generation, commit them atomically on successful navigation, and gate creation on matching listing ownership. Cancellation checks alone are insufficient for concurrent navigation requests.

### iOS: ref request completion is represented as endless loading

`apps/ios/Harness/Views/NewSessionView.swift`, `RefPickerSheet`, renders “Loading refs from the device…” whenever `refs.isEmpty`. The parent does not distinguish loading, a completed empty result, and a failed request; its ref task is keyed only by the space ID. An offline host or an unborn repository can therefore leave a permanent loading message with no reconnect retry.

A separate fix should model loading/empty/failure explicitly and provide a retry/reconnect path.

### Desktop: implicit chat model can borrow an unrelated remembered label

`crates/ui/src/pickers.rs`, `selected_model_label()`, falls back to the last-used model label when an existing chat's model is implicit and its catalog has not loaded. Once the catalog loads, resolution can instead select the catalog default. The displayed model changes without a user selection; explicitly saved model IDs are already preserved correctly.

### Desktop: optimistic first-send transition can expose global defaults

The first-send transition in `crates/ui/src/composer.rs` selects a newly minted chat before its workspace row exists. The picker observer clears draft configuration during that transition. Until the row arrives, `effective_harness()` / `effective_model_id()` can resolve global remembered defaults from a different canvas. The first send captures its configuration earlier, so the concrete finding is a transient display/config-resolution gap, not proof that its initial request executes on the wrong model.

### Desktop: discovery errors can display an invented agent mark

`crates/ui/src/pickers.rs`, composer chip rendering, treats only idle/loading agent discovery as an unknown-harness loader. A discovery error with no configured or remembered harness can fall through to the Claude mark despite no resolved agent. Errors should retain a neutral unresolved-agent presentation.

### Desktop: successful empty models can remain a skeleton

`crates/ui/src/pickers.rs`, model-list rendering, handles an error specially but otherwise uses skeleton rows when no rows exist. That includes `Loadable::Ready([])` when there is no selection-only row. Normal prefetch does not reload a ready catalog, so successful empty discovery can appear to load forever.

A separate fix should render a completed empty state with an explicit retry, rather than an in-progress skeleton.
