import XCTest
@testable import Harness

@MainActor
final class SessionStatusWindowTests: XCTestCase {
    func testEmptyAndSingleSessionHaveNoOverflow() {
        let empty = SessionStatusWindow(ids: [], current: "missing", limit: 3)
        XCTAssertTrue(empty.visibleIDs.isEmpty)
        XCTAssertNil(empty.overflowText)
        let single = SessionStatusWindow(ids: ["open"], current: "open", limit: 3)
        XCTAssertEqual(single.visibleIDs, ["open"])
        XCTAssertEqual(single.hiddenCount, 0)
        XCTAssertNil(single.overflowText)
    }

    func testOneHiddenSessionUsesWordsNotAnAddAffordance() {
        let window = SessionStatusWindow(ids: ["a", "b", "c", "d"], current: "a", limit: 3)
        XCTAssertEqual(window.visibleIDs, ["a", "b", "c"])
        XCTAssertEqual(window.overflowText, "1 more")
    }

    func testCurrentStaysVisibleAtEveryPositionAndCountsNeverLoseSessions() {
        for total in [1, 2, 6, 10, 11, 12, 32] {
            let ids = (0..<total).map { "session-\($0)" }
            for current in ids {
                for limit in 1...8 {
                    let window = SessionStatusWindow(ids: ids, current: current, limit: limit)
                    XCTAssertTrue(window.visibleIDs.contains(current))
                    XCTAssertEqual(window.visibleIDs.filter { $0 == current }.count, 1)
                    XCTAssertEqual(window.visibleIDs.count + window.hiddenCount, total)
                    XCTAssertEqual(window.visibleIDs, ids.filter(window.visibleIDs.contains))
                    XCTAssertLessThanOrEqual(window.visibleIDs.count, limit)
                }
            }
        }
    }

    func testZeroNegativeAndOversizedLimitsAreSafe() {
        let ids = ["a", "b", "c"]
        for limit in [0, -1] {
            let window = SessionStatusWindow(ids: ids, current: "c", limit: limit)
            XCTAssertTrue(window.visibleIDs.isEmpty)
            XCTAssertEqual(window.hiddenCount, 3)
        }
        XCTAssertEqual(SessionStatusWindow(ids: ids, current: "missing", limit: 99).visibleIDs, ids)
    }

    func testLayoutUsesActualNavigationAndAvailableWidth() {
        for width: CGFloat in [180, 220, 280, 320, 390, 600] {
            for total in [0, 1, 4, 7, 12] {
                let withPager = SessionStatusWindow.visibleLimit(availableWidth: width, total: total, hasPager: true)
                let withoutPager = SessionStatusWindow.visibleLimit(availableWidth: width, total: total, hasPager: false)
                XCTAssertGreaterThanOrEqual(withoutPager, withPager)
                XCTAssertLessThanOrEqual(withoutPager, min(6, total))
                XCTAssertGreaterThanOrEqual(withPager, total > 0 ? 1 : 0)
            }
        }
        XCTAssertGreaterThan(SessionStatusWindow.visibleLimit(availableWidth: 280, total: 7, hasPager: false),
                             SessionStatusWindow.visibleLimit(availableWidth: 280, total: 7, hasPager: true))
    }

    func testTwoDigitCounterReservesMoreRoomForTheTitle() {
        XCTAssertGreaterThan(SessionStatusWindow.visibleLimit(availableWidth: 302, total: 9, hasPager: true),
                             SessionStatusWindow.visibleLimit(availableWidth: 302, total: 12, hasPager: true))
    }

    func testPagerAndOverflowIncludeEveryEligibleSessionBeyondTen() {
        let model = makeModel(count: 12)
        XCTAssertEqual(JuggledSessions(model: model).chats.count, 10, "Home remains bounded")
        let entries = SessionPaging.entries(model: model, including: "chat-11")
        let set = SessionPaging.pageSet(of: "chat-11", in: entries)
        XCTAssertEqual(set.count, 12)
        XCTAssertEqual(SessionPaging.position(of: "chat-11", in: entries)?.count, 12)
        XCTAssertEqual(SessionPaging.neighbors(of: "chat-11", in: entries).previous, "chat-10")
        let window = SessionStatusWindow(ids: set.map(\.id), current: "chat-11", limit: 3)
        XCTAssertTrue(window.visibleIDs.contains("chat-11"))
        XCTAssertEqual(window.overflowText, "9 more")
    }

    func testOldIdleCurrentRemainsPageableAcrossRecentCutoff() {
        let model = makeModel(count: 3)
        for age in [JuggledSessions.recentWindowMs - 1, JuggledSessions.recentWindowMs + 1] {
            model.demo!.chats[2].lastPromptAt = nowMs() - age
            model.demo!.sessions["chat-2"] = nil
            model.demo!.chats[2].lastSeenAt = nowMs()
            let entries = SessionPaging.entries(model: model, including: "chat-2")
            XCTAssertTrue(entries.contains { $0.id == "chat-2" })
            XCTAssertEqual(SessionPaging.position(of: "chat-2", in: entries)?.count, 3)
            XCTAssertNotNil(SessionPaging.neighbors(of: "chat-2", in: entries).previous)
        }
    }

    func testReadingReplyKeepsCounterMarksAndDestinationsConsistent() {
        let model = makeModel(count: 3)
        model.demo!.sessions["chat-1"] = nil
        let before = SessionPaging.entries(model: model, including: "chat-0")
        XCTAssertEqual(SessionPaging.pageSet(of: "chat-0", in: before).count, 3)
        model.markSeen(chatId: "chat-1")
        let after = SessionPaging.entries(model: model, including: "chat-0")
        let set = SessionPaging.pageSet(of: "chat-0", in: after)
        XCTAssertEqual(set.map(\.id), ["chat-0", "chat-2"])
        XCTAssertEqual(SessionPaging.position(of: "chat-0", in: after)?.count, set.count)
        XCTAssertEqual(SessionPaging.neighbors(of: "chat-0", in: after).next, "chat-2")
        XCTAssertEqual(SessionStatusWindow(ids: set.map(\.id), current: "chat-0", limit: 1).hiddenCount, 1)
    }

    private func makeModel(count: Int) -> AppModel {
        let now = nowMs()
        let chats = (0..<count).map { index in
            Chat(id: "chat-\(index)", deviceId: "host", title: "Session \(index)", archived: false,
                 lastMessageAt: now - Int64(index * 1_000), createdAt: now - 100_000,
                 lastSeenAt: now - 200_000, lastPromptAt: now - Int64(index * 1_000))
        }
        let sessions = Dictionary(uniqueKeysWithValues: chats.map {
            ($0.id, SessionRow(chatId: $0.id, deviceId: "host", status: .working,
                              startedAt: now, updatedAt: now))
        })
        let model = AppModel()
        model.demo = DemoDataset(devices: [], spaces: [], chats: chats, sessions: sessions)
        return model
    }
}
