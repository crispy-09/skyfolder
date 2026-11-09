import SwiftUI

struct DriveView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TopBar()
            HStack(alignment: .top, spacing: 0) {
                SidebarView()
                    .frame(width: 256)
                HStack(spacing: 0) {
                    BrowserView()
                    if model.showDetails {
                        Divider().overlay(Theme.divider)
                        DetailsPanel()
                            .frame(width: 320)
                            .transition(.move(edge: .trailing))
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottomLeading) { ToastView().padding(24) }
        .overlay(alignment: .bottomTrailing) { TransfersPanel().padding(24) }
        .animation(.easeOut(duration: 0.18), value: model.showDetails)
        .modifier(DialogsModifier())
        .sheet(item: Binding(get: { model.moveTargets.map { MoveRequest(items: $0) } },
                             set: { if $0 == nil { model.moveTargets = nil } })) { req in
            MoveSheet(targets: req.items)
        }
    }
}

struct MoveRequest: Identifiable {
    let id = UUID()
    let items: [RemoteItem]
}

struct TopBar: View {
    @Environment(DriveModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                AppLogo(size: 34)
                Text("Skyfolder")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 256 - 80 - 16, alignment: .leading)

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Search in Skyfolder", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit { model.search() }
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                        if case .search = model.section { model.go(.myFiles) }
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
            .frame(maxWidth: 720)
            .background(Capsule().fill(searchFocused ? Theme.searchFieldFocused : Theme.searchField))
            .shadow(color: .black.opacity(searchFocused ? 0.15 : 0), radius: 3, y: 1)

            Spacer(minLength: 0)

            if model.isLoading {
                ProgressView().controlSize(.small)
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Settings")

            AccountMenu()
        }
        .padding(.leading, 80)
        .padding(.trailing, 20)
        .frame(height: 64)
        .background(WindowDragArea())
    }
}

/// Lets the user drag the window from the custom top bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct AccountMenu: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        Menu {
            if let acc = model.account {
                Text(acc.displayName)
                Text(acc.username)
                Divider()
                Button("Open web version") { model.openWeb() }
                Button("Open in Finder") { model.openInFinder() }.disabled(!model.finderEnabled)
                Divider()
                Button("Sign out…") { model.dialog = PendingDialog(kind: .signOut) }
            }
        } label: {
            Avatar(name: model.account?.displayName ?? "?", size: 32)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 32

    private var initials: String {
        let parts = name.split(separator: " ")
        return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var color: Color {
        let palette: [UInt32] = [0x1A73E8, 0x188038, 0xD93025, 0xE37400, 0x9334E6, 0x007B83, 0xB80672]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Color(hex: palette[h % palette.count])
    }

    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white))
    }
}
