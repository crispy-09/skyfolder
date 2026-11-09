import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Environment(DriveModel.self) private var model
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        let list = model.visibleItems
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar()
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)

            if !model.selection.isEmpty {
                SelectionBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else if model.section != .trash {
                FilterChips()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if model.sessionExpired {
                Banner(icon: "person.crop.circle.badge.exclamationmark",
                       text: "Your session expired. Sign in again to keep syncing.",
                       actionTitle: "Sign in") { model.reauthenticate() }
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }

            if model.section == .trash {
                TrashBanner().padding(.horizontal, 16).padding(.bottom, 8)
            }

            ZStack {
                if let err = model.loadError, list.isEmpty {
                    EmptyState(icon: "exclamationmark.icloud", title: "Couldn't load files", message: err,
                               actionTitle: "Try again") { model.reload() }
                } else if list.isEmpty && !model.isLoading {
                    emptyState
                } else if model.viewMode == .grid && model.section != .trash {
                    GridContent(items: list)
                } else {
                    ListContent(items: list)
                }

                if dropTargeted {
                    DropOverlay(folderName: model.crumbs.last?.name ?? "My Files")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.delete, .deleteForward, .return, .escape]) { press in
            handleKey(press.key, list: list)
        }
        .onKeyPress(characters: .init(charactersIn: "a")) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selection = Set(list.map(\.id))
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.section == .myFiles else { return false }
            model.upload(urls)
            return true
        } isTargeted: { dropTargeted = $0 && model.section == .myFiles }
        .onAppear { focused = true }
    }

    private func handleKey(_ key: KeyEquivalent, list: [RemoteItem]) -> KeyPress.Result {
        let sel = model.selectedItems
        switch key {
        case .delete, .deleteForward:
            guard !sel.isEmpty else { return .ignored }
            if model.section == .trash { model.dialog = PendingDialog(kind: .deleteForever(sel)) }
            else { model.trash(sel) }
            return .handled
        case .return:
            guard sel.count == 1 else { return .ignored }
            model.open(sel[0])
            return .handled
        case .escape:
            model.selection = []
            return .handled
        default:
            return .ignored
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.section {
        case .myFiles:
            EmptyState(icon: "tray.and.arrow.down", title: "Drop files here",
                       message: "or use the “New” button to upload files and create folders.")
        case .recent:
            EmptyState(icon: "clock", title: "No recent files", message: "Files you change in the last 30 days show up here.")
        case .starred:
            EmptyState(icon: "star", title: "No starred files", message: "Add stars to things you want to find easily later.")
        case .offline:
            EmptyState(icon: "checkmark.circle", title: "Nothing is on this Mac yet",
                       message: "Everything is online-only until you need it. Files you open or download show up here, and anything you mark “Make available offline” always stays downloaded.")
        case .trash:
            EmptyState(icon: "trash", title: "Trash is empty", message: "Items moved to the trash appear here.")
        case .search(let q):
            EmptyState(icon: "magnifyingglass", title: "No results for “\(q)”", message: "Try a different name.")
        }
    }
}

// MARK: Header

struct HeaderBar: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 4) {
            if model.section == .myFiles {
                Breadcrumbs()
            } else {
                Text(model.section.title)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.leading, 4)
            }
            Spacer()
            if model.section != .trash {
                ViewModeToggle()
            }
            Button { model.showDetails.toggle() } label: {
                Image(systemName: model.showDetails ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("View details")
        }
        .frame(height: 44)
    }
}

struct Breadcrumbs: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.crumbs.enumerated()), id: \.offset) { idx, crumb in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 2)
                }
                if idx == model.crumbs.count - 1 {
                    Menu {
                        Button { model.dialog = PendingDialog(kind: .newFolder) } label: {
                            Label("New folder", systemImage: "folder.badge.plus")
                        }
                        Button { model.pickAndUpload(folders: false) } label: {
                            Label("File upload", systemImage: "doc.badge.arrow.up")
                        }
                        Button { model.pickAndUpload(folders: true) } label: {
                            Label("Folder upload", systemImage: "folder.badge.gearshape")
                        }
                        if let f = model.currentFolder, idx > 0 {
                            Divider()
                            ItemMenuItems(item: f, inHeader: true)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(crumb.name).font(.system(size: 22)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .hoverBackground(selected: false, cornerRadius: 19, hoverColor: Theme.navHover)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Button { model.openFolder(path: crumb.path) } label: {
                        Text(crumb.name)
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .hoverBackground(selected: false, cornerRadius: 19, hoverColor: Theme.navHover)
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: URL.self) { urls, _ in
                        uploadInto(path: crumb.path, urls: urls)
                    }
                }
            }
        }
    }

    private func uploadInto(path: String, urls: [URL]) -> Bool {
        guard let client = model.client else { return false }
        Task {
            if let folder = try? await client.stat(client.spacePathURL(path)) {
                model.upload(urls, toFolderID: folder.id)
            }
        }
        return true
    }
}

