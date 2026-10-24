import Foundation

/// Folder listings recently loaded from each computer, by path (#420). Without
/// it every step through the New space folder browser, including going back
/// to the folder just left, cost a phone → relay → host → filesystem round
/// trip. A class so the sheet and the app share one cache across presentations.
final class FolderListingCache {
    enum Lookup: Equatable {
        /// Loaded a moment ago: show it without asking the host again.
        case fresh(FolderListing)
        /// Older: show it now and refresh it from the host in the background.
        case stale(FolderListing)
        case miss
    }

    /// A listing this recent is shown without a refresh. Short, so a folder
    /// changed on the computer shows up on the next visit after that.
    let freshFor: TimeInterval
    /// A listing older than this isn't shown at all; the folder loads cold.
    let keepFor: TimeInterval
    /// Listings remembered at once; the least recently loaded goes first.
    let capacity: Int

    private struct Key: Hashable {
        let deviceId: String
        let path: String
    }

    private struct Entry {
        let listing: FolderListing
        let loadedAt: Date
    }

    private var entries: [Key: Entry] = [:]
    /// Each computer's home folder as it reported it, so a "home" request
    /// (no path) finds the listing stored under its real path.
    private var homes: [String: String] = [:]

    init(freshFor: TimeInterval = 10, keepFor: TimeInterval = 10 * 60, capacity: Int = 64) {
        self.freshFor = freshFor
        self.keepFor = keepFor
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func lookup(deviceId: String, path: String?, now: Date) -> Lookup {
        guard let key = key(deviceId: deviceId, path: path),
              let entry = entries[key] else { return .miss }
        let age = now.timeIntervalSince(entry.loadedAt)
        if age < 0 || age > keepFor { return .miss }
        return age <= freshFor ? .fresh(entry.listing) : .stale(entry.listing)
    }

    /// Stores the listing under the path it reports, and under the path it was
    /// requested by when that differs (home, a trailing slash).
    func store(_ listing: FolderListing, deviceId: String, requestedPath: String?, now: Date) {
        let entry = Entry(listing: listing, loadedAt: now)
        let reported = Key(deviceId: deviceId, path: Self.normalize(listing.path))
        entries[reported] = entry
        if requestedPath == nil {
            homes[deviceId] = reported.path
        } else if let requested = key(deviceId: deviceId, path: requestedPath), requested != reported {
            entries[requested] = entry
        }
        evict(now: now)
    }

    /// Forgets a folder the host couldn't list, so the next visit asks again
    /// instead of showing what may no longer be there.
    func invalidate(deviceId: String, path: String?) {
        guard let key = key(deviceId: deviceId, path: path),
              let listing = entries[key]?.listing else { return }
        // Its alias (the reported or requested path) goes with it.
        entries = entries.filter {
            !($0.key.deviceId == deviceId && ($0.key == key || $0.value.listing.path == listing.path))
        }
    }

    func removeAll() {
        entries.removeAll()
        homes.removeAll()
    }

    private func key(deviceId: String, path: String?) -> Key? {
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return homes[deviceId].map { Key(deviceId: deviceId, path: $0) }
        }
        return Key(deviceId: deviceId, path: Self.normalize(path))
    }

    private func evict(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.loadedAt) <= keepFor }
        guard entries.count > capacity else { return }
        let oldest = entries.sorted { $0.value.loadedAt < $1.value.loadedAt }
        for (key, _) in oldest.prefix(entries.count - capacity) {
            entries.removeValue(forKey: key)
        }
    }

    /// `/a/b/` and `/a/b` are one folder; `/` stays `/`.
    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
