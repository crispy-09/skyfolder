import FileProvider
import AppKit
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {
    let domain: NSFileProviderDomain
    private var client: DAVClient?
    private var cache: ItemCache?
    private lazy var manager = NSFileProviderManager(for: domain)

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    // MARK: Context

    /// Returns the API client and cache, (re)loading the account if needed. Throws notAuthenticated if signed out.
    func context() throws -> (DAVClient, ItemCache) {
        guard let account = AccountConfig.load() else { throw NSFileProviderError(.notAuthenticated) }
        if let client, client.account == account, let cache { return (client, cache) }
        let c = DAVClient(account: account)
        let k = ItemCache(domainID: domain.identifier.rawValue)
        client = c
        cache = k
        return (c, k)
    }

    func remoteID(_ identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer { return AccountConfig.load()?.rootID ?? "" }
        return identifier.rawValue
    }

    static func mapError(_ error: Error) -> Error {
        switch error {
        case let e as NSFileProviderError: return e
        case AuthError.notSignedIn, AuthError.sessionExpired, DAVError.unauthorized:
            return NSFileProviderError(.notAuthenticated)
        case DAVError.notFound: return NSFileProviderError(.noSuchItem)
        case DAVError.insufficientStorage: return NSFileProviderError(.insufficientQuota)
        case DAVError.alreadyExists: return NSFileProviderError(.filenameCollision)
        case let e as URLError:
            if e.code == .cancelled { return CocoaError(.userCancelled) }
            return NSFileProviderError(.serverUnreachable)
        case is CancellationError: return CocoaError(.userCancelled)
        default: return error
        }
    }

    /// Runs async work and wires cancellation into the returned Progress.
    private func run(_ progress: Progress, _ body: @escaping () async throws -> Void, onError: @escaping (Error) -> Void) -> Progress {
        let task = Task {
            do { try await body() } catch { onError(Self.mapError(error)) }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private func fpItem(_ r: RemoteItem) -> FileProviderItem {
        FileProviderItem(r, rootID: client?.account.rootID ?? "")
    }

    private func signalWorkingSet() {
        manager?.signalEnumerator(for: .workingSet) { _ in }
    }

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .trashContainer || identifier == .workingSet {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        return run(progress, { [self] in
            let (client, _) = try context()
            let item = try await client.item(id: remoteID(identifier))
            completionHandler(fpItem(item), nil)
            progress.completedUnitCount = 1
        }, onError: { completionHandler(nil, $0) })
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        return run(progress, { [self] in
            let (client, _) = try context()
            let id = remoteID(itemIdentifier)
            let item = try await client.item(id: id)
            progress.totalUnitCount = max(item.size, 1)
            guard let tmpDir = try manager?.temporaryDirectoryURL() else { throw NSFileProviderError(.cannotSynchronize) }
            let dest = tmpDir.appendingPathComponent(UUID().uuidString)
            try await client.download(id: id, to: dest, progress: progress)
            DownloadedStore.record(id, name: item.name, path: cache(for: client).path(for: id, rootID: client.account.rootID))
            completionHandler(dest, fpItem(item), nil)
        }, onError: { completionHandler(nil, nil, $0) })
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let type = itemTemplate.contentType ?? .data
        if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) {
            // Links aren't supported by OpenCloud; keep them local only.
            completionHandler(itemTemplate, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return progress
        }
        if Self.isExcluded(itemTemplate.filename) {
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return progress
        }
        return run(progress, { [self] in
            let (client, cache) = try context()
            let parentID = remoteID(itemTemplate.parentItemIdentifier)
            let name = itemTemplate.filename

            if type.conforms(to: .folder) {
                let folder: RemoteItem
                do {
                    folder = try await client.createFolder(parentID: parentID, name: name)
                } catch DAVError.alreadyExists {
                    // Merge with the existing remote folder of the same name.
                    guard let existing = try await client.child(parentID: parentID, name: name), existing.isFolder else {
                        throw DAVError.alreadyExists
                    }
                    folder = existing
                }
                cache.upsert(folder, parentID: parentID)
                completionHandler(fpItem(folder), [], false, nil)
                return
            }

            guard let url else { throw NSFileProviderError(.cannotSynchronize) }
            var targetName = name
            if let existing = try await client.child(parentID: parentID, name: name) {
                let localSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
                if options.contains(.mayAlreadyExist), !existing.isFolder, existing.size == localSize {
                    cache.upsert(existing, parentID: parentID)
                    completionHandler(fpItem(existing), [], false, nil)
                    return
                }
                // The server ignores If-None-Match, so never PUT over a file the system doesn't know about.
                targetName = try await client.availableName(parentID: parentID, desired: name)
            }
            let item = try await client.upload(file: url, to: .new(parentID: parentID, name: targetName),
                                               modified: itemTemplate.contentModificationDate ?? nil, progress: progress)
            cache.upsert(item, parentID: parentID)
            DownloadedStore.record(item.id, name: item.name, path: cache.path(for: item.id, rootID: client.account.rootID))
            completionHandler(fpItem(item), [], false, nil)
        }, onError: { completionHandler(nil, [], false, $0) })
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        return run(progress, { [self] in
            let (client, cache) = try context()
            let id = remoteID(item.itemIdentifier)
            let parentID = remoteID(item.parentItemIdentifier)
            var result: RemoteItem?

            if changedFields.contains(.contents), let newContents, !(item.contentType?.conforms(to: .folder) ?? false) {
                let baseEtag = String(data: version.contentVersion, encoding: .utf8)
                do {
                    result = try await client.upload(file: newContents, to: .existing(id: id, ifMatch: baseEtag),
                                                     modified: item.contentModificationDate ?? nil, progress: progress)
                } catch DAVError.preconditionFailed {
                    // Edited here and on the server: keep both. Local edits go to a conflicted copy,
                    // and the local file is refreshed with the server version.
                    let ext = (item.filename as NSString).pathExtension
                    let base = (item.filename as NSString).deletingPathExtension
                    let stamp = Self.conflictStamp()
                    let conflictName = ext.isEmpty ? "\(base) (conflicted copy \(stamp))"
                                                   : "\(base) (conflicted copy \(stamp)).\(ext)"
                    let copy = try await client.upload(file: newContents, to: .new(parentID: parentID, name: conflictName),
                                                       modified: nil, progress: nil)
                    cache.upsert(copy, parentID: parentID)
                    let server = try await client.item(id: id)
                    completionHandler(fpItem(server), [], true, nil)
                    signalWorkingSet()
                    return
                }
            }

            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                result = try await client.move(id: id, toParent: parentID, name: item.filename)
            }

            let final: RemoteItem
            if let result { final = result } else { final = try await client.item(id: id) }
            cache.upsert(final, parentID: parentID)
            DownloadedStore.updatePath(id, name: final.name, path: cache.path(for: id, rootID: client.account.rootID))
            completionHandler(fpItem(final), [], false, nil)
        }, onError: { completionHandler(nil, [], false, $0) })
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .rootContainer {
            completionHandler(NSFileProviderError(.deletionRejected))
            return progress
        }
        return run(progress, { [self] in
            let (client, cache) = try context()
            let id = remoteID(identifier)
            try await client.delete(id: id) // goes to the OpenCloud trash bin, so it can be restored
            cache.remove(id)
            PinnedStore.set(id, pinned: false, info: nil)
            DownloadedStore.remove([id])
            completionHandler(nil)
        }, onError: { completionHandler($0) })
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer { throw NSFileProviderError(.noSuchItem) }
        _ = try context()
        return FileProviderEnumerator(container: containerItemIdentifier, ext: self)
    }

    /// macOS metadata files that should never be uploaded.
    static func isExcluded(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".Trash" || name == ".localized" || name == "Icon\r"
            || name.hasPrefix("._") || name == ".TemporaryItems" || name.hasPrefix(".~lock.")
    }

    private func cache(for client: DAVClient) -> ItemCache {
        (try? context().1) ?? ItemCache(domainID: domain.identifier.rawValue)
    }

    private static func conflictStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    // MARK: Finder actions

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        return run(progress, { [self] in
            let (client, _) = try context()
            switch actionIdentifier.rawValue {
            case "io.github.crispy-09.skyfolder.action.keepOffline", "io.github.crispy-09.skyfolder.action.onlineOnly":
                let pin = actionIdentifier.rawValue.hasSuffix("keepOffline")
                for ident in itemIdentifiers {
                    let id = remoteID(ident)
                    let item = try? await client.item(id: id)
                    PinnedStore.set(id, pinned: pin,
                                    info: item.map { .init(name: $0.name, isFolder: $0.isFolder, path: $0.path) })
                }
                try await manager?.signalEnumerator(for: .workingSet)
                for ident in itemIdentifiers {
                    if pin {
                        try? await manager?.requestDownloadForItem(withIdentifier: ident, requestedRange: NSRange(location: NSNotFound, length: 0))
                    } else {
                        try? await manager?.evictItem(identifier: ident)
                    }
                }
            case "io.github.crispy-09.skyfolder.action.openWeb":
                if let ident = itemIdentifiers.first {
                    let url = client.account.webURL(forFileID: remoteID(ident))
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
            default:
                break
            }
            completionHandler(nil)
        }, onError: { completionHandler($0) })
    }
}
