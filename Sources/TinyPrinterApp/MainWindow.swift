import AppKit
import SwiftUI
import TinyPrinterKit

// Main window: modes on the left, the paper in the middle, the controls of the mode on the right.

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("ui.inspector") private var showInspector = true
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 236, ideal: 250, max: 320)
        } detail: {
            PreviewCanvas()
                .navigationTitle(model.tab.title)
                .navigationSubtitle(sizeLine)
                .inspector(isPresented: $showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 340, ideal: 380, max: 500)
                }
                .toolbar {
                    printItem
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation { showInspector.toggle() }
                        } label: {
                            Label(showInspector ? "Скрыть настройки макета" : "Показать настройки макета", systemImage: "sidebar.trailing")
                        }
                        .help("Настройки макета (⌃⌘I)")
                    }
                }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .tint(.brand)
        .onChange(of: appearance, initial: true) { _, v in v.apply() }
    }

    /// The print button draws its own capsule, so on macOS 26+ the toolbar must not add glass around it.
    @ToolbarContentBuilder private var printItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { PrintButton() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { PrintButton() }
        }
    }

    private var sizeLine: String {
        guard let bm = model.preview, bm.height > 0, bm.blackRatio > 0 else { return "57 мм" }
        let mm = Int(Units.mm(dots: bm.height).rounded())
        let total = model.copies > 1 ? " · \(model.copies) шт. = \(mm * model.copies) мм" : ""
        return "57 × \(mm) мм" + total
    }
}

// MARK: - Print button

struct PrintButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.printCurrent()
        } label: {
            HStack(spacing: 6) {
                if case .printing = model.printer.state {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "printer.fill")
                }
                Text(title)
            }
        }
        .buttonStyle(BrandButtonStyle())
        .disabled(model.busy || !canPrint)
        .help("Напечатать (⌘P)")
    }

    private var canPrint: Bool {
        guard let bm = model.preview else { return false }
        return bm.height > 0 && bm.blackRatio > 0
    }

    private var title: String {
        if case .printing(let p) = model.printer.state { return "\(Int(p * 100))%" }
        if model.busy { return "Печать…" }
        return model.copies > 1 ? "Печать × \(model.copies)" : "Печать"
    }
}

/// Capsule filled with the icon gradient. Drawn by hand because macOS 26+ toolbars render
/// `.borderedProminent` as untinted glass.
struct BrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(LinearGradient(colors: [.brandCoral, .brand], startPoint: .leading, endPoint: .trailing)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: Color.brand.opacity(isEnabled ? 0.35 : 0), radius: 6, y: 2)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.tab) {
            Section("Создать") {
                ForEach(EditorTab.allCases) { tab in
                    HStack(spacing: 10) {
                        IconTile(systemName: tab.icon, tint: tab.tint, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.title).font(.body.weight(.medium))
                            Text(tab.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(tab)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PrinterCard().padding(10)
        }
    }
}

/// The printer at the bottom of the sidebar; click for quick controls.
struct PrinterCard: View {
    @EnvironmentObject var model: AppModel
    @State private var showPopover = false
    @State private var hover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    IconTile(systemName: model.output == .virtual ? "doc.on.doc.fill" : "printer.fill",
                             tint: model.output == .virtual ? .purple : .gray, size: 32)
                    StatusDot(tone: model.printerTone, size: 10)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.printerTitle).font(.callout.weight(.medium)).lineLimit(1)
                    if let d = model.printerDetail {
                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let b = model.printer.status.battery, model.output == .bluetooth {
                    BatteryBadge(level: b)
                }
                Image(systemName: "chevron.up").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.background.opacity(hover ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            PrinterPopover().environmentObject(model)
        }
        .help("Принтер")
    }
}

struct BatteryBadge: View {
    let level: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text("\(level)%").monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(level <= 15 ? .red : .secondary)
    }

    private var symbol: String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct PrinterPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.tab") private var settingsTab: SettingsTab = .printer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemName: model.output == .virtual ? "doc.on.doc.fill" : "printer.fill",
                         tint: model.output == .virtual ? .purple : model.printerTone == .ok ? .green : .gray, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusDot(tone: model.printerTone)
                        Text(model.printerTitle).font(.headline)
                    }
                    if let d = model.printerDetail {
                        Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let b = model.printer.status.battery, model.output == .bluetooth {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Заряд"); Spacer(); Text("\(b)%").monospacedDigit() }.font(.caption)
                    ProgressView(value: Double(b), total: 100).tint(b <= 15 ? .red : .green)
                }
            }

            HStack {
                if model.output == .virtual {
                    Button("Открыть папку") { NSWorkspace.shared.open(AppModel.virtualDir) }
                } else if model.printer.isConnected {
                    Button("Отключить") { model.printer.disconnect() }
                } else {
                    Button("Подключить") { model.connectPrinter() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.printer.state.isBusy)
                }
                Button("Тестовая печать") { model.testPrint() }.disabled(model.busy)
            }

            Divider()

            Picker("Куда печатать", selection: $model.output) {
                Text("Bluetooth").tag(OutputMode.bluetooth)
                Text("PNG в папку").tag(OutputMode.virtual)
            }
            Picker("Плотность", selection: $model.settings.density) {
                ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)

            Divider()

            Button {
                settingsTab = .printer
                openSettings()
            } label: {
                Label("Настройки принтера…", systemImage: "gearshape")
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.tab {
            case .cards: CardInspector()
            case .text: TextEditorView()
            case .qr: QREditorView()
            case .photo: PhotoEditorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct InspectorHeader: View {
    let tab: EditorTab

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: tab.icon, tint: tab.tint, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title).font(.title3.weight(.semibold))
                Text(tab.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Form pages in the inspector share this frame: header on top, grouped form below.
struct InspectorForm<Content: View>: View {
    let tab: EditorTab
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(tab: tab)
            Divider()
            Form { content }
                .formStyle(.grouped)
        }
    }
}
