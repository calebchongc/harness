import UIKit
import XCTest

/// The Select model sheet's top-right control (#407): an X while the selection
/// matches the one the sheet opened with, a checkmark in the selected row's
/// colors once it differs.
@MainActor
final class ModelConfirmationUITests: XCTestCase {
    private func row(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.scrollViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(label),")).firstMatch
    }

    func testConfirmationTracksTheOpeningModelAcrossThemes() throws {
        continueAfterFailure = false
        let themes = [
            ("harnesser-light", "light"),
            ("codegraff-dark", "dark"),
            ("tokyo-night", "dark"),
            ("gruvbox-light", "light"),
            ("synthwave-84", "dark"),
        ]
        for (theme, appearance) in themes {
            let app = XCUIApplication()
            app.launchArguments = ["-demo", "-route", "chat:chat-tabs", "-sheet", "config",
                                   "-phoneSplit", "off",
                                   "-theme.mode", appearance, "-theme.\(appearance)", theme,
                                   "-theme.followDesktop", "NO"]
            app.launch()

            let confirm = app.buttons["model-picker-confirm"]
            let initial = row(app, "GPT-5.6-Terra")
            let alternate = row(app, "GPT-5.6-Luna")
            XCTAssertTrue(initial.waitForExistence(timeout: 10), theme)
            XCTAssertEqual(confirm.label, "Close", theme)
            XCTAssertTrue(initial.isSelected, "VoiceOver reports the selected row: \(theme)")
            XCTAssertFalse(alternate.isSelected, theme)

            initial.tap()
            XCTAssertEqual(confirm.label, "Close", "Reselecting the opening model: \(theme)")
            alternate.tap()
            XCTAssertEqual(confirm.label, "Done", theme)
            XCTAssertTrue(confirm.isHittable)
            XCTAssertTrue(alternate.isSelected, theme)
            XCTAssertFalse(initial.isSelected, theme)

            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "model-confirmation-\(theme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            // Sample clear fill away from text, tick strokes, and rounded edges.
            // Native toolbar compositing can slightly alter the same semantic color.
            let circle = try pixel(screenshot.image, at: CGPoint(
                x: confirm.frame.minX + confirm.frame.width * 0.15, y: confirm.frame.midY))
            let fill = try pixel(screenshot.image, at: CGPoint(
                x: alternate.frame.maxX - 8, y: alternate.frame.midY))
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(circle[channel] - fill[channel]), 16,
                                         "Confirmation fill must match selected row: \(theme)")
            }

            initial.tap()
            XCTAssertEqual(confirm.label, "Close", "A → B → A restores X: \(theme)")
            alternate.tap()
            XCTAssertEqual(confirm.label, "Done", theme)
            confirm.tap()

            let composer = app.descendants(matching: .any)["composer-input"].firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            let chip = app.buttons["GPT-5.6-Luna"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "The pick is kept: \(theme)")
            chip.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            XCTAssertEqual(confirm.label, "Close", "Reopening resets the baseline: \(theme)")
            confirm.tap()
            app.terminate()
        }
    }

    /// A new session with no saved model opens the sheet while the host's
    /// catalog is still loading. The catalog arriving resolves a model, but
    /// that is not the user's change, so the X stays until a row is picked.
    func testHydrationIsNotASelectionChange() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-route", "space:space-harness", "-sheet", "newsession",
                               "-setnewsessionharness", "codex", "-setnewsessionmodel", "",
                               "-slow-catalog", "-phoneSplit", "off"]
        app.launch()
        let chip = app.buttons["Loading models…"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        let confirm = app.buttons["model-picker-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.label, "Close")

        let first = row(app, "GPT-6-Astra")
        XCTAssertTrue(first.waitForExistence(timeout: 40))
        XCTAssertEqual(confirm.label, "Close", "catalog hydration is not a user selection")

        let other = row(app, "GPT-5.6-Luna")
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        XCTAssertEqual(confirm.label, "Done")
        XCTAssertTrue(other.isSelected)
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let source = try XCTUnwrap(image.cgImage)
        let x = Int(point.x * image.scale)
        let y = Int(point.y * image.scale)
        let sample = try XCTUnwrap(source.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
                                             bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map(Int.init)
    }
}
