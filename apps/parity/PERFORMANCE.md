# Performance monitor

Both apps time themselves on the device and show the result under Settings > Performance. Anonymous sharing is
on by default and can be turned off in Settings; existing explicit opt-outs are preserved. "Copy report" produces plain numbers (no chat content, names or identifiers).

| | iOS (`PerfMonitor.swift`) | Android (`perf/Perf.kt`) |
| --- | --- | --- |
| Operations against budgets | `Perf.measure`, also signpost intervals for Instruments | `Perf.measure`, also `Trace` sections for Perfetto |
| Frame health | main run loop turn length: slow over 16.7 ms, frozen over 700 ms | `FrameMetrics` per frame against the system's own deadline, with the stage that took longest |
| Main-thread stalls | any turn of 50 ms or more, recorded as `main.stall` | a 100 ms timer that fires late, recorded as `main.stall` |
| Startup | process start to first screen | process start to first draw |
| Device | memory footprint, thermal state, Low Power Mode | Java and native heap, collections, thermal status, Battery Saver |

The operations and budgets are pinned in `perf-contract.json`: `startup.firstFrame`, `nav.open` (tap to the page it
opened), `transcript.rows`, `markdown.parse`, `home.group`, `send.apply`, `main.stall`. An operation over budget is
shown in red and logged (`HarnessPerf` on Android, the `perf` category on iOS).

Reading it: if slow frames blame layout, look at measure and layout work; if they blame the GPU or display, the cost
is in what is drawn or the device, not in Kotlin or Swift code. A stall with no slow operation beside it is work the
monitor does not name yet, so add a span there.

## Sharing anonymous performance numbers

iOS sends **OpenTelemetry OTLP/HTTP JSON** to `POST /v1/metrics`: one resource, one
`harness.ios.performance` instrumentation scope, and delta explicit-bucket histograms. The payload uses standard
OTLP nanosecond timestamp strings, string-encoded 64-bit counts, units, bounds, sums and maxima. It does not require
an SDK dependency or send raw samples. Android and desktop retain `POST /v1/harness/stats`; the legacy mobile vectors
continue to test that format. Bucket percentiles estimate a range's upper bound, not an exact sample percentile.

Sharing is on by default. iOS honors the latest explicit setting, including opt-outs from earlier timing-only
releases. Only physical-device release builds collect or upload diagnostics; simulator and debug builds never do.
iOS samples its own process every five foreground seconds:
CPU utilization (`1`, where 1 means one occupied core), physical memory footprint (`By`), physical disk-write bytes
per sampled interval (`By`) and write rate (`By/s`). Counter failures and suspension gaps are omitted, never made into
zero samples. Disk I/O counters are not logical filesystem writes or SQLite attribution.

While a visible transcript scrolls or streams, iOS also records display-link callback delay (`ms`) using the current
refresh interval. This is a responsiveness proxy, **not measured GPU/render-server hitch time or FPS**. Its display
link stops while idle/backgrounded or sharing is disabled. Existing operation and main-thread timings use `ms`.

The receiver accepts only the fixed iOS meter, metric names, units, histogram bounds and coarse resource attributes;
it rejects extra attributes/exemplars or cumulative histograms before storing anything. Metadata is app/OS version,
architecture, hardware model and maximum refresh rate, plus a random per-launch `service.instance.id`. No account,
persistent device/session identifier, process ID, raw uptime, chat content or paths are exported. Aggregates retain
90 days. Uploads happen periodically in the foreground and on backgrounding, no more than once per ten minutes,
subject to the sharing setting, power, thermal and network restrictions.

Legacy format (Android and iOS compatibility tests):

- **Content:** `vectors/perf-stats.json` pins the legacy JSON (`schema` `harness.mobile.stats.v1`): `os`,
  `arch`, app and OS version, the hardware model (never the name the owner gave it, capped at 40 characters), the
  refresh rate, the time window, and per metric a count, sum, max and the range counts. Metric names outside the list
  are dropped before sending, each sample is clamped to 0..60000 ms, and values are made to fit what the server
  accepts (the version is limited to letters, digits and `.+-`, and a window never reaches back more than six days),
  so one odd value cannot get every batch of a launch refused. The server's own validator is tested against these
  exact bodies.
