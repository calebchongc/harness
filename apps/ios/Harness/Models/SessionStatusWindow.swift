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

    var overflowText: String? { hiddenCount > 0 ? "+\(hiddenCount)" : nil }

    /// Reserve title space and only the navigation that is actually rendered.
    /// Compact overflow leaves room for more status marks and the session title.
    static func visibleLimit(availableWidth: CGFloat, total: Int, hasPager: Bool) -> Int {
        guard total > 0 else { return 0 }
        // Both the current index and total can grow to multiple digits.
        let counterWidth = CGFloat(String(total).count * 2 + 1) * 7
        let navigationWidth: CGFloat = hasPager ? 56 + counterWidth + 7 : 7
        let budget = availableWidth - 120 - navigationWidth
        for count in stride(from: min(6, total), through: 1, by: -1) {
            let marksWidth = CGFloat(count * 16 + (count - 1) * 3)
            let overflowWidth: CGFloat = total > count ? 3 + CGFloat(String(total - count).count + 1) * 7 : 0
            if marksWidth + overflowWidth <= budget { return count }
        }
        return 1
    }
}
