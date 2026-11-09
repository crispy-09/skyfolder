import SwiftUI
import AppKit

/// Drive-style palette with light/dark variants.
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let background = dynamic(0xF8FAFD, 0x1B1B1F)
    static let surface = dynamic(0xFFFFFF, 0x131314)
    static let searchField = dynamic(0xE9EEF6, 0x282A2C)
    static let searchFieldFocused = dynamic(0xFFFFFF, 0x37393B)
    static let navSelected = dynamic(0xC2E7FF, 0x004A77)
    static let navHover = dynamic(0xE8EBEE, 0x2C2D2F)
    static let itemSelected = dynamic(0xC2E7FF, 0x004A77)
    static let itemHover = dynamic(0xE1E5EA, 0x2A2B2D)
    static let tile = dynamic(0xF0F4F9, 0x1F2022)
    static let chip = dynamic(0xFFFFFF, 0x131314)
    static let chipBorder = dynamic(0x747775, 0x8E918F)
    static let divider = dynamic(0xDDE3EA, 0x333537)
    static let textPrimary = dynamic(0x1F1F1F, 0xE3E3E3)
    static let textSecondary = dynamic(0x444746, 0xC4C7C5)
    static let accent = dynamic(0x0B57D0, 0xA8C7FA)
    static let newButton = dynamic(0xFFFFFF, 0x37393B)
    static let toast = dynamic(0x303030, 0xE3E3E3)
    static let toastText = dynamic(0xF2F2F2, 0x1F1F1F)
    static let toastAction = dynamic(0xA8C7FA, 0x0B57D0)
    static let progressTrack = dynamic(0xD3E3FD, 0x3C4043)
    static let banner = dynamic(0xE8F0FE, 0x1E2A3A)
    static let danger = dynamic(0xB3261E, 0xF2B8B5)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// Hover highlight helper.
struct HoverBackground: ViewModifier {
    var selected: Bool
    var cornerRadius: CGFloat
    var selectedColor: Color = Theme.itemSelected
    var hoverColor: Color = Theme.itemHover
    var baseColor: Color = .clear
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? selectedColor : (hovering ? hoverColor : baseColor))
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverBackground(selected: Bool, cornerRadius: CGFloat, selectedColor: Color = Theme.itemSelected,
                         hoverColor: Color = Theme.itemHover, baseColor: Color = .clear) -> some View {
        modifier(HoverBackground(selected: selected, cornerRadius: cornerRadius, selectedColor: selectedColor,
                                 hoverColor: hoverColor, baseColor: baseColor))
    }
}
