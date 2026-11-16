import Foundation

/// Remembers what we last told the system about each folder we've enumerated, so we can turn a fresh server
/// listing into "updated" / "deleted" change sets. OpenCloud propagates etags up the tree, so an unchanged
/// folder etag means nothing below it changed and we can skip it.
final class ItemCache {
    struct Folder: Codable {
        var etag: String
        var children: [String: RemoteItem]
    }

    private struct State: Codable {
        var anchor: Int = 1
        var folders: [String: Folder] = [:]
    }

    private var state = State()
    private let lock = NSLock()
    private let url: URL

    init(domainID: String) {
        url = AppConstants.groupContainer.appendingPathComponent("fp-cache-\(domainID).json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        }
    }

    /// While a change scan runs, nothing is written to disk: the scan's findings only count once they have been
    /// handed to the system. If the scan fails, or the process dies first, the saved state is still the old one
    /// and the next scan finds the same differences again.
    private var scanning = false

    /// Starts a scan and returns a copy of the current state to roll back to.
    func beginScan() -> Data? {
        lock.withLock {
            scanning = true
            return try? JSONEncoder().encode(state)
        }
    }

    /// The scan's results were delivered: save.
    func commitScan() {
        lock.withLock { scanning = false; persist() }
    }

    /// The scan failed: forget what it changed.
    func abortScan(_ snapshot: Data?) {
        lock.withLock {
            scanning = false
            if let snapshot, let s = try? JSONDecoder().decode(State.self, from: snapshot) { state = s }
        }
    }

    private func persist() {
        if scanning { return }
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }

    var anchor: Int { lock.withLock { state.anchor } }

    func folderEtag(_ id: String) -> String? { lock.withLock { state.folders[id]?.etag } }

    func isKnownFolder(_ id: String) -> Bool { lock.withLock { state.folders[id] != nil } }

    func allItems() -> [RemoteItem] {
        lock.withLock { state.folders.values.flatMap { $0.children.values } }
    }

    /// Stores a fresh listing and returns the difference against the previous one.
    @discardableResult
    func replace(folderID: String, etag: String, children: [RemoteItem]) -> (updated: [RemoteItem], deleted: [String]) {
        lock.withLock {
            let old = state.folders[folderID]?.children ?? [:]
            var new: [String: RemoteItem] = [:]
            var updated: [RemoteItem] = []
            for c in children {
                new[c.id] = c
                if old[c.id] != c { updated.append(c) }
            }
            let deleted = old.keys.filter { new[$0] == nil }
            state.folders[folderID] = Folder(etag: etag, children: new)
            for d in deleted where old[d]?.isFolder == true { pruneLocked(d) }
            if !updated.isEmpty || !deleted.isEmpty { state.anchor += 1 }
            persist()
            return (updated, Array(deleted))
        }
    }

    func upsert(_ item: RemoteItem, parentID: String) {
        lock.withLock {
            // Remove from any previous parent (moves).
            for key in state.folders.keys where key != parentID {
                state.folders[key]?.children.removeValue(forKey: item.id)
            }
            // The parent may be a folder created on this Mac that the system never asked us to enumerate.
            // Track it anyway (empty etag = "rescan me"), otherwise remote changes inside it go unnoticed.
            if state.folders[parentID] == nil { state.folders[parentID] = Folder(etag: "", children: [:]) }
            state.folders[parentID]?.children[item.id] = item
            if item.isFolder, state.folders[item.id] == nil { state.folders[item.id] = Folder(etag: "", children: [:]) }
            persist()
        }
    }

    /// Starts tracking folders that exist on disk but were never enumerated through us (created on this Mac).
    /// - Parameter fullRescan: also forget every stored listing, so the next scan reports all items again. The
    ///   system ignores what it already has; this recovers changes an earlier build detected but never delivered.
    func registerFolders(_ ids: [String], fullRescan: Bool) {
        lock.withLock {
            var changed = false
            for id in ids where state.folders[id] == nil {
                state.folders[id] = Folder(etag: "", children: [:])
                changed = true
            }
            guard changed || fullRescan else { return }
            // Forget folder etags so the next scan walks the whole known tree and reaches the new entries.
            for key in state.folders.keys {
                state.folders[key]?.etag = ""
                if fullRescan { state.folders[key]?.children = [:] }
            }
            persist()
        }
    }

    func remove(_ id: String) {
        lock.withLock {
            for key in state.folders.keys { state.folders[key]?.children.removeValue(forKey: id) }
            pruneLocked(id)
            persist()
        }
    }

    /// Path of an item relative to the space root, reconstructed from enumerated folders (nil if unknown).
    func path(for id: String, rootID: String) -> String? {
        lock.withLock {
            var parts: [String] = []
            var current = id
            for _ in 0..<128 {
                if current == rootID { return parts.reversed().joined(separator: "/") }
                guard let (folderID, item) = state.folders.lazy
                        .compactMap({ key, f in f.children[current].map { (key, $0) } }).first else { return nil }
                parts.append(item.name)
                current = folderID
            }
            return nil
        }
    }

    func bumpAnchor() {
        lock.withLock { state.anchor += 1; persist() }
    }

    func reset() {
        lock.withLock { state = State(); persist() }
    }

    private func pruneLocked(_ folderID: String) {
        guard let f = state.folders.removeValue(forKey: folderID) else { return }
        for c in f.children.values where c.isFolder { pruneLocked(c.id) }
    }
}
