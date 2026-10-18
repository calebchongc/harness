import Foundation

/// A bounded, ordered window of status marks. The open session stays visible;
/// the overflow label counts every omitted session, including those before it.
struct SessionStatusWindow {
    let visibleIDs: [String]
    let hiddenCount: Int

    init(ids: [String], current: String, limit: Int) {
        let count = min(ids.count, max(0, limit))
        let index = ids.firstIndex(of: current) ?? 0
        let start = min(max(0, index - count / 2), ids.count - count)
        visibleIDs = Array(ids[start..<(start + count)])
        hiddenCount = ids.count - count
    }

    var overflowText: String? { hiddenCount > 0 ? "\(hiddenCount) more" : nil }

    /// Reserve title space and only the navigation that is actually rendered.
    /// Overflow uses words rather than a plus sign so it cannot look like Add.
    static func visibleLimit(availableWidth: CGFloat, total: Int, hasPager: Bool) -> Int {
        guard total > 0 else { return 0 }
        // Both the current index and total can grow to multiple digits.
        let counterWidth = CGFloat(String(total).count * 2 + 1) * 7
        let navigationWidth: CGFloat = hasPager ? 88 + counterWidth + 16 : 8
        let budget = availableWidth - 80 - navigationWidth
        let maximum = min(6, total)
        if CGFloat(maximum) * 19 <= budget, total <= 6 { return maximum }
        return max(1, min(maximum, Int((budget - 40) / 19)))
    }
}
