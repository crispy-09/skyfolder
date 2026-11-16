import FileProvider
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let remote: RemoteItem
    private let rootID: String
    private let pinned: Bool

    init(_ remote: RemoteItem, rootID: String) {
        self.remote = remote
        self.rootID = rootID
        self.pinned = PinnedStore.isPinned(remote.id)
    }

    private var isRoot: Bool { remote.id == rootID }

    var itemIdentifier: NSFileProviderItemIdentifier {
        isRoot ? .rootContainer : NSFileProviderItemIdentifier(remote.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard !isRoot, let p = remote.parentID, p != rootID, !p.isEmpty, p != remote.id.components(separatedBy: "!").first
        else { return .rootContainer }
        return NSFileProviderItemIdentifier(p)
    }

    var filename: String { isRoot ? AppConstants.domainDisplayName : remote.name }

    var contentType: UTType { remote.utType }

    var documentSize: NSNumber? { remote.isFolder ? nil : NSNumber(value: remote.size) }

    var contentModificationDate: Date? { remote.modified }

    var creationDate: Date? { remote.modified }

    var itemVersion: NSFileProviderItemVersion {
        let content = remote.isFolder ? "folder" : remote.etag
        let meta = [remote.etag, remote.name, remote.parentID ?? "", pinned ? "p2" : "", remote.tags.joined(separator: ",")]
            .joined(separator: "|")
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data(meta.utf8))
    }

    var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = [.allowsReading]
        if remote.isFolder {
            caps.insert(.allowsContentEnumerating)
            if remote.canAddChildren { caps.insert(.allowsAddingSubItems) }
        } else if remote.canWrite {
            caps.insert(.allowsWriting)
        }
        if !isRoot {
            if remote.canRename { caps.insert(.allowsRenaming) }
            if remote.canMove { caps.insert(.allowsReparenting) }
            if remote.canDelete { caps.insert(.allowsDeleting) }
        }
        return caps
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        var flags: NSFileProviderFileSystemFlags = [.userReadable]
        if remote.isFolder { flags.insert(.userExecutable) }
        if remote.isFolder ? remote.canAddChildren : remote.canWrite { flags.insert(.userWritable) }
        return flags
    }

    /// Always on-demand. Pinned items are downloaded by Skyfolder (see `FileProviderExtension.requestDownloads`) rather
    /// than via `keepDownloaded`, because macOS refuses to evict such items ("... cannot be evicted").
    var contentPolicy: NSFileProviderContentPolicy {
        isRoot ? .downloadLazily : .inherited
    }

    var userInfo: [AnyHashable: Any]? { ["pinned": pinned] }

}
