import AppKit
import SwiftUI
import TinyPrinterKit

// Inspector of the cards mode, split into four pages: templates, picture (with AI), text, look.

enum CardPane: String, CaseIterable, Identifiable {
    case templates, picture, text, style
    var id: String { rawValue }
    var title: String {
        switch self {
        case .templates: return "Шаблоны"
        case .picture: return "Картинка"
        case .text: return "Текст"
        case .style: return "Вид"
        }
    }
    var icon: String {
        switch self {
        case .templates: return "square.grid.2x2"
        case .picture: return "photo.on.rectangle.angled"
        case .text: return "textformat"
        case .style: return "paintpalette"
        }
    }
}

extension CardKind {
    var plural: String {
        switch self { case .note: return "Записки"; case .postcard: return "Открытки"; case .sticker: return "Стикеры" }
    }
}

extension AIStyle {
    var shortTitle: String {
        switch self {
        case .lineArt: return "Контур"
        case .cute: return "Милый"
        case .doodle: return "Дудл"
        case .woodcut: return "Гравюра"
        case .silhouette: return "Силуэт"
        case .tattoo: return "Тату"
        case .pixel: return "Пиксели"
        case .photo: return "Фото"
        }
    }
    var icon: String {
        switch self {
        case .lineArt: return "scribble"
        case .cute: return "face.smiling"
        case .doodle: return "pencil.tip"
        case .woodcut: return "leaf"
        case .silhouette: return "person.fill"
        case .tattoo: return "flame"
        case .pixel: return "square.grid.3x3.fill"
        case .photo: return "camera"
        }
    }
}

struct CardInspector: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("cards.pane") private var pane: CardPane = .templates

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(tab: .cards)
            PaneBar(selection: $pane, busy: model.aiBusy)
            Divider()
            switch pane {
            case .templates: TemplatesPane()
            case .picture: PicturePane()
            case .text: CardTextPane()
            case .style: CardStylePane()
            }
        }
    }
}

struct PaneBar: View {
    @Binding var selection: CardPane
    var busy = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CardPane.allCases) { p in
                let on = selection == p
                Button { selection = p } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: p.icon).font(.system(size: 15, weight: .medium)).frame(height: 18)
                            if p == .picture && busy {
                                Circle().fill(Color.brand).frame(width: 7, height: 7).offset(x: 6, y: -2)
                            }
                        }
                        Text(p.title).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(on ? Color.brand : .secondary)
                    .background(on ? Color.brand.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - Thumbnails

/// Renders every template (and frame) once, so the galleries show real prints, not icons.
@MainActor
final class CardThumbnails: ObservableObject {
    static let shared = CardThumbnails()

    @Published private(set) var presets: [String: CGImage] = [:]
    @Published private(set) var frames: [CardFrame: CGImage] = [:]
    private var started = false

    /// Stand-in pictures so that templates with a picture slot don't look empty.
    private static let symbols = ["note": "cat.fill", "birthday": "birthday.cake.fill", "thanks": "camera.macro",
                                  "love": "heart.fill", "newyear": "tree.fill", "sticker": "cat.fill", "sticker-text": "sun.max.fill"]

    func load() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            for p in CardPreset.all {
                let sample = Self.symbols[p.id].flatMap { Self.symbolImage($0) }
                if let cg = p.design.render(width: 384, image: sample).cgImage() { presets[p.id] = cg }
                await Task.yield()
            }
            for f in CardFrame.allCases {
                var d = CardDesign.blank
                d.kind = .postcard
                d.frame = f
                d.title = "Aa"
                d.titleFont = "SnellRoundhand-Black"
                d.titleSizePt = 24
                d.lengthMM = 24
                if let cg = d.render(width: 384, image: nil).cgImage() { frames[f] = cg }
                await Task.yield()
            }
        }
    }

    static func symbolImage(_ name: String, side: Int = 360) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.7, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let s = symbol.size
        let k = min(CGFloat(side) / s.width, CGFloat(side) / s.height) * 0.92
        symbol.draw(in: CGRect(x: (CGFloat(side) - s.width * k) / 2, y: (CGFloat(side) - s.height * k) / 2,
                               width: s.width * k, height: s.height * k))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

// MARK: - Templates

struct TemplatesPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var thumbs = CardThumbnails.shared
    @AppStorage("cards.preset") private var lastPreset = ""
    @State private var filter: CardKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Показать", selection: $filter) {
                    Text("Все").tag(CardKind?.none)
                    ForEach(CardKind.allCases) { Text($0.plural).tag(CardKind?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 10)], spacing: 14) {
                    if filter == nil {
                        TemplateTile(title: "Чистый лист", image: nil, placeholder: "plus", selected: lastPreset == "blank") {
                            var d = CardDesign.blank
                            d.kind = .postcard
                            model.card = d
                            lastPreset = "blank"
                        }
                    }
                    ForEach(CardPreset.all.filter { filter == nil || $0.design.kind == filter }) { p in
                        TemplateTile(title: p.title, image: thumbs.presets[p.id], selected: lastPreset == p.id) {
                            model.applyPreset(p)
                            lastPreset = p.id
                        }
                    }
                }

                Label("Шаблон меняет текст и оформление, а вашу картинку оставляет.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .onAppear { thumbs.load() }
    }
}

