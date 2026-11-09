import FileProvider

/// Shared change-detection logic used by both folder and working-set enumerators.
struct ChangeScanner {
    let client: DAVClient
    let cache: ItemCache

    /// Walks down from the root, only into folders the system knows about and whose etag changed.
    func scanWorkingSet() async throws -> (updated: [RemoteItem], deleted: [String]) {
        var updated: [String: RemoteItem] = [:]
        var deleted = Set<String>()
        let rootID = client.account.rootID

        let root = try await client.item(id: rootID)
        if cache.folderEtag(rootID) != root.etag || !cache.isKnownFolder(rootID) {
            try await visit(rootID, updated: &updated, deleted: &deleted)
        }

        // Items whose local-only metadata (pin state) changed.
        for id in PinnedStore.takeDirty() {
            if let it = try? await client.item(id: id) { updated[it.id] = it }
        }
        deleted.subtract(updated.keys) // moved items show up as "missing here, present there"
        return (Array(updated.values), Array(deleted))
    }

    private func visit(_ folderID: String, updated: inout [String: RemoteItem], deleted: inout Set<String>) async throws {
        let listing: (folder: RemoteItem?, children: [RemoteItem])
        do {
            listing = try await client.listFolder(id: folderID)
        } catch DAVError.notFound {
            cache.remove(folderID)
            deleted.insert(folderID)
            return
        }
        // Capture old child etags before replacing so we know which subfolders changed.
        let diff = cache.replace(folderID: folderID, etag: listing.folder?.etag ?? "", children: listing.children)
        for u in diff.updated { updated[u.id] = u }
        deleted.formUnion(diff.deleted)
        for child in listing.children where child.isFolder && cache.isKnownFolder(child.id) {
            if cache.folderEtag(child.id) != child.etag {
                try await visit(child.id, updated: &updated, deleted: &deleted)
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
                if isWorkingSet {
                    changes = try await scanner.scanWorkingSet()
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
                for u in changes.updated where downloaded[u.id] != nil {
                    DownloadedStore.updatePath(u.id, name: u.name, path: cache.path(for: u.id, rootID: rootID))
                }
                DownloadedStore.remove(changes.deleted.filter { downloaded[$0] != nil })
                if !changes.updated.isEmpty {
                    observer.didUpdate(changes.updated.map { FileProviderItem($0, rootID: rootID) })
                }
                if !changes.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier($0) })
                }
                observer.finishEnumeratingChanges(upTo: Self.anchor(cache.anchor), moreComing: false)
            } catch {
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
