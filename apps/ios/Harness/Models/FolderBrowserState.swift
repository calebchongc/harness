import Foundation

/// Folder paths and Git metadata belong to a particular host and successful
/// request. A reply from a superseded request must never mutate that selection.
///
/// Listings recently loaded come from `cache` straight away (#420): a fresh one
/// needs no request at all, an older one is shown while a background request
/// refreshes it. Only a folder with nothing cached waits on the host.
struct FolderBrowserState {
    struct Selection {
        let deviceId: String
        let listing: FolderListing
        let isRepo: Bool
    }

    struct Request: Equatable {
        let id = UUID()
        let deviceId: String
        let path: String?
        let isRepo: Bool
        /// The folder's cached listing is already on screen; this request
        /// only refreshes it.
        var revalidating = false
    }

    private(set) var deviceId: String?
    private(set) var pendingRequest: Request?
    private(set) var error: String?
    private var selection: Selection?
    /// Shared with the app so a reopened sheet starts from what it saw.
    var cache: FolderListingCache
    private let now: () -> Date

    init(cache: FolderListingCache = FolderListingCache(), now: @escaping () -> Date = Date.init) {
        self.cache = cache
        self.now = now
    }

    /// A folder with nothing to show yet is loading. Refreshing a cached
    /// listing that is already on screen isn't: it neither shows a spinner
    /// nor blocks "Use this folder".
    var isLoading: Bool { pendingRequest.map { !$0.revalidating } ?? false }
    var isRefreshing: Bool { pendingRequest?.revalidating ?? false }

    mutating func selectDevice(_ id: String?) {
        guard deviceId != id else { return }
        deviceId = id
        pendingRequest = nil
        selection = nil
        error = nil
    }

    /// Called synchronously by the navigation action, before starting its Task,
    /// so creation is blocked even before the new RPC gets scheduled. Returns
    /// the request to send, or nil when there's none: no host, or a listing
    /// fresh enough to show as it is. `refresh` asks the host even then.
    mutating func begin(path: String?, isRepo: Bool = false, refresh: Bool = false) -> Request? {
        guard let deviceId else { return nil }
        error = nil
        switch cache.lookup(deviceId: deviceId, path: path, now: now()) {
        case .fresh(let listing) where !refresh:
            // Supersedes whatever was in flight; its reply no longer applies.
            selection = Selection(deviceId: deviceId, listing: listing, isRepo: isRepo)
            pendingRequest = nil
            return nil
        case .fresh(let listing), .stale(let listing):
            selection = Selection(deviceId: deviceId, listing: listing, isRepo: isRepo)
            let request = Request(deviceId: deviceId, path: path, isRepo: isRepo, revalidating: true)
            pendingRequest = request
            return request
        case .miss:
            let request = Request(deviceId: deviceId, path: path, isRepo: isRepo)
            pendingRequest = request
            return request
        }
    }

    /// The view's current host is checked as well: its device list can change
    /// before SwiftUI starts the replacement host task.
    @discardableResult
    mutating func finish(_ request: Request, listing: FolderListing?,
                         currentDeviceId: String?, cancelled: Bool = false,
                         failureMessage: String) -> Bool {
        if let listing {
            // Even a superseded reply is a good listing of its folder: keep it
            // for the next visit, without showing it now.
            cache.store(listing, deviceId: request.deviceId, requestedPath: request.path, now: now())
        }
        guard pendingRequest == request, deviceId == request.deviceId,
              currentDeviceId == request.deviceId else { return false }
        pendingRequest = nil
        guard !cancelled else { return false }
        if let listing {
            selection = Selection(deviceId: request.deviceId, listing: listing, isRepo: request.isRepo)
        } else {
            // Keep the last successful path AND its Git flag when navigation
            // fails. Only a successful reply may replace either value. A
            // failed refresh keeps the cached listing on screen with the
            // error, but stops serving it on later visits.
            error = failureMessage
            if request.revalidating {
                cache.invalidate(deviceId: request.deviceId, path: request.path)
            }
        }
        return true
    }

    mutating func cancelPendingRequest() {
        pendingRequest = nil
    }

    func selection(for currentDeviceId: String?) -> Selection? {
        guard let currentDeviceId, deviceId == currentDeviceId,
              selection?.deviceId == currentDeviceId else { return nil }
        return selection
    }

    func creationTarget(for currentDeviceId: String?) -> Selection? {
        guard !isLoading else { return nil }
        return selection(for: currentDeviceId)
    }
}
