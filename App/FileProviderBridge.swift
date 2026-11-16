import Foundation
import FileProvider
import AppKit

/// App-side control of the Finder integration (File Provider domain).
enum FileProviderBridge {
    static var domain: NSFileProviderDomain {
        let d = NSFileProviderDomain(identifier: AppConstants.domainIdentifier, displayName: AppConstants.domainDisplayName)
        // Deleting in Finder goes straight to the server's trash bin (restorable from the app). A separate local
        // Trash for the drive isn't implemented, and leaving it on made Finder's trash operations fail.
        d.supportsSyncingTrash = false
        return d
    }

    static var manager: NSFileProviderManager? { NSFileProviderManager(for: domain) }

    /// Registers the domain so it shows up in Finder's sidebar. Safe to call repeatedly.
    static func register() async throws {
        let existing = try await NSFileProviderManager.domains()
        // Only for a new registration. Never re-add a live domain to change its settings: doing that restarted
        // the domain underneath the system and left it unable to start ("database is locked").
        if !existing.contains(where: { $0.identifier == AppConstants.domainIdentifier }) {
            try await NSFileProviderManager.add(domain)
        }
        // Clear any "sign in required" state from an earlier expired session.
        try? await manager?.signalErrorResolved(NSFileProviderError(.notAuthenticated))
        // Earlier builds failed every Trash operation; the system backs such failures off for hours. Tell it
        // they are worth retrying now, so work queued behind them isn't stuck until the timer runs out.
        try? await manager?.signalErrorResolved(NSFileProviderError(.noSuchItem))
        try? await manager?.signalErrorResolved(NSFileProviderError(.serverUnreachable))
        try? await manager?.signalErrorResolved(NSFileProviderError(.cannotSynchronize))
        try? await manager?.signalEnumerator(for: .workingSet)
    }

    /// Removes the Finder location. Files with changes that were never uploaded are preserved; returns where.
    @discardableResult
    static func unregister() async -> URL? {
        var preserved: URL?
        if let domains = try? await NSFileProviderManager.domains() {
            for d in domains where d.identifier == AppConstants.domainIdentifier {
                if let url = try? await NSFileProviderManager.remove(d, mode: .preserveDirtyUserData) { preserved = url }
            }
        }
        // Drop the extension's change-tracking cache too.
        let dir = AppConstants.groupContainer
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasPrefix("fp-cache-") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        return preserved
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
    /// Downloads a file now. Going through the file itself is treated like Finder's "Download Now" and starts
    /// right away; `requestDownloadForItem` only queues a background download that can wait a long time when the
    /// system is busy (it stays as the fallback).
    private static func download(_ item: RemoteItem) async {
        if let p = item.path, let url = await localURL(forPath: p),
           (try? FileManager.default.startDownloadingUbiquitousItem(at: url)) != nil {
            return
        }
        try? await manager?.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(item.id),
                                                   requestedRange: NSRange(location: NSNotFound, length: 0))
    }

    /// `contained` lists the files inside any pinned folders; with the on-demand content policy the system no longer
    /// downloads a folder's subtree by itself, so each file is requested explicitly.
    static func setOffline(_ items: [RemoteItem], contained: [RemoteItem] = [], on: Bool, rootID: String) async {
        if on { DownloadedStore.remove((items + contained).map(\.id)) }
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
        if on {
            for it in contained {
                // A lookup on the path makes the system enumerate the folders leading to it.
                await download(it)
            }
        }
        for it in items {
            let ident = identifier(for: it, rootID: rootID)
            if on {
                if it.isFolder {
                    try? await manager.requestDownloadForItem(withIdentifier: ident,
                                                              requestedRange: NSRange(location: NSNotFound, length: 0))
                } else {
                    await download(it)
                }
            } else {
                try? await manager.evictItem(identifier: ident)
            }
        }
    }
}
