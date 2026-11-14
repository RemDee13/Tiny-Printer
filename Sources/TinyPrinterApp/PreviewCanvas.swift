import AppKit
import SwiftUI
import TinyPrinterKit
import UniformTypeIdentifiers

// The centre of the window: the label as it will come out of the printer.

struct PreviewCanvas: View {
    @EnvironmentObject var model: AppModel
    /// 0 = fit the paper to the width of the canvas.
    @AppStorage("ui.zoom2") private var zoom: Double = 0
    @State private var canvasWidth: CGFloat = 500
    @AppStorage("cards.pane") private var cardPane: CardPane = .templates
    @State private var dropTargeted = false

    private static let zoomSteps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    var body: some View {
        ZStack {
            CanvasBackground()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Group {
                        if let bm = model.preview, bm.height > 0, bm.blackRatio > 0, let cg = bm.cgImage() {
                            PaperStrip(image: cg, widthDots: bm.width, heightDots: bm.height, zoom: effectiveZoom,
                                       receipt: model.settings.paper == .receipt)
                                .padding(.top, 24)
                        } else {
                            emptyState
                                .frame(width: max(320, geo.size.width - 80))
                                .padding(.top, max(40, geo.size.height * 0.18))
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 90)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .top)
                }
                .onAppear { canvasWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in canvasWidth = w }
            }

            if model.aiBusy && model.tab == .cards {
                AIBusyCard(provider: model.ai.provider, modelName: model.ai.model(for: model.ai.provider))
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .background(Color.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        Label(model.tab == .cards ? "Картинка для открытки" : "Открыть фото", systemImage: "square.and.arrow.down")
                            .font(.title3.weight(.medium))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) { bottomBar }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(text: toast)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .animation(.easeInOut(duration: 0.15), value: dropTargeted)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "minus").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .disabled(effectiveZoom <= Self.zoomSteps.first! + 0.001)
                    .help("Уменьшить")
                Menu {
                    Button("По ширине окна") { zoom = 0 }
                    Divider()
                    ForEach(Self.zoomSteps, id: \.self) { z in
                        Button("\(Int(z * 100))%") { zoom = z }
                    }
                } label: {
                    Text(zoom == 0 ? "Вписать" : "\(Int(effectiveZoom * 100))%").monospacedDigit().frame(minWidth: 50)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                Button { step(1) } label: { Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .disabled(effectiveZoom >= Self.zoomSteps.last! - 0.001)
                    .help("Увеличить")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
            .help("Масштаб")

            Spacer()

            HStack(spacing: 12) {
                Picker("Бумага", selection: $model.settings.paper) {
                    Text("Стикер").tag(PrintSettings.Paper.sticker)
                    Text("Чек").tag(PrintSettings.Paper.receipt)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Бумага в принтере: самоклейка или чековая лента")

                Divider().frame(height: 16)

                HStack(spacing: 6) {
                    Image(systemName: "square.on.square").foregroundStyle(.secondary)
                    Text("\(model.copies)").monospacedDigit().frame(minWidth: 16)
                    Stepper("Копий", value: $model.copies, in: 1...50).labelsHidden()
                }
                .help("Сколько копий напечатать")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        }
        .controlSize(.small)
        .padding(12)
    }

    /// Paper (with its unprinted edges and the printer slot) fitted into the canvas, 40%…150%.
    private var effectiveZoom: Double {
        if zoom > 0 { return zoom }
        let dots = Double((model.preview?.width ?? 384) + 2 * Units.dots(mm: 4.5) + 28)
        return min(1.5, max(0.4, (Double(canvasWidth) - 56) / dots))
    }

    private func step(_ d: Int) {
        let z = effectiveZoom
        let next = d > 0 ? Self.zoomSteps.first { $0 > z + 0.01 } : Self.zoomSteps.last { $0 < z - 0.01 }
        zoom = next ?? (d > 0 ? Self.zoomSteps.last! : Self.zoomSteps.first!)
    }

    // MARK: Empty states

    @ViewBuilder private var emptyState: some View {
        switch model.tab {
        case .cards:
            ContentUnavailableView {
                Label("Чистый лист", systemImage: "gift")
            } description: {
                Text("Выберите шаблон, напишите пару слов или нарисуйте картинку с AI.")
            } actions: {
                HStack {
                    Button("Шаблоны") { cardPane = .templates }
                    Button {
                        cardPane = .picture
                    } label: { Label("Нарисовать с AI", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent)
                }
                .fixedSize()
            }
        case .photo:
            ContentUnavailableView {
                Label("Фото не выбрано", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Перетащите фото сюда или вставьте из буфера обмена — приложение переведёт его в точки для термопечати.")
            } actions: {
                HStack {
                    Button("Вставить") { PhotoEditorView.pasteImage(into: model) }
                    Button("Выбрать фото…") { PhotoEditorView.pickImage(into: model) }
                        .buttonStyle(.borderedProminent)
                }
                .fixedSize()
            }
        case .text:
            ContentUnavailableView("Здесь появится надпись", systemImage: "character.cursor.ibeam",
                                   description: Text("Напишите текст в панели справа."))
        case .qr:
            ContentUnavailableView("Нет содержимого", systemImage: "qrcode",
                                   description: Text("Вставьте ссылку или текст в панели справа."))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { AppModel.shared.open(urls: [url]) } }
            }
            return true
        }
        for p in providers where p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                DispatchQueue.main.async {
                    let m = AppModel.shared
                    if m.tab == .cards { m.setCardImage(cg, name: "Перетащенная картинка") } else {
                        m.photoImage = cg; m.photoName = "Перетащенная картинка"; m.tab = .photo
                    }
                }
            }
            return true
        }
        return false
    }
}

