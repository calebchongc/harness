// Settings > Performance (PerformanceScreen.kt on Android). Shows what the on-device monitor has seen this
// run: startup, main-thread turns, each measured operation against its budget, memory and thermal state.
// Anonymous diagnostic sharing is on by default and can be turned off. "Copy report" copies local numbers for an issue.

import SwiftUI

struct PerformanceView: View {
    @AppStorage(PerfSharing.key) private var share = PerfSharing.enabled
    @State private var inspectionID = UUID()
    @State private var inspecting = false
    @Environment(\.scenePhase) private var scenePhase

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        // Re-read the counters once a second while the page is open.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let perf = Perf.shared
            let turns = perf.turns.snapshot()
            let stats = perf.recorder.stats()
            let resources = perf.resources.snapshot()
            let writes = perf.fileWrites.snapshot()
            List {
                Section("Startup") {
                    LabeledContent("First frame", value: perf.startupMs.map { "\($0) ms" } ?? "Not measured this run")
                }
                .harnessListRow()
                Section("Main thread") {
                    LabeledContent("Turns", value: "\(turns.turns)")
                    LabeledContent("Slow", value: "\(turns.slow) (\(String(format: "%.1f", turns.slowPercent))%)")
                    LabeledContent("Frozen", value: "\(turns.frozen)")
                    LabeledContent("Median · 95th", value: "\(String(format: "%.1f", turns.p50)) · \(String(format: "%.1f", turns.p95)) ms")
                    LabeledContent("Worst", value: "\(String(format: "%.0f", turns.worst)) ms")
                }
                .harnessListRow()
                Section("Operations") {
                    if stats.isEmpty {
                        Text("Nothing measured yet").foregroundStyle(.secondary)
                    }
                    ForEach(stats, id: \.name) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(stat.name)
                                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                                    .foregroundStyle(stat.overBudget > 0 ? Color.red : Color.primary)
                                Spacer()
                                Text("×\(stat.count)").foregroundStyle(.secondary)
                            }
                            Text(timings(stat)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .harnessListRow()
                Section {
                    LabeledContent("CPU · current", value: PerfFormat.percent(resources.cpuPercent))
                    LabeledContent("CPU · sampled peak", value: PerfFormat.percent(resources.peakCPUPercent))
                    LabeledContent("Memory footprint", value: PerfFormat.bytes(resources.footprintBytes))
                    LabeledContent("Memory · sampled peak", value: PerfFormat.bytes(resources.peakFootprintBytes))
                } header: {
                    Text("App resources")
                } footer: {
                    Text("100% CPU means one fully occupied core. Sampled once a second while this page is open or a visible transcript is scrolling or receiving a live reply. No background sampling.")
                }
                .harnessListRow()
                Section {
                    LabeledContent("Written since reset", value: PerfFormat.bytes(writes.bytes))
                    LabeledContent("Latest interval", value: PerfFormat.rate(writes.bytesPerSecond))
                    LabeledContent("Writes · failures", value: "\(writes.writes) · \(writes.failures)")
                    ForEach(PerfFileKind.allCases, id: \.rawValue) { kind in
                        LabeledContent(kind.rawValue, value: PerfFormat.bytes(writes.byKind[kind] ?? 0))
                    }
                } header: {
                    Text("Tracked file writes")
                } footer: {
                    Text("Successful logical payload bytes in snapshots, registry, model/harness caches and staged attachments. Not physical disk I/O or total process writes; excludes preferences and other caches.")
                }
                .harnessListRow()
                ForEach(PerfActivity.allCases, id: \.rawValue) { activity in
                    let cadence = perf.cadence.snapshot(activity)
                    Section {
                        LabeledContent("Average cadence", value: cadence.averageHz.map { String(format: "%.1f Hz", $0) } ?? "Not measured")
                        LabeledContent("95th interval", value: cadence.p95Ms.map { String(format: "%.1f ms", $0) } ?? "Not measured")
                        LabeledContent("Worst interval", value: cadence.worstMs.map { String(format: "%.1f ms", $0) } ?? "Not measured")
                        LabeledContent("Observed intervals", value: "\(cadence.intervals)")
                        LabeledContent("Estimated missed refreshes", value: "\(cadence.missedRefreshes)")
                    } header: {
                        Text(activity.rawValue)
                    } footer: {
                        Text("Display-link callback cadence, not GPU-rendered FPS. Missed refreshes are estimated from the display link's target interval; idle and background time are excluded.")
                    }
                    .harnessListRow()
                }
                Section("Device") {
                    LabeledContent("Thermal state", value: Perf.thermalLabel)
                    LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                }
                .harnessListRow()
                if PerfSharing.available {
                    Section {
                        Toggle("Share anonymous performance data", isOn: $share)
                            .accessibilityIdentifier("settings-share-performance")
                    } footer: {
                        Text("On by default. Sends diagnostic ranges for operation timings, CPU use, memory footprint, disk writes and scroll/stream callback delays. Callback delays are responsiveness proxies, not actual GPU hitches. Includes your device model, refresh rate and app and OS versions, with a random id that changes each launch. No chat content, account or persistent device identifiers. Diagnostics are retained for 90 days. Turn sharing off at any time.")
                    }
                    .harnessListRow()
                }
                Section {
                    Button("Copy report") { UIPasteboard.general.string = perf.report(version: version) }
                    Button("Reset", role: .destructive) { perf.reset() }
                } header: {
                    Text("Report")
                } footer: {
                    Text(PerfSharing.available
                         ? "These local resource summaries, tracked payload writes and cadence counters are not uploaded. Anonymous diagnostics use separate samples as described above. Operation columns are median, 95th and worst."
                         : "Measured on this device only and never sent anywhere. Operation columns are median, 95th and worst.")
                }
                .harnessListRow()
            }
            .harnessGroupedList()
        }
        .onChange(of: share) { _, _ in PerfSharing.consentChanged() }
        .onAppear {
            inspecting = true
            PerfLiveMonitor.shared.inspect(inspectionID, visible: scenePhase == .active)
        }
        .onDisappear {
            inspecting = false
            PerfLiveMonitor.shared.remove(inspectionID)
        }
        .onChange(of: scenePhase) { _, phase in
            PerfLiveMonitor.shared.inspect(inspectionID, visible: inspecting && phase == .active)
        }
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func timings(_ stat: SpanStat) -> String {
        let base = String(format: "%.1f / %.1f / %.1f ms", stat.p50, stat.p95, stat.max)
        guard let budget = PerfSpan.budgetsMs[stat.name] else { return base }
        return base + " · budget \(Int(budget)) ms"
    }
}
