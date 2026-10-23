import SwiftUI
import XCTest
@testable import Harness

final class BrandMarkTests: XCTestCase {
    func testGraffUsesItsOwnMarkInsteadOfClaude() {
        XCTAssertEqual(BrandMark.forHarness("graff"), .graff)
        XCTAssertNotEqual(BrandMark.forHarness("graff"), .claude)
        XCTAssertNil(BrandMark.brandTint(for: "graff"))
    }

    func testGraffRendersTheBracketsSlashAndInkDetails() {
        let mark = BrandMark.forHarness("graff")
        let path = BrandMarkShape(mark: mark).path(in: CGRect(x: 0, y: 0, width: 32, height: 32))

        XCTAssertEqual(mark.viewBox, CGSize(width: 32, height: 32))
        XCTAssertTrue(path.contains(CGPoint(x: 8.5, y: 16)), "Left code bracket must not disappear in a fill-only renderer")
        XCTAssertTrue(path.contains(CGPoint(x: 24.5, y: 16)), "Right code bracket")
        XCTAssertTrue(path.contains(CGPoint(x: 16.5, y: 16)), "Center slash")
        XCTAssertTrue(path.contains(CGPoint(x: 29, y: 17)), "Ink detail")
        XCTAssertFalse(path.contains(CGPoint(x: 0, y: 0)))
    }

    func testExistingHarnessMarksAreUnchanged() {
        let expected: [(String, BrandMark)] = [
            ("claude-code", .claude), ("mock", .claude), ("codex", .openai),
            ("cursor", .cursor), ("devin", .devin), ("grok", .grok),
            ("hermes", .hermes), ("pi", .pi), ("opencode", .opencode),
            ("antigravity", .antigravity),
        ]
        for (harness, mark) in expected {
            XCTAssertEqual(BrandMark.forHarness(harness), mark, harness)
        }
    }
}