- **Identity:** `install_id` is a random v4 UUID made fresh for every launch, so one launch's batches can be joined but
  never linked to a person or to the next launch. The desktop app keeps one per install instead, in its own file. No
  account, device or session identifier, and no chat content.
- **Metrics:** `app_launch_ms` and `conversation_load_ms` mean the same as on desktop. The rest are mobile's own:
  `transcript_rows_ms`, `markdown_parse_ms`, `home_group_ms`, `send_apply_ms`, `main_stall_ms`, and one frame measure:
  `frame_cost_ms` on Android (a frame's render cost) or `main_turn_ms` on iOS (a main run loop turn). Those two differ,
  so they are never compared with each other.
- **Rules:** an endpoint exists, sharing is on, the window has samples, at most one attempt per 10 minutes. Samples that
  could not go stay and merge into the next window; samples recorded while sharing is off are dropped and never sent
  later. Both apps test these against the same vectors.
- **Never uploaded:** debug builds, or while Battery Saver or Low Power Mode is on, or at a moderate or higher thermal
  state. Android also waits for an unmetered network; iOS refuses expensive and constrained networks.
- **Transport:** a JSON POST over https (loopback http for tests), with no cookies, credentials, cache or redirects.
- **Store listings and disclosure:** declare diagnostics (performance data, not linked to the user) in store privacy
  answers and the privacy policy. The iOS privacy manifest already declares Performance Data and the elapsed-time API
  reason; absolute system uptime is never exported.

The remaining legacy batch details above describe Android and the compatibility vectors. iOS uses the same bounded
aggregation/transport policy with its OTLP encoder; resource samples have their own units rather than milliseconds.

How the app treats the server's answer:

| Status | Meaning | The app |
| --- | --- | --- |
| 2xx | stored, or accepted and dropped by a cap | counts as sent |
| 429, other 4xx | rate limited, or for example a route not deployed yet | keeps the samples, starts the 10 minute wait |
| 400, 413, 415 | the batch is invalid, too large, or not JSON | drops it and stops sending for the rest of the launch |
| 5xx, no connection | server or network trouble | keeps the samples, no wait, tries again at the next chance |

## What it costs the device

The monitor must not be what slows the app or drains the phone. The historical measurements below concern the
existing Android monitor, except the explicitly named iOS debug recording threshold. They do not measure the added
iOS resource sampler or display link; physical-device CPU, write and battery overhead still needs a device baseline.

- **Per call:** recording an operation takes about 0.07 µs on Android and tallying a frame, including its range count, about 0.07 µs (a unit test
  fails above 5 µs; the iOS test fails above 25 µs in a debug build, to catch a hundredfold regression).
- **Frames:** the frame listener runs on its own thread and only while the app is in front. A scripted scroll on the
  emulator, three runs each with and without the monitor, showed no difference beyond run-to-run noise.
- **Idle:** on a still screen the monitor added at most about 0.6 ms of CPU per second (0.06% of one core), which is
  at the limit of what the 10 ms CPU clock can resolve. The stall timer checks every 100 ms only while frames are being
  drawn and about once a second when nothing is, and stops while the phone is hot or saving power.
- **Launch:** cold start was indistinguishable (about 180 ms both ways) when the emulator was quiet.
- **Logging:** an operation over budget logs at most one line a second.
- **Uploads:** built and sent off the main thread, at most one batch of a few kilobytes per 10 minutes. Nothing is built
  or sent while sharing is off, in a debug build, while Battery Saver or Low Power Mode is on, or at a moderate or higher
  thermal state. Android also waits for an unmetered network; iOS refuses expensive and constrained networks. Waking a
  mobile radio costs more battery than the batch is worth, so it is simply tried again at the next chance.
- **Startup:** the sharing setting is read on a background thread, so launch never waits on a preferences file for it.

Not measured: a physical device (all numbers are from the emulator and simulator), and battery drain over hours.