struct ViewModeToggle: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            segment(.list, icon: "list.bullet")
            Rectangle().fill(Theme.chipBorder).frame(width: 1)
            segment(.grid, icon: "square.grid.2x2")
        }
        .frame(height: 32)
        .overlay(Capsule().stroke(Theme.chipBorder, lineWidth: 1))
        .clipShape(Capsule())
    }

    private func segment(_ mode: ViewMode, icon: String) -> some View {
        let on = model.viewMode == mode
        return Button { model.viewMode = mode } label: {
            HStack(spacing: 4) {
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                Image(systemName: icon).font(.system(size: 13))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 52, height: 32)
            .background(on ? Theme.navSelected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .list ? "List layout" : "Grid layout")
    }
}

struct FilterChips: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Menu {
                ForEach(FileKind.allCases.filter { $0 != .other }) { k in
                    Button { model.typeFilter = k } label: {
                        Label(k.label, systemImage: k.symbol)
                    }
                }
            } label: {
                ChipLabel(title: model.typeFilter?.label ?? "Type", active: model.typeFilter != nil)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .overlay(alignment: .trailing) { clearButton(model.typeFilter != nil) { model.typeFilter = nil } }

            Menu {
                ForEach(ModifiedFilter.allCases) { m in
                    Button(m.rawValue) { model.modifiedFilter = m }
                }
            } label: {
                ChipLabel(title: model.modifiedFilter?.rawValue ?? "Modified", active: model.modifiedFilter != nil)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .overlay(alignment: .trailing) { clearButton(model.modifiedFilter != nil) { model.modifiedFilter = nil } }

            Spacer()
        }
    }

    @ViewBuilder
    private func clearButton(_ show: Bool, _ action: @escaping () -> Void) -> some View {
        if show {
            Button(action: action) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
    }
}

struct ChipLabel: View {
    let title: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            if active { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            Text(title).font(.system(size: 13, weight: .medium))
            Image(systemName: active ? "xmark" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .opacity(active ? 0 : 1)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.navSelected : Theme.chip))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Color.clear : Theme.chipBorder, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct SelectionBar: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        let sel = model.selectedItems
        HStack(spacing: 2) {
            barButton("xmark", "Clear selection") { model.selection = [] }
            Text("\(model.selection.count) selected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8)
            if model.section == .trash {
                barButton("arrow.uturn.backward", "Restore") { model.restore(sel) }
                barButton("trash.slash", "Delete forever") { model.dialog = PendingDialog(kind: .deleteForever(sel)) }
            } else {
                barButton("arrow.down.to.line", "Download") { model.download(sel) }
                barButton("folder", "Move to…") { model.moveTargets = sel }
                barButton("trash", "Move to trash") { model.trash(sel) }
                let allStarred = sel.allSatisfy(\.isFavorite)
                barButton(allStarred ? "star.slash" : "star", allStarred ? "Remove from Starred" : "Add to Starred") {
                    model.setStarred(sel, !allStarred)
                }
                let allOffline = sel.allSatisfy { model.isPinned($0) }
                barButton(allOffline ? "icloud" : "checkmark.circle",
                          allOffline ? "Remove offline copy" : "Make available offline") {
                    model.setOffline(sel, on: !allOffline)
                }
                if sel.count == 1 {
                    barButton("link", "Copy link") { model.copyLink(sel[0]) }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(Capsule().fill(Theme.tile))
    }

    private func barButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 34, height: 34)
                .hoverBackground(selected: false, cornerRadius: 17, hoverColor: Theme.itemHover)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct Banner: View {
    let icon: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.banner))
    }
}

struct TrashBanner: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        Banner(icon: "info.circle",
               text: "Items in trash can be restored until you delete them forever.",
               actionTitle: model.items.isEmpty ? nil : "Empty trash") {
            model.dialog = PendingDialog(kind: .emptyTrash)
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.tile).frame(width: 120, height: 120)
                Image(systemName: icon).font(.system(size: 46, weight: .light)).foregroundStyle(Theme.accent)
            }
            Text(title).font(.system(size: 20)).foregroundStyle(Theme.textPrimary)
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

struct DropOverlay: View {
    let folderName: String

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.accent.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, lineWidth: 2))
                .padding(8)
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.doc")
                Text("Drop files to upload them to “\(folderName)”")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Capsule().fill(Color(hex: 0x0B57D0)))
            .padding(.bottom, 32)
        }
        .allowsHitTesting(false)
    }
}
