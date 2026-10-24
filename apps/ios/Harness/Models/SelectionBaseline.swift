import Foundation

/// What a picker sheet's top-right control compares against: the selection
/// the sheet opened with. The control is an X (Close) while the current
/// selection matches it and a checkmark (Done) once it differs, so picking a
/// different row and then the original one again returns to the X (#407).
///
/// Host metadata can arrive while the sheet is open and resolve the bound
/// selection (a new session with no saved model resolves to the catalog's
/// first row, for example). That is not the user's change, so until the user
/// picks a row the baseline follows the bound value.
struct SelectionBaseline<Value: Equatable>: Equatable {
    private(set) var opening: Value
    private(set) var userPicked = false

    init(_ opening: Value) {
        self.opening = opening
    }

    /// The bound selection changed without a pick (metadata hydration).
    mutating func hydrated(to value: Value) {
        if !userPicked { opening = value }
    }

    /// The user picked a row; the baseline stays fixed for this opening.
    mutating func picked() {
        userPicked = true
    }

    func changed(to current: Value, same: (Value, Value) -> Bool = { $0 == $1 }) -> Bool {
        !same(opening, current)
    }
}

/// A model picker selection: the agent and the model's wire id.
struct ModelSelection: Equatable {
    var harness: String
    var modelId: String
}

extension HarnessCatalog {
    /// Whether two model selections stand for the same picker row. A legacy
    /// long-context alias and its base model are one row, so reselecting the
    /// highlighted row never counts as a change.
    static func sameRow(_ a: ModelSelection, _ b: ModelSelection,
                        catalogs: [String: [ModelInfo]]) -> Bool {
        guard a.harness == b.harness else { return false }
        let models = catalogs[a.harness] ?? []
        func row(_ id: String) -> String { resolveExisting(modelId: id, in: models)?.id ?? id }
        return row(a.modelId) == row(b.modelId)
    }
}
