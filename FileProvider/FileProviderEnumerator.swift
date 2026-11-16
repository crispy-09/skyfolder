import FileProvider
import os

let syncLog = Logger(subsystem: "io.github.crispy-09.skyfolder", category: "sync")

/// Shared change-detection logic used by both folder and working-set enumerators.
struct ChangeScanner {
    let client: DAVClient
    let cache: ItemCache

    /// Walks down from the root, only into folders the system knows about and whose etag changed.
    /// `download` lists files that must be fetched to keep pinned items available offline.
    func scanWorkingSet() async throws -> (updated: [RemoteItem], deleted: [String], download: [String]) {
        // The cache is updated as the walk goes. If the walk fails part-way, roll it back; otherwise the next
        // scan would see "nothing changed" and the differences found so far would be lost for good.
        let before = cache.beginScan()
        let dirty = PinnedStore.takeDirty()
        do {
            return try await scan(dirty: dirty)
        } catch {
            cache.abortScan(before)
            PinnedStore.markDirty(dirty)
            throw error
        }
    }

    private func scan(dirty: [String]) async throws -> (updated: [RemoteItem], deleted: [String], download: [String]) {
        var updated: [String: RemoteItem] = [:]
        var deleted = Set<String>()
        var pinnedFiles: [String] = []
        let rootID = client.account.rootID

        let root = try await client.item(id: rootID)
        if cache.folderEtag(rootID) != root.etag || !cache.isKnownFolder(rootID) {
            try await visit(rootID, force: false, updated: &updated, deleted: &deleted, files: &pinnedFiles)
        }

        // Items whose local-only metadata (pin state) changed.
        PinnedStore.migrateContentPolicyIfNeeded()
        let pins = PinnedStore.all()
        for id in dirty {
            guard let it = try? await client.item(id: id) else { continue }
            updated[it.id] = it
            // A folder that was just pinned: walk all of it so every file inside gets downloaded.
            if pins[id] != nil {
                if it.isFolder {
                    try await visit(id, force: true, updated: &updated, deleted: &deleted, files: &pinnedFiles)
                } else {
                    pinnedFiles.append(id)
                }
            }
        }
        deleted.subtract(updated.keys) // moved items show up as "missing here, present there"

        // Keep pins pointing at the right place after renames and moves.
        for (id, _) in pins {
            guard let it = updated[id], let path = cache.path(for: id, rootID: rootID) else { continue }
            PinnedStore.updateLocation(id, name: it.name, path: path)
        }
        // Remote edits and new files inside pinned items must be fetched again to stay available offline.
        if !pins.isEmpty {
            let current = PinnedStore.all()
            for u in updated.values where !u.isFolder
                && PinnedStore.covers(u.id, path: cache.path(for: u.id, rootID: rootID), in: current) {
                pinnedFiles.append(u.id)
            }
        }
        return (Array(updated.values), Array(deleted), Array(Set(pinnedFiles)))
    }

    /// - Parameter force: walk every subfolder regardless of etags, collecting all files (used for new pins).
    private func visit(_ folderID: String, force: Bool, updated: inout [String: RemoteItem], deleted: inout Set<String>,
                       files: inout [String]) async throws {
        let listing: (folder: RemoteItem?, children: [RemoteItem])
        do {
            listing = try await client.listFolder(id: folderID)
        } catch DAVError.notFound {
            cache.remove(folderID)
            deleted.insert(folderID)
            return
        }
        // Capture old child etags before replacing so we know which subfolders changed.
        let oldEtags = Dictionary(uniqueKeysWithValues: listing.children.filter(\.isFolder).map { ($0.id, cache.folderEtag($0.id)) })
        let known = Set(listing.children.filter { $0.isFolder && cache.isKnownFolder($0.id) }.map(\.id))
        let diff = cache.replace(folderID: folderID, etag: listing.folder?.etag ?? "", children: listing.children)
        for u in diff.updated { updated[u.id] = u }
        deleted.formUnion(diff.deleted)
        if force { files.append(contentsOf: listing.children.filter { !$0.isFolder }.map(\.id)) }
        let pins = PinnedStore.all()
        let rootID = client.account.rootID
        for child in listing.children where child.isFolder {
            // Folders the system hasn't looked into are skipped, unless they must be kept offline.
            let wanted = force || known.contains(child.id)
                || (!pins.isEmpty && PinnedStore.covers(child.id, path: cache.path(for: child.id, rootID: rootID), in: pins))
            if wanted, force || oldEtags[child.id] != child.etag {
                try await visit(child.id, force: force, updated: &updated, deleted: &deleted, files: &files)
            }
        }
    }
}

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let ext: FileProviderExtension

    init(container: NSFileProviderItemIdentifier, ext: FileProviderExtension) {
        self.container = container
        self.ext = ext
    }

    func invalidate() {}

    private var isWorkingSet: Bool { container == .workingSet }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let (client, cache) = try ext.context()
                if isWorkingSet {
                    let items = cache.allItems().map { FileProviderItem($0, rootID: client.account.rootID) }
                    if !items.isEmpty { observer.didEnumerate(items) }
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                let folderID = ext.remoteID(container)
                let listing = try await client.listFolder(id: folderID)
                cache.replace(folderID: folderID, etag: listing.folder?.etag ?? "", children: listing.children)
                let items = listing.children.map { FileProviderItem($0, rootID: client.account.rootID) }
                // Hand items over in reasonably sized batches.
                var idx = 0
                while idx < items.count {
                    let end = min(idx + 500, items.count)
                    observer.didEnumerate(Array(items[idx..<end]))
                    idx = end
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.mapError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                let (client, cache) = try ext.context()
                let scanner = ChangeScanner(client: client, cache: cache)
                let changes: (updated: [RemoteItem], deleted: [String])
                var download: [String] = []
                if isWorkingSet {
                    await ext.adoptMaterializedFolders(into: cache)
                    let r = try await scanner.scanWorkingSet()
                    syncLog.notice("working set: \(r.updated.count) updated, \(r.deleted.count) deleted, \(r.download.count) to download")
                    changes = (r.updated, r.deleted)
                    download = r.download
                } else {
                    let folderID = ext.remoteID(container)
                    do {
                        let listing = try await client.listFolder(id: folderID)
                        changes = cache.replace(folderID: folderID, etag: listing.folder?.etag ?? "",
                                                children: listing.children)
                    } catch DAVError.notFound {
                        cache.remove(folderID)
                        observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
                        return
                    }
                }
                let rootID = client.account.rootID
                let downloaded = DownloadedStore.all()
                DownloadedStore.updatePaths(changes.updated.filter { downloaded[$0.id] != nil }.map {
                    ($0.id, $0.name, cache.path(for: $0.id, rootID: rootID))
                })
                DownloadedStore.remove(changes.deleted.filter { downloaded[$0] != nil })
                if !changes.updated.isEmpty {
                    observer.didUpdate(changes.updated.map { FileProviderItem($0, rootID: rootID) })
                }
                if !changes.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier($0) })
                }
                observer.finishEnumeratingChanges(upTo: Self.anchor(cache.anchor), moreComing: false)
                if isWorkingSet { cache.commitScan() }
                ext.requestDownloads(download)
            } catch {
                syncLog.error("enumerating changes failed: \(String(describing: error), privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderExtension.mapError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let (_, cache) = try? ext.context() else { completionHandler(nil); return }
        completionHandler(Self.anchor(cache.anchor))
    }

    static func anchor(_ n: Int) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(n).utf8))
    }
}
