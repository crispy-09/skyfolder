import SwiftUI

// MARK: Details panel

struct DetailsPanel: View {
    @Environment(DriveModel.self) private var model
    @State private var thumb: NSImage?

    var body: some View {
        let sel = model.selectedItems
        let item: RemoteItem? = sel.count == 1 ? sel[0] : (sel.isEmpty ? model.currentFolder : nil)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let item { FileIconView(item: item, size: 22) }
                Text(item.map { $0.id == model.account?.rootID ? "My Files" : $0.name } ?? "\(sel.count) items selected")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer()
                Button { model.showDetails = false } label: {
                    Image(systemName: "xmark").foregroundStyle(Theme.textSecondary).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                if let item {
                    VStack(alignment: .leading, spacing: 18) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(Theme.tile)
                            if let thumb {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(8)
                            } else {
                                FileIconView(item: item, size: 72)
                            }
                        }
                        .frame(height: 180)

                        Text("File details").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        VStack(alignment: .leading, spacing: 16) {
                            detail("Type", FileKind.of(item).typeName + (item.isFolder ? "" : item.fileExtension.isEmpty ? "" : " (.\(item.fileExtension))"))
                            if !item.isFolder || item.size > 0 { detail("Size", item.size.formattedBytes) }
                            if model.section == .trash {
                                detail("Original location", item.originalLocation ?? "—")
                                if let d = item.deletedAt { detail("Deleted", d.formatted(date: .long, time: .shortened)) }
                            } else {
                                detail("Location", item.parentPath.map { $0.isEmpty ? "My Files" : "My Files/" + $0 } ?? "—")
                                detail("Owner", "me")
                                if let d = item.modified { detail("Modified", d.formatted(date: .long, time: .shortened)) }
                                detail("On this Mac", model.isPinned(item) ? "Always kept offline"
                                       : model.isOffline(item) ? "Downloaded" : "Online-only (downloads when opened)")
                                if item.isFavorite { detail("Starred", "Yes") }
                            }
                        }
                        if model.section != .trash && item.id != model.account?.rootID {
                            HStack {
                                Button(model.isPinned(item) ? "Remove offline copy" : "Make available offline") {
                                    model.setOffline([item], on: !model.isPinned(item))
                                }
                                Button("Open in web") { model.openWeb(item) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                } else {
                    Text("Select a single item to see its details.")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(20)
                }
            }
        }
        .task(id: item?.id ?? "") {
            thumb = nil
            guard let item, ThumbnailLoader.canThumbnail(item), let client = model.client else { return }
            thumb = await ThumbnailLoader.shared.thumbnail(for: item, client: client)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text(value).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
        }
    }
}

// MARK: Toast

struct ToastView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if let t = model.toast {
            HStack(spacing: 16) {
                Text(t.message).font(.system(size: 14)).foregroundStyle(Theme.toastText).lineLimit(2)
                if let title = t.actionTitle, let action = t.action {
                    Button(title) { model.toast = nil; action() }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.toastAction)
                }
                Button { model.toast = nil } label: {
                    Image(systemName: "xmark").foregroundStyle(Theme.toastText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.toast))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}

// MARK: Transfers

struct TransfersPanel: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if !model.transfers.isEmpty {
            let running = model.transfers.filter { $0.state == .running }
            let uploads = model.transfers.filter { $0.kind == .upload }
            let title: String = {
                if !running.isEmpty {
                    let verb = running.allSatisfy { $0.kind == .upload } ? "Uploading" :
                               running.allSatisfy { $0.kind == .download } ? "Downloading" : "Transferring"
                    return "\(verb) \(running.count) item\(running.count == 1 ? "" : "s")"
                }
                let failed = model.transfers.filter { if case .failed = $0.state { return true }; return false }.count
                if failed > 0 { return "\(failed) transfer\(failed == 1 ? "" : "s") failed" }
                let n = model.transfers.count
                return uploads.count == n ? "\(n) upload\(n == 1 ? "" : "s") complete"
                     : "\(n) transfer\(n == 1 ? "" : "s") complete"
            }()

            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { model.transfersCollapsed.toggle() } label: {
                        Image(systemName: model.transfersCollapsed ? "chevron.up" : "chevron.down")
                            .frame(width: 28, height: 28)
                    }.buttonStyle(.plain)
                    Button {
                        for t in running { t.progress.cancel() }
                        model.transfers.removeAll()
                    } label: {
                        Image(systemName: "xmark").frame(width: 28, height: 28)
                    }.buttonStyle(.plain)
                    .help(running.isEmpty ? "Close" : "Cancel all")
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .frame(height: 50)
                .background(Theme.tile)

