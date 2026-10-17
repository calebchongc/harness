import QuartzCore
import UIKit

/// Callback cadence only: this does not observe rendered frames, compositor hitches, or FPS.
/// The current display-link interval follows variable refresh rates, rather than assuming 60 Hz.
struct PerfFrameDelay {
    private var previous: (timestamp: Double, callbackTime: Double)?

    mutating func reset() {
        previous = nil
    }

    /// Excess time between callback arrivals, including an estimate of skipped callback time.
    /// Callback scheduling jitter and refresh-rate transitions can affect this proxy too.
    mutating func sample(timestamp: Double, targetTimestamp: Double, callbackTime: Double) -> Double? {
        let expected = targetTimestamp - timestamp
        guard timestamp.isFinite, timestamp >= 0,
              targetTimestamp.isFinite, expected.isFinite, expected > 0,
              callbackTime.isFinite, callbackTime >= timestamp else {
            reset()
            return nil
        }
        guard let previous else {
            self.previous = (timestamp, callbackTime)
            return nil
        }
        let elapsed = callbackTime - previous.callbackTime
        guard timestamp > previous.timestamp, elapsed.isFinite, elapsed > 0 else {
            reset()
            return nil
        }
        let delay = max(0, elapsed - expected) * 1000
        guard delay.isFinite else {
            reset()
            return nil
        }
        self.previous = (timestamp, callbackTime)
        return delay
    }
}

enum PerfFrameActivity: String {
    case scroll = "scroll_callback_delay_ms"
    case stream = "stream_callback_delay_ms"

    static func select(sharingEnabled: Bool, debugBuild: Bool, visible: Bool, foreground: Bool,
                       scrolling: Bool, streaming: Bool) -> Self? {
        guard sharingEnabled, !debugBuild, visible, foreground else { return nil }
        if scrolling { return .scroll }
        return streaming ? .stream : nil
    }
}

/// Owned by a transcript table; all UIKit and display-link work stays on the main actor.
/// An idle/hidden/backgrounded table has no scheduled display link and retains no timing baseline.
@MainActor
final class PerfFrames: NSObject {
    private weak var scrollView: UIScrollView?
    private var streaming = false
    private var lifecycleActive = true
    private var activity: PerfFrameActivity?
    private var delay = PerfFrameDelay()
    private var displayLink: CADisplayLink?

    init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init()
        #if !DEBUG
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification] {
            center.addObserver(self, selector: #selector(lifecycleChanged(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(preferencesChanged),
                           name: UserDefaults.didChangeNotification, object: nil)
        #endif
    }

    func setStreaming(_ streaming: Bool) {
        self.streaming = streaming
        refresh()
    }

    func didMoveToWindow() {
        lifecycleActive = isForeground
        refresh()
    }

    /// Called on native scroll-state transitions, as well as before recording each callback.
    func refresh() {
        #if DEBUG
        stop()
        #else
        // Bail out before inspecting the view hierarchy when sharing is off or the transcript is idle.
        guard PerfSharing.collectingEnabled else { stop(); return }
        let scrolling = scrollView.map { $0.isDragging || $0.isDecelerating } ?? false
        guard scrolling || streaming else { stop(); return }
        let next = PerfFrameActivity.select(
            sharingEnabled: true, debugBuild: false,
            visible: isVisible, foreground: lifecycleActive && isForeground,
            scrolling: scrolling, streaming: streaming
        )
        guard let next else { stop(); return }
        if activity != next { delay.reset() }
        activity = next
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: WeakTarget(owner: self), selector: #selector(WeakTarget.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
        #endif
    }

    private var isForeground: Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        guard let scene = scrollView?.window?.windowScene else { return true }
        return scene.activationState == .foregroundActive
    }

    private var isVisible: Bool {
        guard let scrollView, scrollView.window != nil else { return false }
        var view: UIView? = scrollView
        while let current = view {
            if current.isHidden || current.alpha <= 0 { return false }
            view = current.superview
        }
        return true
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        activity = nil
        delay.reset()
    }

    @objc private func lifecycleChanged(_ notification: Notification) {
        // Scene notifications must not stop a different window's transcript.
        if let scene = notification.object as? UIScene, scene !== scrollView?.window?.windowScene { return }
        lifecycleActive = notification.name == UIApplication.didBecomeActiveNotification
            || notification.name == UIScene.didActivateNotification
        refresh()
    }

    // Defaults notifications can originate off-main. UIKit lifecycle notifications above arrive on main.
    @objc nonisolated private func preferencesChanged() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.refresh() }
        } else {
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // Recheck actual drag/deceleration, visibility, and consent: UIKit can end momentum silently.
        refresh()
        guard displayLink === link, let activity,
              let ms = delay.sample(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp,
                                    callbackTime: now) else { return }
        Perf.shared.histograms.add(activity.rawValue, ms: ms)
    }

    @MainActor
    private final class WeakTarget: NSObject {
        weak var owner: PerfFrames?

        init(owner: PerfFrames) { self.owner = owner }

        @objc func tick(_ link: CADisplayLink) {
            // The run loop retains the link and its target, never the table or monitor.
            // If the owner disappears without a detach callback, retire this link on its next tick.
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
}
