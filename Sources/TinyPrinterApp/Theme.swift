import AppKit
import SwiftUI

// Look & feel shared by every window: the coral-pink of the app icon, tinted tiles, soft cards.

extension Color {
    /// #F2609A — the pink end of the icon gradient.
    static let brand = Color(red: 0.949, green: 0.376, blue: 0.604)
    /// #FF8A8A — the coral middle of the icon gradient.
    static let brandCoral = Color(red: 1.0, green: 0.541, blue: 0.541)
    /// #FFC58F — the peach start of the icon gradient.
    static let brandPeach = Color(red: 1.0, green: 0.773, blue: 0.561)

    /// Warm light grey of the canvas in light mode; tiles reuse it so the galleries match the desk.
    static let deskLight = Color(red: 0.953, green: 0.937, blue: 0.929)

    static let brandGradient = LinearGradient(colors: [.brandPeach, .brandCoral, .brand],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension EditorTab {
    var tint: Color {
        switch self {
        case .cards: return .brand
        case .text: return .orange
        case .qr: return .indigo
        case .photo: return .teal
        }
    }
}

extension AppModel.PrinterTone {
    var color: Color {
        switch self {
        case .ok: return .green
        case .busy: return .orange
        case .problem: return .red
        case .off: return .secondary
        case .virtual: return .purple
        }
    }
}

/// A rounded square with a white glyph, like the icons in System Settings.
struct IconTile: View {
    let systemName: String
    var tint: Color = .brand
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Soft rounded panel used for the inspector blocks that are not plain form rows.
struct Panel<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// The status dot: steady when idle, softly pulsing while something is going on.
struct StatusDot: View {
    let tone: AppModel.PrinterTone
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .overlay {
                if tone == .busy {
                    Circle().stroke(tone.color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                }
            }
    }
}

/// Bottom-centre notification capsule.
struct ToastView: View {
    let text: String
    var isError = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(iconColor)
            Text(text).lineLimit(2)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var icon: String { isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill" }
    private var iconColor: Color { isError ? .orange : .green }
}

/// "Section" title used inside custom (non-Form) inspector pages.
struct BlockTitle: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Selectable chip, used for AI styles and other short choices.
struct Chip: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.caption) }
                Text(title).lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(Color.brand.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.brand.opacity(0.7) : .clear, lineWidth: 1))
            .foregroundStyle(selected ? Color.brand : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Simple flow layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

// MARK: - Appearance

/// Light / dark choice of the app itself, independent of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Как в системе")
        case .light: return String(localized: "Светлое")
        case .dark: return String(localized: "Тёмное")
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static let storageKey = "ui.appearance"

    static var stored: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    @MainActor func apply() { NSApp.appearance = nsAppearance }
}
