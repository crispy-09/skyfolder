import Foundation
import UniformTypeIdentifiers

struct RemoteItem: Codable, Hashable, Identifiable {
    var id: String              // oc:fileid ("storage$space!opaque")
    var parentID: String?
    var name: String
    var path: String?           // path relative to the space root, no leading slash ("" = root)
    var isFolder: Bool
    var size: Int64
    var modified: Date?
    var etag: String
    var contentType: String?
    var permissions: String
    var tags: [String]
    var privateLink: String?
    var hasPreview: Bool
    var ownerName: String?

    // Trash-only fields
    var trashKey: String?
    var originalLocation: String?
    var deletedAt: Date?

    var isFavorite: Bool { tags.contains(AppConstants.favoriteTag) }

    /// Opaque node id (the part after "!"); also the trash-bin key once the item is deleted.
    var opaqueID: String {
        if let i = id.lastIndex(of: "!") { return String(id[id.index(after: i)...]) }
        return id
    }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    var utType: UTType {
        if isFolder { return .folder }
        if let t = UTType(filenameExtension: fileExtension) { return t }
        if let ct = contentType, let t = UTType(mimeType: ct) { return t }
        return .data
    }

    var canWrite: Bool { permissions.contains("W") || permissions.isEmpty }
    var canDelete: Bool { permissions.contains("D") || permissions.isEmpty }
    var canRename: Bool { permissions.contains("N") || permissions.isEmpty }
    var canMove: Bool { permissions.contains("V") || permissions.isEmpty }
    var canAddChildren: Bool { permissions.contains("C") || permissions.contains("K") || permissions.isEmpty }

    /// Parent path ("" for items at the root), when the path is known.
    var parentPath: String? {
        guard let path else { return nil }
        let p = (path as NSString).deletingLastPathComponent
        return p == "/" ? "" : p
    }
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