                if !model.transfersCollapsed {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.transfers) { t in TransferRow(transfer: t) }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
            .frame(width: 360)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.isFolder ? "folder.fill" : (transfer.kind == .upload ? "doc" : "arrow.down.doc"))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20)
            Text(transfer.name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            status
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var status: some View {
        switch transfer.state {
        case .running:
            if hovering {
                Button { transfer.progress.cancel(); transfer.state = .cancelled } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain).help("Cancel")
            } else {
                ZStack {
                    Circle().stroke(Theme.progressTrack, lineWidth: 3)
                    Circle().trim(from: 0, to: max(0.03, transfer.fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 20, height: 20)
                .animation(.linear(duration: 0.2), value: transfer.fraction)
            }
        case .done:
            if let url = transfer.resultURL, hovering {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 13, weight: .medium))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x188038))
            }
        case .failed(let msg):
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger).help(msg)
        case .cancelled:
            Text("Canceled").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: Dialogs

struct DialogsModifier: ViewModifier {
    @Environment(DriveModel.self) private var model
    @State private var text = ""

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(alertTitle, isPresented: Binding(get: { model.dialog != nil }, set: { if !$0 { model.dialog = nil } }),
                   presenting: model.dialog) { d in
                switch d.kind {
                case .newFolder:
                    TextField("Folder name", text: $text)
                    Button("Cancel", role: .cancel) {}
                    Button("Create") { model.createFolder(named: text) }
                case .rename(let item):
                    TextField("Name", text: $text)
                    Button("Cancel", role: .cancel) {}
                    Button("OK") { model.rename(item, to: text) }
                case .emptyTrash:
                    Button("Cancel", role: .cancel) {}
                    Button("Empty trash", role: .destructive) { model.emptyTrash() }
                case .deleteForever(let items):
                    Button("Cancel", role: .cancel) {}
                    Button("Delete forever", role: .destructive) { model.deleteForever(items) }
                case .signOut:
                    Button("Cancel", role: .cancel) {}
                    Button("Sign out", role: .destructive) { model.signOut() }
                }
            } message: { d in
                switch d.kind {
                case .emptyTrash: Text("All items in the trash will be deleted forever and you won't be able to restore them.")
                case .deleteForever(let items):
                    Text(items.count == 1 ? "“\(items[0].name)” will be deleted forever and you won't be able to restore it."
                                          : "\(items.count) items will be deleted forever and you won't be able to restore them.")
                case .signOut:
                    Text("Skyfolder will be removed from Finder and offline copies on this Mac will be deleted. Your files stay on the server.")
                default: EmptyView()
                }
            }
            .onChange(of: model.dialog?.id) {
                switch model.dialog?.kind {
                case .newFolder: text = "Untitled folder"
                case .rename(let item): text = item.name
                default: break
                }
            }
    }

    private var alertTitle: String {
        switch model.dialog?.kind {
        case .newFolder: return "New folder"
        case .rename: return "Rename"
        case .emptyTrash: return "Delete forever?"
        case .deleteForever: return "Delete forever?"
        case .signOut: return "Sign out of OpenCloud?"
        case nil: return ""
        }
    }
}

// MARK: Move sheet

struct MoveSheet: View {
    @Environment(DriveModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let targets: [RemoteItem]

    @State private var path: String = ""
    @State private var folder: RemoteItem?
    @State private var subfolders: [RemoteItem] = []
    @State private var loading = false
    @State private var selected: RemoteItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(targets.count == 1 ? "Move “\(targets[0].name)”" : "Move \(targets.count) items")
                .font(.system(size: 18))
                .padding(.bottom, 10)
            HStack(spacing: 6) {
                Button { navigate((path as NSString).deletingLastPathComponent) } label: {
                    Image(systemName: "arrow.left")
                }
                .buttonStyle(.plain)
                .disabled(path.isEmpty)
                Text(path.isEmpty ? "My Files" : (path as NSString).lastPathComponent)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 8)
            Divider()
            List(subfolders, selection: Binding(get: { selected?.id }, set: { id in selected = subfolders.first { $0.id == id } })) { f in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.textSecondary)
                    Text(f.name)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { navigate(f.path ?? "") }
                .tag(f.id)
                .disabled(targets.contains { $0.id == f.id })
            }
            .listStyle(.plain)
            .frame(height: 300)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selected == nil ? "Move here" : "Move") {
                    if let dest = selected ?? folder {
                        model.move(targets, to: dest)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((selected ?? folder) == nil)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { navigate(targets.first?.parentPath ?? "") }
    }

    private func navigate(_ p: String) {
        guard let client = model.client else { return }
        let clean = p == "/" ? "" : p
        loading = true
        selected = nil
        Task {
            if let listing = try? await client.listFolder(path: clean) {
                path = clean
                folder = listing.folder
                subfolders = listing.children.filter(\.isFolder)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            loading = false
        }
    }
}
