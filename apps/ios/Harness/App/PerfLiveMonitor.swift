// Demand-driven monitoring: no periodic sampling on quiet screens or in the background.
// These local summaries never enter PerfHistograms, PerfUpload, or the separate OTLP sampler.
import UIKit

@MainActor
final class PerfLiveMonitor: NSObject {
    static let shared = PerfLiveMonitor()

    @MainActor
    private struct Interest {
        var inspection = false
        var scrolling = false
        var streaming = false
        weak var view: UIView?
        var tracksView = false

        var visible: Bool {
            guard tracksView else { return true }
            guard let view, let window = view.window,
                  window.windowScene?.activationState == .foregroundActive,
                  view.convert(view.bounds, to: window).intersects(window.bounds) else { return false }
            var ancestor: UIView? = view
            while let current = ancestor {
                if current.isHidden || current.alpha <= 0 { return false }
                ancestor = current.superview
            }
            return true
        }
    }
    private var interests: [UUID: Interest] = [:]
    private var backgrounded: Bool
    private var sampler: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var lifecycle: [NSObjectProtocol] = []
    var isSampling: Bool { sampler != nil }
    var isMeasuringCadence: Bool { displayLink != nil }

    override init() {
        backgrounded = UIApplication.shared.applicationState != .active
        super.init()
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification] {
            lifecycle.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.setBackgrounded(note.name != UIApplication.didBecomeActiveNotification)
                }
            })
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.didActivateNotification] {
            lifecycle.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit {
        sampler?.cancel()
        displayLink?.invalidate()
        for token in lifecycle { NotificationCenter.default.removeObserver(token) }
    }

    func inspect(_ id: UUID, visible: Bool) {
        interests[id] = visible ? Interest(inspection: true) : nil
        refresh()
    }

    func transcript(_ id: UUID, visible: Bool, scrolling: Bool, streaming: Bool, view: UIView? = nil) {
        interests[id] = visible && (scrolling || streaming)
            ? Interest(scrolling: scrolling, streaming: streaming, view: view, tracksView: view != nil) : nil
        refresh()
    }

    func remove(_ id: UUID) {
        interests.removeValue(forKey: id)
        refresh()
    }

    func setBackgrounded(_ value: Bool) {
        backgrounded = value
        refresh()
    }

    private func refresh() {
        let visible = backgrounded ? [] : interests.values.filter { $0.visible }
        let scrolling = visible.contains { $0.scrolling }
        let streaming = visible.contains { $0.streaming }
        Perf.shared.cadence.setActive(.scrolling, scrolling)
        Perf.shared.cadence.setActive(.streaming, streaming)
        let needed = !visible.isEmpty
        if needed, sampler == nil {
            Perf.shared.resources.pause()
            Perf.shared.fileWrites.pause()
            sampler = Task { [weak self] in
                while !Task.isCancelled {
                    // Recheck hidden/detached views before reading process counters too.
                    self?.refresh()
                    guard self != nil, !Task.isCancelled else { return }
                    let sample = ProcessResourceSample.read()
                    Perf.shared.resources.sample(sample)
                    Perf.shared.fileWrites.sampleRate(at: sample.uptime)
                    do { try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100)) }
                    catch { return }
                }
            }
        } else if !needed {
            sampler?.cancel()
            sampler = nil
            Perf.shared.resources.pause()
            Perf.shared.fileWrites.pause()
        }
        if scrolling || streaming {
            if displayLink == nil {
                let link = CADisplayLink(target: WeakTarget(owner: self), selector: #selector(WeakTarget.frame(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        refresh()
        guard displayLink === link else { return }
        Perf.shared.cadence.record(timestamp: link.timestamp,
                                   expectedInterval: link.targetTimestamp - link.timestamp)
    }

    @MainActor
    private final class WeakTarget: NSObject {
        weak var owner: PerfLiveMonitor?
        init(owner: PerfLiveMonitor) { self.owner = owner }

        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.frame(link)
        }
    }
}
