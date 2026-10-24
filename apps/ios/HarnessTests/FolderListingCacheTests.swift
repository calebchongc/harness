import XCTest
@testable import Harness

/// #420: recently loaded folders come from the cache, refresh in the
/// background, and a reply for a folder already left never takes the screen.
final class FolderListingCacheTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func listing(_ path: String, _ names: [String] = []) -> FolderListing {
        FolderListing(path: path,
                      entries: names.map { FolderEntry(name: $0, isDir: true, isRepo: false) },
                      truncated: false)
    }

    private func browser(cache: FolderListingCache = FolderListingCache()) -> FolderBrowserState {
        var state = FolderBrowserState(cache: cache, now: { [unowned self] in self.clock })
        state.selectDevice("host-a")
        return state
    }

    @discardableResult
    private func reply(_ request: FolderBrowserState.Request?, _ listing: FolderListing?,
                       host: String = "host-a", to state: inout FolderBrowserState) -> Bool {
        guard let request else { XCTFail("expected a request"); return false }
        return state.finish(request, listing: listing, currentDeviceId: host,
                            failureMessage: "Folder unavailable")
    }

    private func shownPath(_ state: FolderBrowserState) -> String? {
        state.selection(for: "host-a")?.listing.path
    }

    /// Home, then a child: both are cached once loaded.
    private func visitedHomeAndChild() -> FolderBrowserState {
        var state = browser()
        reply(state.begin(path: nil), listing("/home", ["a", "b"]), to: &state)
        reply(state.begin(path: "/home/a"), listing("/home/a", ["deep"]), to: &state)
        return state
    }

    // MARK: Showing cached listings

    func testGoingBackToAFreshFolderShowsItWithoutAskingTheHost() {
        var state = visitedHomeAndChild()
        XCTAssertNil(state.begin(path: "/home"))
        XCTAssertEqual(shownPath(state), "/home")
        XCTAssertEqual(state.selection(for: "host-a")?.listing.entries.map(\.name), ["a", "b"])
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.creationTarget(for: "host-a")?.listing.path, "/home")
    }

    func testOlderListingShowsAtOnceAndRefreshesInTheBackground() {
        var state = visitedHomeAndChild()
        clock += 60
        let refresh = state.begin(path: "/home")
        XCTAssertEqual(refresh?.revalidating, true)
        // On screen straight away, usable, and no spinner.
        XCTAssertEqual(shownPath(state), "/home")
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.isRefreshing)
        XCTAssertNotNil(state.creationTarget(for: "host-a"))
        // The refresh replaces it with what the host has now.
        XCTAssertTrue(reply(refresh, listing("/home", ["a", "b", "new"]), to: &state))
        XCTAssertEqual(state.selection(for: "host-a")?.listing.entries.map(\.name), ["a", "b", "new"])
        XCTAssertFalse(state.isRefreshing)
    }

    func testExpiredListingLoadsCold() {
        var state = visitedHomeAndChild()
        clock += 11 * 60
        let request = state.begin(path: "/home")
        XCTAssertEqual(request?.revalidating, false)
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.creationTarget(for: "host-a"))
        XCTAssertEqual(shownPath(state), "/home/a", "the last folder stays until the host answers")
    }

    func testHomeIsFoundUnderTheFolderTheHostReported() {
        var state = visitedHomeAndChild()
        // Reopening the sheet (or returning to this host) asks for home again.
        state.selectDevice("host-b")
        state.selectDevice("host-a")
        XCTAssertNil(state.begin(path: nil))
        XCTAssertEqual(shownPath(state), "/home")
        // A trailing slash names the same folder.
        XCTAssertNil(state.begin(path: "/home/a/"))
        XCTAssertEqual(shownPath(state), "/home/a")
    }

    func testCacheIsPerHost() {
        let cache = FolderListingCache()
        var a = browser(cache: cache)
        reply(a.begin(path: "/home"), listing("/home"), to: &a)
        var b = FolderBrowserState(cache: cache, now: { [unowned self] in self.clock })
        b.selectDevice("host-b")
        XCTAssertEqual(b.begin(path: "/home")?.revalidating, false)
        XCTAssertTrue(b.isLoading)
    }

    func testRefreshAsksTheHostEvenForAFreshListing() {
        var state = visitedHomeAndChild()
        let request = state.begin(path: "/home/a", refresh: true)
        XCTAssertEqual(request?.revalidating, true)
        XCTAssertEqual(shownPath(state), "/home/a")
    }

    func testCacheSurvivesTheSheetThroughTheSharedInstance() {
        let cache = FolderListingCache()
        var first = browser(cache: cache)
        reply(first.begin(path: nil), listing("/home"), to: &first)
        var reopened = browser(cache: cache)
        XCTAssertNil(reopened.begin(path: nil))
        XCTAssertEqual(reopened.selection(for: "host-a")?.listing.path, "/home")
    }

    // MARK: Failures

    func testFailedRefreshKeepsTheListingShowsTheErrorAndStopsServingIt() {
        var state = visitedHomeAndChild()
        clock += 60
        let refresh = state.begin(path: "/home")
        XCTAssertTrue(reply(refresh, nil, to: &state))
        XCTAssertEqual(state.error, "Folder unavailable")
        XCTAssertEqual(shownPath(state), "/home")
        XCTAssertFalse(state.isRefreshing)
        // The next visit asks the host instead of trusting it.
        XCTAssertEqual(state.begin(path: "/home")?.revalidating, false)
    }

    func testFailedColdLoadShowsTheErrorOverThePreviousFolder() {
        var state = visitedHomeAndChild()
        XCTAssertTrue(reply(state.begin(path: "/home/a/locked"), nil, to: &state))
        XCTAssertEqual(state.error, "Folder unavailable")
        XCTAssertEqual(shownPath(state), "/home/a")
        XCTAssertNotNil(state.creationTarget(for: "host-a"))
    }

    // MARK: Out-of-order replies

    func testRefreshReplyForAFolderAlreadyLeftDoesNotTakeTheScreen() {
        var state = visitedHomeAndChild()
        clock += 60
        let homeRefresh = state.begin(path: "/home")
        // Tap back into a child before the refresh lands.
        let child = state.begin(path: "/home/b")
        XCTAssertFalse(reply(homeRefresh, listing("/home", ["a", "b", "late"]), to: &state))
        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(reply(child, listing("/home/b"), to: &state))
        XCTAssertEqual(shownPath(state), "/home/b")
    }

    func testFreshHitSupersedesTheRequestInFlight() {
        var state = visitedHomeAndChild()
        let cold = state.begin(path: "/home/b")
        XCTAssertTrue(state.isLoading)
        // Back up to home, which is fresh: no request, and the cold one is moot.
        XCTAssertNil(state.begin(path: "/home"))
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(reply(cold, listing("/home/b"), to: &state))
        XCTAssertEqual(shownPath(state), "/home")
    }

    func testSupersededReplyIsKeptForTheNextVisitButNotShown() {
        var state = visitedHomeAndChild()
        let left = state.begin(path: "/home/b")
        XCTAssertNil(state.begin(path: "/home"))
        XCTAssertFalse(reply(left, listing("/home/b", ["x"]), to: &state))
        XCTAssertEqual(shownPath(state), "/home")
        XCTAssertNil(state.begin(path: "/home/b"), "the late reply serves the next visit")
        XCTAssertEqual(state.selection(for: "host-a")?.listing.entries.map(\.name), ["x"])
    }

    func testReplyFromAnotherHostIsCachedForThatHostOnly() {
        let cache = FolderListingCache()
        var state = browser(cache: cache)
        let a = state.begin(path: "/shared")
        state.selectDevice("host-b")
        XCTAssertFalse(reply(a, listing("/shared", ["from-a"]), host: "host-b", to: &state))
        XCTAssertNil(state.selection(for: "host-b"))
        XCTAssertEqual(state.begin(path: "/shared")?.revalidating, false)
        if case .fresh(let cached) = cache.lookup(deviceId: "host-a", path: "/shared", now: clock) {
            XCTAssertEqual(cached.entries.map(\.name), ["from-a"])
        } else {
            XCTFail("host-a's reply belongs in host-a's cache")
        }
    }

    // MARK: The cache itself

    func testCapacityDropsTheOldestListingFirst() {
        let cache = FolderListingCache(capacity: 3)
        for i in 0..<4 {
            cache.store(listing("/f\(i)"), deviceId: "host-a", requestedPath: "/f\(i)", now: clock + Double(i))
        }
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.lookup(deviceId: "host-a", path: "/f0", now: clock + 4), .miss)
        XCTAssertNotEqual(cache.lookup(deviceId: "host-a", path: "/f3", now: clock + 4), .miss)
    }

    func testRemoveAllForgetsListingsAndHomes() {
        let cache = FolderListingCache()
        cache.store(listing("/home"), deviceId: "host-a", requestedPath: nil, now: clock)
        cache.removeAll()
        XCTAssertEqual(cache.lookup(deviceId: "host-a", path: nil, now: clock), .miss)
        XCTAssertEqual(cache.lookup(deviceId: "host-a", path: "/home", now: clock), .miss)
    }

    /// Shape of the fix: browsing down and back up repeatedly asks the host
    /// for each folder once, where it used to ask on every step.
    func testBrowsingBackAndForthAsksTheHostOncePerFolder() {
        func hostRequests(_ cache: FolderListingCache) -> Int {
            var state = browser(cache: cache)
            var sent = 0
            for path in [nil, "/home/a", "/home", "/home/a", "/home", "/home/a", "/home"] as [String?] {
                if let request = state.begin(path: path) {
                    sent += 1
                    reply(request, listing(path ?? "/home"), to: &state)
                }
                clock += 1
            }
            return sent
        }
        let uncached = hostRequests(FolderListingCache(freshFor: 0, keepFor: 0))
        let cached = hostRequests(FolderListingCache())
        XCTAssertEqual(uncached, 7)
        XCTAssertEqual(cached, 2)
        XCTAssertGreaterThanOrEqual(uncached / cached, 3)
    }
}
