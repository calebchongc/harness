import XCTest

/// #420: the New space folder browser against a slow host (`-slow-folders`
/// makes every demo listing take 1.5 s).
@MainActor
final class FolderBrowserCacheUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sheet", "newspace", "-slow-folders", "-phoneSplit", "off"]
        app.launch()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Going back up shows the folder already visited at once, rather than
    /// waiting another host round trip with the old folder still on screen.
    func testGoingBackShowsTheVisitedFolderWithoutWaitingForTheHost() {
        let projects = app.buttons["folder-row-Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10))
        projects.tap()
        let harness = app.buttons["folder-row-harness"]
        XCTAssertTrue(harness.waitForExistence(timeout: 10))

        app.buttons["folder-up"].tap()
        Thread.sleep(forTimeInterval: 0.4)
        snapshot("back-0.4s")
        // Well inside the host's 1.5 s: the cached listing is already up.
        XCTAssertTrue(projects.exists, "the visited parent should show without a host round trip")
        XCTAssertFalse(harness.exists)
        XCTAssertFalse(app.descendants(matching: .any)["folder-loading"].firstMatch.exists)
    }

    /// Going back into a folder visited a moment ago is just as immediate.
    func testRevisitingAFolderShowsItsCachedListing() {
        let projects = app.buttons["folder-row-Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10))
        projects.tap()
        XCTAssertTrue(app.buttons["folder-row-harness"].waitForExistence(timeout: 10))
        app.buttons["folder-up"].tap()
        XCTAssertTrue(projects.waitForExistence(timeout: 10))

        projects.tap()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(app.buttons["folder-row-harness"].exists)
    }
}