// MARK: - Paper

/// The strip of paper coming out of the printer slot, with a torn bottom edge.
struct PaperStrip: View {
    @Environment(\.colorScheme) private var scheme
    let image: CGImage
    let widthDots: Int
    let heightDots: Int
    let zoom: Double
    var receipt = false

    var body: some View {
        let z = CGFloat(zoom)
        let margin = CGFloat(Units.dots(mm: 4.5)) * z          // unprinted edge of 57 mm paper
        let paperWidth = CGFloat(widthDots) * z + margin * 2
        let tooth = max(4, 5 * z)

        VStack(spacing: 0) {
            PrinterSlot(width: paperWidth + 28 * z, scale: z)
                .zIndex(1)
            Image(decorative: image, scale: 1)
                .interpolation(zoom >= 1 ? .none : .medium)
                .resizable()
                .frame(width: CGFloat(widthDots) * z, height: CGFloat(heightDots) * z)
                .padding(.horizontal, margin)
                .padding(.top, 12 * z)
                .padding(.bottom, 12 * z + tooth)
                .background {
                    TornPaper(tooth: tooth)
                        .fill(receipt ? Color(white: 0.985) : .white)
                        .shadow(color: scheme == .dark ? .black.opacity(0.35) : Color(red: 0.35, green: 0.2, blue: 0.25).opacity(0.18),
                                radius: 10 * z, y: 5 * z)
                }
                .overlay(alignment: .top) {
                    // The paper darkens where it disappears into the slot.
                    LinearGradient(colors: [.black.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14 * z)
                }
                .padding(.top, -8 * z)
        }
        .accessibilityLabel("Превью печати")
    }
}

/// The dark mouth of the printer the paper comes out of.
struct PrinterSlot: View {
    let width: CGFloat
    let scale: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: 20 * scale)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: width - 18 * scale, height: 4 * scale)
                    .padding(.bottom, 5 * scale)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 6 * scale, y: 3 * scale)
    }
}

/// Rectangle with a zig-zag bottom edge, like paper torn off at the tear bar.
struct TornPaper: Shape {
    var tooth: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - tooth))
        let n = max(4, Int((r.width / (tooth * 2.2)).rounded()))
        let step = r.width / CGFloat(n)
        for i in stride(from: n, to: 0, by: -1) {
            let x = r.minX + CGFloat(i) * step
            p.addLine(to: CGPoint(x: x - step / 2, y: r.maxY))
            p.addLine(to: CGPoint(x: x - step, y: r.maxY - tooth))
        }
        p.closeSubpath()
        return p
    }
}

/// Dotted "drafting table" background with a faint warm glow from the printer.
struct CanvasBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if scheme == .dark {
                Color(nsColor: .underPageBackgroundColor)
                RadialGradient(colors: [Color.brand.opacity(0.10), .clear], center: .top, startRadius: 0, endRadius: 520)
            } else {
                // Warm paper-grey desk: light enough to feel airy, dark enough for white paper to stand out.
                LinearGradient(colors: [Color.deskLight, Color(red: 0.918, green: 0.906, blue: 0.910)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.brandPeach.opacity(0.28), Color.brand.opacity(0.06), .clear],
                               center: .top, startRadius: 0, endRadius: 560)
            }
            SwiftUI.Canvas { ctx, size in
                let step: CGFloat = 20
                var dots = Path()
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        dots.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                        x += step
                    }
                    y += step
                }
                ctx.fill(dots, with: .color(scheme == .dark ? .white.opacity(0.10) : Color(red: 0.45, green: 0.32, blue: 0.36).opacity(0.16)))
            }
        }
        .ignoresSafeArea()
    }
}

struct AIBusyCard: View {
    let provider: AIProvider
    let modelName: String
    @State private var started = Date()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.brandGradient)
                .symbolEffect(.pulse, options: .repeating)
            Text("Рисую картинку…").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(Int(ctx.date.timeIntervalSince(started))) с · обычно 15–40 с")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("\(provider.shortTitle) · \(modelName)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .onAppear { started = Date() }
    }
}