struct TemplateTile: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let image: CGImage?
    var placeholder: String?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(scheme == .dark ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.deskLight))
                    if let image {
                        Image(decorative: image, scale: 1)
                            .interpolation(.medium)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                            .background(.white)
                            .compositingGroup()
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
                            .padding(10)
                    } else if let placeholder {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                            .frame(width: 58, height: 84)
                            .overlay { Image(systemName: placeholder).font(.title3).foregroundStyle(.secondary) }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 136)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.brand : hover ? Color.secondary.opacity(0.4) : .clear, lineWidth: selected ? 2 : 1)
                )
                .scaleEffect(hover ? 1.02 : 1)
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.brand : .primary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: - Picture & AI

struct PicturePane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.tab") private var settingsTab: SettingsTab = .printer
    @State private var redrawCurrent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel {
                    ImageWell(image: model.cardImage, name: model.cardImageName,
                              emptyText: "Картинки нет — перетащите её на ленту или нарисуйте ниже",
                              paste: paste, pick: pick, clear: { model.setCardImage(nil, name: "") })
                }
                aiPanel
                if !model.aiHistory.isEmpty { history }
                if model.cardImage != nil { placement }
            }
            .padding(16)
        }
    }

    private var aiPanel: some View {
        let provider = model.ai.provider
        let canRedraw = model.cardImage != nil
        let idea = model.aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = model.hasKey(provider)

        return Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title3).foregroundStyle(Color.brandGradient)
                    Text("Нарисовать с AI").font(.headline)
                    Spacer()
                    Button {
                        settingsTab = .ai
                        openSettings()
                    } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .help("Ключ, модель и расходы")
                }

                TextField("Что нарисовать", text: $model.aiPrompt, prompt: Text("Например: котик спит на стопке книг"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                FlowLayout(spacing: 6) {
                    ForEach(AIStyle.allCases) { s in
                        Chip(title: s.shortTitle, systemImage: s.icon, selected: model.ai.style == s) { model.ai.style = s }
                            .help(s.title)
                    }
                }

                if canRedraw {
                    Toggle("Перерисовать текущую картинку (фото → рисунок)", isOn: $redrawCurrent)
                        .font(.callout)
                }

                Button {
                    model.generateAI(useReference: redrawCurrent && canRedraw)
                } label: {
                    HStack(spacing: 6) {
                        if model.aiBusy { ProgressView().controlSize(.small) } else { Image(systemName: "wand.and.stars") }
                        Text(model.aiBusy ? "Рисую…" : "Нарисовать")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.brand)
                .disabled(model.aiBusy || !hasKey || (idea.isEmpty && !(redrawCurrent && canRedraw)))

                if !hasKey {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                        Text("Нужен ключ API \(provider.shortTitle)").font(.callout)
                        Spacer()
                        Button("Добавить ключ…") {
                            settingsTab = .ai
                            openSettings()
                        }
                        .controlSize(.small)
                    }
                }
                if let err = model.aiError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                HStack(spacing: 6) {
                    Text("\(provider.shortTitle) · \(model.ai.model(for: provider))").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let spend = spendText {
                        Text(spend).monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var spendText: String? {
        guard !model.aiLedger.isEmpty else { return nil }
        return "всего ≈ \(AIPricing.format(model.aiSpent))"
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                BlockTitle(title: "Нарисованные раньше", systemImage: "clock")
                Button("Папка") { NSWorkspace.shared.open(AppModel.aiDir) }
                    .buttonStyle(.link).font(.caption)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 8)], spacing: 8) {
                ForEach(model.aiHistory) { item in
                    Button { model.useAIImage(item) } label: {
                        Image(nsImage: item.thumbnail)
                            .resizable().scaledToFit()
                            .padding(3)
                            .frame(width: 62, height: 62)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
                    }
                    .buttonStyle(.plain)
                    .help(item.title + (model.costRecord(for: item).map { "\n" + $0.costText + " · " + $0.model } ?? ""))
                    .contextMenu {
                        Button("Взять в открытку") { model.useAIImage(item) }
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Divider()
                        Button("В корзину", role: .destructive) { model.trashAIImage(item) }
                    }
                }
            }
        }
    }

    private var placement: some View {
        VStack(alignment: .leading, spacing: 8) {
            BlockTitle(title: "Как разместить картинку", systemImage: "rectangle.center.inset.filled")
            Panel {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Где").foregroundStyle(.secondary)
                        Picker("Где", selection: $model.card.imagePlacement) {
                            ForEach(CardImagePlacement.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Ширина").foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $model.card.imageWidthPercent, in: 20...100, step: 5)
                            Text("\(Int(model.card.imageWidthPercent))%").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    GridRow {
                        Text("Точки").foregroundStyle(.secondary)
                        Picker("Растрирование", selection: $model.card.imageDither) {
                            Text("Авто").tag(DitherMethod?.none)
                            ForEach(DitherMethod.allCases) { Text($0.title).tag(DitherMethod?.some($0)) }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Toggle("Обрезать белые поля", isOn: $model.card.imageTrim)
                    }
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.loadCardImage(url: url) }
    }

    private func paste() {
        if let img = NSImage(pasteboard: .general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            model.setCardImage(cg, name: "Из буфера обмена")
        } else {
            model.show("В буфере нет картинки")
        }
    }
}

// MARK: - Text

struct CardTextPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Заголовок") {
                WideField(title: "Текст заголовка", text: $model.card.title, prompt: "С днём рождения!", lines: 1...3)
                CardFontPicker(title: "Шрифт", name: $model.card.titleFont)
                SliderRow(title: "Размер", value: $model.card.titleSizePt, range: 8...60) { "\(Int($0)) pt" }
                Picker("Стиль", selection: $model.card.titleStyle) {
                    ForEach(CardTitleStyle.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Текст") {
                TextBox(text: $model.card.message, placeholder: "Пара тёплых слов…", minHeight: 76)
                CardFontPicker(title: "Шрифт", name: $model.card.messageFont)
                SliderRow(title: "Размер", value: $model.card.messageSizePt, range: 6...40) { "\(Int($0)) pt" }
                AlignPicker(align: $model.card.align)
            }
            Section("Подпись") {
                WideField(title: "Внизу, мелко", text: $model.card.signature, prompt: "— с любовью, мама")
            }
        }
        .formStyle(.grouped)
    }
}

struct CardFontPicker: View {
    let title: String
    @Binding var name: String

    var body: some View {
        Picker(title, selection: $name) {
            ForEach(CardFonts.all, id: \.name) { f in Text(f.title).tag(f.name) }
            if !CardFonts.all.contains(where: { $0.name == name }) { Text(name).tag(name) }
        }
    }
}

// MARK: - Look

struct CardStylePane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var thumbs = CardThumbnails.shared

    var body: some View {
        Form {
            Section {
                Picker("Тип", selection: Binding(get: { model.card.kind }, set: { model.card = model.card.switched(to: $0) })) {
                    ForEach(CardKind.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(kindHint).font(.caption).foregroundStyle(.secondary)
            }

            Section("Рамка") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)], spacing: 8) {
                    ForEach(CardFrame.allCases) { f in
                        FrameTile(frame: f, image: thumbs.frames[f], selected: model.card.frame == f) { model.card.frame = f }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Украшения") {
                Picker("Узор", selection: $model.card.ornament) {
                    ForEach(CardOrnament.allCases) { Text($0.title).tag($0) }
                }
                if model.card.ornament != .none {
                    Toggle("Повторить внизу", isOn: $model.card.ornamentBottom)
                }
                Toggle("Полоска скотча сверху", isOn: $model.card.tape)
            }

            Section("Бумага") {
                Toggle("Линейки для письма", isOn: $model.card.lined)
                if model.card.lined {
                    Stepper("Пустых строк: \(model.card.blankLines)", value: $model.card.blankLines, in: 0...15)
                }
                Toggle("Контур для вырезания", isOn: $model.card.cutOutline)
            }

            Section("Размер") {
                MMField(title: "Длина", value: $model.card.lengthMM)
                MMField(title: "Поля", value: $model.card.paddingMM, range: 0...15, zeroMeansAuto: false)
                Stepper("Одинаковых подряд: \(model.card.repeatCount)", value: $model.card.repeatCount, in: 1...20)
            }
        }
        .formStyle(.grouped)
        .onAppear { thumbs.load() }
    }

    private var kindHint: String {
        switch model.card.kind {
        case .note: return "Записка: скотч сверху, линейки, текст слева — как листок для холодильника."
        case .postcard: return "Открытка: рамка, украшения, заголовок по центру."
        case .sticker: return "Стикер: картинка во всю ширину и контур, по которому удобно вырезать."
        }
    }
}

struct FrameTile: View {
    let frame: CardFrame
    let image: CGImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white)
                if let image {
                    Image(decorative: image, scale: 1).interpolation(.medium).resizable().scaledToFit().padding(4)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.brand : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(frame.title)
    }
}
