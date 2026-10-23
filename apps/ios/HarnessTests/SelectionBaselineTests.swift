import XCTest
@testable import Harness

final class SelectionBaselineTests: XCTestCase {
    private let catalogs: [String: [ModelInfo]] = [
        "codex": [
            ModelInfo(id: "terra", label: "Terra", description: nil, reasoningLevels: []),
            ModelInfo(id: "luna", label: "Luna", description: nil, reasoningLevels: []),
        ],
        "claude-code": [
            ModelInfo(id: "claude-fable-5-1", label: "Fable 5.1", description: nil, reasoningLevels: []),
        ],
    ]

    private func changed(_ baseline: SelectionBaseline<ModelSelection>, _ current: ModelSelection,
                         catalogs: [String: [ModelInfo]]? = nil) -> Bool {
        baseline.changed(to: current) { HarnessCatalog.sameRow($0, $1, catalogs: catalogs ?? self.catalogs) }
    }

    func testChangedComparesTheCurrentSelectionWithTheOpeningOne() {
        let a = ModelSelection(harness: "codex", modelId: "terra")
        let b = ModelSelection(harness: "codex", modelId: "luna")
        var baseline = SelectionBaseline(a)
        XCTAssertFalse(changed(baseline, a), "opening with A shows the X")

        baseline.picked()
        XCTAssertFalse(changed(baseline, a), "reselecting A keeps the X")
        XCTAssertTrue(changed(baseline, b), "selecting B shows the checkmark")
        XCTAssertFalse(changed(baseline, a), "A → B → A returns to the X")
    }

    func testAnotherAgentIsAChangeEvenWithTheSameModelId() {
        let baseline = SelectionBaseline(ModelSelection(harness: "codex", modelId: "terra"))
        XCTAssertTrue(changed(baseline, ModelSelection(harness: "claude-code", modelId: "terra")))
        XCTAssertTrue(changed(baseline, ModelSelection(harness: "claude-code", modelId: "claude-fable-5-1")))
    }

    func testHydrationMovesTheBaselineUntilTheUserPicks() {
        // A new session with no saved model opens while the catalog loads; the
        // catalog then resolves the first row. That is not the user's change.
        var baseline = SelectionBaseline(ModelSelection(harness: "codex", modelId: ""))
        let resolved = ModelSelection(harness: "codex", modelId: "terra")
        baseline.hydrated(to: resolved)
        XCTAssertFalse(changed(baseline, resolved))

        baseline.picked()
        let luna = ModelSelection(harness: "codex", modelId: "luna")
        baseline.hydrated(to: luna)
        XCTAssertTrue(changed(baseline, luna), "a pick's own update must not reset the baseline")
        XCTAssertEqual(baseline.opening, resolved)
    }

    func testLegacyLongContextAliasAndItsBaseAreOneRow() {
        let alias = ModelSelection(harness: "claude-code", modelId: "claude-fable-5-1[1m]")
        let base = ModelSelection(harness: "claude-code", modelId: "claude-fable-5-1")
        let baseline = SelectionBaseline(alias)
        XCTAssertFalse(changed(baseline, base), "tapping the highlighted row is not a change")
        XCTAssertTrue(changed(baseline, base, catalogs: [:]),
                      "without metadata only the wire identity can be compared")
    }

    func testUnresolvedSavedSelectionComparesByWireIdentity() {
        // Saved before metadata loads, or absent from the live catalog.
        let saved = ModelSelection(harness: "codex", modelId: "saved-live-only")
        let baseline = SelectionBaseline(saved)
        XCTAssertFalse(changed(baseline, saved))
        XCTAssertFalse(changed(baseline, saved, catalogs: [:]))
        XCTAssertTrue(changed(baseline, ModelSelection(harness: "codex", modelId: "terra")))
    }
}
