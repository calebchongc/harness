import XCTest
@testable import Harness

final class PerfFramesTests: XCTestCase {
    func testFirstCallbackOnlyEstablishesBaseline() {
        var delay = PerfFrameDelay()
        XCTAssertNil(delay.sample(timestamp: 1, targetTimestamp: 1.01, callbackTime: 1.001))
        XCTAssertEqual(delay.sample(timestamp: 1.01, targetTimestamp: 1.02, callbackTime: 1.011)!,
                       0, accuracy: 0.000001)
    }

    func testUsesCurrentVariableRefreshIntervalRatherThanSixtyHz() {
        var delay = PerfFrameDelay()
        var time = 10.0
        XCTAssertNil(delay.sample(timestamp: time, targetTimestamp: time + 1 / 120.0, callbackTime: time))
        // The advertised current interval, not the preceding interval or a fixed 60 Hz budget, wins.
        for interval in [1 / 120.0, 1 / 60.0, 1 / 30.0, 1 / 80.0, 1 / 120.0] {
            time += interval
            let ms = delay.sample(timestamp: time, targetTimestamp: time + interval, callbackTime: time)
            XCTAssertNotNil(ms)
            XCTAssertEqual(ms!, 0, accuracy: 0.000001)
        }
    }

    func testSkippedCallbacksEstimateExcessArrivalTime() {
        var delay = PerfFrameDelay()
        let interval = 1 / 120.0
        XCTAssertNil(delay.sample(timestamp: 1, targetTimestamp: 1 + interval, callbackTime: 1))
        let next = 1 + 4 * interval
        let ms = delay.sample(timestamp: next, targetTimestamp: next + interval, callbackTime: next)
        XCTAssertEqual(ms!, 3 * interval * 1000, accuracy: 0.000001)
    }

    func testCallbackSchedulingDelayIsNotPresentedAsRenderCost() {
        var delay = PerfFrameDelay()
        XCTAssertNil(delay.sample(timestamp: 1, targetTimestamp: 1.01, callbackTime: 1))
        let ms = delay.sample(timestamp: 1.01, targetTimestamp: 1.02, callbackTime: 1.016)
        XCTAssertEqual(ms!, 6, accuracy: 0.000001)
        // A shorter following arrival gap cannot produce a negative histogram sample.
        XCTAssertEqual(delay.sample(timestamp: 1.02, targetTimestamp: 1.03, callbackTime: 1.02)!, 0)
    }

    func testPauseOrBackgroundClearsBaselineBeforeResume() {
        var delay = PerfFrameDelay()
        XCTAssertNil(delay.sample(timestamp: 1, targetTimestamp: 1.01, callbackTime: 1))
        for resumedAt in [100.0, 50_000.0] {
            // Both idle/hidden pauses and lifecycle/background stops call reset().
            delay.reset()
            XCTAssertNil(delay.sample(timestamp: resumedAt, targetTimestamp: resumedAt + 0.01,
                                      callbackTime: resumedAt))
            XCTAssertEqual(delay.sample(timestamp: resumedAt + 0.01, targetTimestamp: resumedAt + 0.02,
                                        callbackTime: resumedAt + 0.01)!, 0, accuracy: 0.000001)
        }
    }

    func testInvalidTimestampsDropSampleAndClearBaseline() {
        let invalid: [(Double, Double, Double)] = [
            (.nan, 2, 1), (.infinity, 2, 1), (-1, 0, 0),
            (1, .nan, 1), (1, .infinity, 1), (1, 1, 1), (1, 0.9, 1),
            (1, 1.01, .nan), (1, 1.01, .infinity), (1, 1.01, -1), (1, 1.01, 0.9),
        ]
        for (timestamp, target, callback) in invalid {
            var delay = PerfFrameDelay()
            XCTAssertNil(delay.sample(timestamp: 0, targetTimestamp: 0.01, callbackTime: 0))
            XCTAssertNil(delay.sample(timestamp: timestamp, targetTimestamp: target, callbackTime: callback))
            XCTAssertNil(delay.sample(timestamp: 2, targetTimestamp: 2.01, callbackTime: 2),
                         "An invalid sample must not leave an old baseline")
        }
    }

    func testNonMonotonicDisplayAndCallbackClocksResetBaseline() {
        for (timestamp, callback) in [(1.0, 1.02), (0.9, 1.02), (1.01, 1.01), (1.005, 1.005)] {
            var delay = PerfFrameDelay()
            XCTAssertNil(delay.sample(timestamp: 1, targetTimestamp: 1.02, callbackTime: 1.01))
            XCTAssertNil(delay.sample(timestamp: timestamp, targetTimestamp: timestamp + 0.02,
                                      callbackTime: callback))
            XCTAssertNil(delay.sample(timestamp: 2, targetTimestamp: 2.02, callbackTime: 2))
        }
    }

    func testActivityRequiresExplicitConsentReleaseVisibleForegroundAndWork() {
        func activity(consent: Bool = true, debug: Bool = false, visible: Bool = true,
                      foreground: Bool = true, scrolling: Bool = true, streaming: Bool = true) -> PerfFrameActivity? {
            PerfFrameActivity.select(sharingEnabled: consent, debugBuild: debug, visible: visible,
                                     foreground: foreground, scrolling: scrolling, streaming: streaming)
        }
        XCTAssertNil(activity(consent: false))
        XCTAssertNil(activity(debug: true))
        XCTAssertNil(activity(visible: false))
        XCTAssertNil(activity(foreground: false))
        XCTAssertNil(activity(scrolling: false, streaming: false))
        XCTAssertEqual(activity(), .scroll, "Scrolling wins when streaming at the same time")
        XCTAssertEqual(activity(streaming: false), .scroll)
        XCTAssertEqual(activity(scrolling: false), .stream)
        XCTAssertEqual(PerfFrameActivity.scroll.rawValue, "scroll_callback_delay_ms")
        XCTAssertEqual(PerfFrameActivity.stream.rawValue, "stream_callback_delay_ms")
    }
}
