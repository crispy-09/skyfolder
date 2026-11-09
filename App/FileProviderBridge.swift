import Foundation
import FileProvider
import AppKit

/// App-side control of the Finder integration (File Provider domain).
enum FileProviderBridge {
    static var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: AppConstants.domainIdentifier, displayName: AppConstants.domainDisplayName)
    }

    static var manager: NSFileProviderManager? { NSFileProviderManager(for: domain) }

    /// Registers the domain so it shows up in Finder's sidebar. Safe to call repeatedly.
    static func register() async throws {
        let existing = try await NSFileProviderManager.domains()
        if !existing.contains(where: { $0.identifier == AppConstants.domainIdentifier }) {
            try await NSFileProviderManager.add(domain)
        }
        // Clear any "sign in required" state from an earlier expired session.
        try? await manager?.signalErrorResolved(NSFileProviderError(.notAuthenticated))
        try? await manager?.signalEnumerator(for: .workingSet)
    }

    static func unregister() async {
        if let domains = try? await NSFileProviderManager.domains() {
            for d in domains where d.identifier == AppConstants.domainIdentifier {
                _ = try? await NSFileProviderManager.remove(d, mode: .removeAll)
            }
        }
        // Drop the extension's change-tracking cache too.
        let dir = AppConstants.groupContainer
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasPrefix("fp-cache-") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
    }

    static func isRegistered() async -> Bool {
        (try? await NSFileProviderManager.domains())?.contains { $0.identifier == AppConstants.domainIdentifier } ?? false
    }

    /// Tell the extension to look for server-side changes.
    static func signalChanges() {
        manager?.signalEnumerator(for: .workingSet) { _ in }
    }

    static func rootURL() async -> URL? {
        try? await manager?.getUserVisibleURL(for: .rootContainer)
    }

    /// Finder-visible URL for an item by its path within the space (lookups materialize folders on demand).
    static func localURL(forPath path: String) async -> URL? {
        guard let root = await rootURL() else { return nil }
        return path.isEmpty ? root : root.appendingPathComponent(path)
    }

    static func identifier(for item: RemoteItem, rootID: String) -> NSFileProviderItemIdentifier {
        item.id == rootID ? .rootContainer : NSFileProviderItemIdentifier(item.id)
    }

    /// Pins or unpins items for offline use, then asks the system to download or evict them.
    static func setOffline(_ items: [RemoteItem], on: Bool, rootID: String) async {
        for it in items {
            PinnedStore.set(it.id, pinned: on, info: .init(name: it.name, isFolder: it.isFolder, path: it.path))
        }
        guard let manager else { return }
        // Make sure the system has seen these items (a lookup on the path materializes them).
        for it in items {
            if let p = it.path, let url = await localURL(forPath: p) {
                _ = FileManager.default.fileExists(atPath: url.path)
            }
        }
        try? await manager.signalEnumerator(for: .workingSet)
        for it in items {
            let ident = identifier(for: it, rootID: rootID)
            if on {
                try? await manager.requestDownloadForItem(withIdentifier: ident,
                                                          requestedRange: NSRange(location: NSNotFound, length: 0))
            } else {
                try? await manager.evictItem(identifier: ident)
            }
        }
    }
}
