import AppKit
import SwiftUI
import TinyPrinterKit

// Inspector pages of the simple modes (text, QR, photo) and the controls they share.

// MARK: - Shared controls

struct MMField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...500
    var zeroMeansAuto = true

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 56).multilineTextAlignment(.trailing)
                Stepper("", value: $value, in: range, step: 5).labelsHidden()
                Text(zeroMeansAuto && value == 0 ? "мм (авто)" : "мм").foregroundStyle(.secondary)
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }
        }
    }
}

struct AlignPicker: View {
    @Binding var align: TextAlign

    var body: some View {
        Picker("Выравнивание", selection: $align) {
            Image(systemName: "text.alignleft").tag(TextAlign.left)
            Image(systemName: "text.aligncenter").tag(TextAlign.center)
            Image(systemName: "text.alignright").tag(TextAlign.right)
        }
        .pickerStyle(.segmented)
    }
}

/// Full-width text field for a grouped form (the default style squeezes the text to the right).
struct WideField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var lines: ClosedRange<Int> = 1...1

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            TextField(title, text: $text, prompt: Text(prompt), axis: lines.upperBound > 1 ? .vertical : .horizontal)
                .labelsHidden()
                .lineLimit(lines)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }
}

/// Multi-line text box that looks at home inside a grouped form.
struct TextBox: View {
    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 80
    var font: Font = .system(size: 14)

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).font(font).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct FontPicker: View {
    @Binding var name: String
    static let families: [String] = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Picker("Шрифт", selection: $name) {
            Text("Системный (SF)").tag("")
            Divider()
            ForEach(Self.families, id: \.self) { Text($0).tag($0) }
        }
    }
}

/// Thumbnail + name + actions for the picture of a mode.
struct ImageWell: View {
    let image: CGImage?
    let name: String
    let emptyText: String
    let paste: () -> Void
    let pick: () -> Void
    var clear: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(image == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.white))
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 6) {
                Text(image == nil ? emptyText : name)
                    .lineLimit(2).truncationMode(.middle)
                    .foregroundStyle(image == nil ? .secondary : .primary)
                HStack(spacing: 6) {
                    Button("Вставить", action: paste)
                    Button("Файл…", action: pick)
                    if image != nil, let clear {
                        Button(role: .destructive, action: clear) { Image(systemName: "trash") }
                            .help("Убрать картинку")
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Text

struct TextEditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InspectorForm(tab: .text) {
            Section("Текст") {
                TextBox(text: $model.text.text, placeholder: String(localized: "Например: Специи"), minHeight: 90, font: .system(size: 15))
            }
            Section("Шрифт") {
                FontPicker(name: $model.text.fontName)
                SliderRow(title: String(localized: "Размер"), value: $model.text.sizePt, range: 6...160) { "\(Int($0)) pt" }
                Toggle("Жирный", isOn: $model.text.bold)
                AlignPicker(align: $model.text.align)
            }
            Section("Оформление") {
                Toggle("Рамка", isOn: $model.text.border)
                Toggle("Белым по чёрному", isOn: $model.text.invert)
            }
            Section {
                Toggle("Вдоль ленты", isOn: $model.text.alongTape)
                if model.text.alongTape {
                    Toggle("Растянуть на всю ширину ленты", isOn: $model.text.autoFit)
                }
                MMField(title: String(localized: "Длина"), value: $model.text.lengthMM)
                MMField(title: String(localized: "Поля"), value: $model.text.paddingMM, range: 0...20, zeroMeansAuto: false)
            } header: {
                Text("Этикетка")
            } footer: {
                Text("«Вдоль ленты» — длинная наклейка: текст идёт по длине рулона, например для корешков папок и проводов.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - QR

struct QREditorView: View {
    @EnvironmentObject var model: AppModel
    @State private var wifiSSID = ""
    @State private var wifiPassword = ""
    @State private var kind: Kind = .link

    enum Kind: String, CaseIterable, Identifiable {
        case link, wifi
        var id: String { rawValue }
        var title: String { self == .link ? String(localized: "Ссылка или текст") : "Wi‑Fi" }
    }

    var body: some View {
        InspectorForm(tab: .qr) {
            Section("Что в QR-коде") {
                Picker("Тип", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch kind {
                case .link:
                    WideField(title: String(localized: "Ссылка или текст"), text: $model.qr.content, prompt: "https://…", lines: 1...4)
                case .wifi:
                    TextField("Сеть (SSID)", text: $wifiSSID)
                    SecureField("Пароль", text: $wifiPassword)
                    Button("Собрать QR для Wi‑Fi") { makeWiFi() }.disabled(wifiSSID.isEmpty)
                }
            }
            Section("Подпись") {
                WideField(title: String(localized: "Подпись"), text: $model.qr.caption, prompt: String(localized: "Первая строка — жирная"), lines: 1...4)
                SliderRow(title: String(localized: "Размер"), value: $model.qr.captionSizePt, range: 6...36) { "\(Int($0)) pt" }
                Picker("Расположение", selection: $model.qr.layout) {
                    ForEach(QRLayout.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Размер") {
                SliderRow(title: String(localized: "Сторона QR"), value: $model.qr.qrSizeMM, range: 8...46) { String(localized: "\(Int($0)) мм") }
                MMField(title: String(localized: "Длина этикетки"), value: $model.qr.lengthMM)
                Picker("Запас на повреждения", selection: $model.qr.correction) {
                    Text("L — мельче").tag(QRCorrection.low)
                    Text("M — обычно").tag(QRCorrection.medium)
                    Text("Q").tag(QRCorrection.quartile)
                    Text("H — надёжнее").tag(QRCorrection.high)
                }
            }
        }
        .onAppear { if model.qr.content.hasPrefix("WIFI:") { kind = .wifi } }
    }

    private func makeWiFi() {
        let esc = { (s: String) in
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ":", with: "\\:")
        }
        model.qr.content = "WIFI:T:WPA;S:\(esc(wifiSSID));P:\(esc(wifiPassword));;"
        if model.qr.caption.isEmpty || model.qr.caption.hasPrefix("Wi‑Fi") { model.qr.caption = "Wi‑Fi\n\(wifiSSID)" }
    }
}

// MARK: - Photo

struct PhotoEditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InspectorForm(tab: .photo) {
            Section("Фото") {
                ImageWell(image: model.photoImage, name: model.photoName, emptyText: String(localized: "Перетащите фото на ленту"),
                          paste: { Self.pasteImage(into: model) }, pick: { Self.pickImage(into: model) },
                          clear: { model.photoImage = nil; model.photoName = "" })
            }
            Section("Точки") {
                Picker("Растрирование", selection: $model.photo.dither) {
                    ForEach(DitherMethod.allCases) { Text($0.title).tag($0) }
                }
                SliderRow(title: String(localized: "Яркость"), value: $model.photo.brightness, range: -0.5...0.5)
                SliderRow(title: String(localized: "Контраст"), value: $model.photo.contrast, range: -0.5...0.8)
                SliderRow(title: String(localized: "Гамма"), value: $model.photo.gamma, range: 0.4...2.5)
                SliderRow(title: String(localized: "Резкость"), value: $model.photo.sharpen, range: 0...2)
                Toggle("Негатив", isOn: $model.photo.invert)
                Button("Сбросить настройки") {
                    let keepRotate = model.photo.rotate
                    model.photo = PhotoSettings()
                    model.photo.rotate = keepRotate
                }
            }
            Section("Размер") {
                SliderRow(title: String(localized: "Ширина"), value: $model.photo.widthPercent, range: 20...100, step: 5) { "\(Int($0))%" }
                Toggle("Повернуть на 90°", isOn: $model.photo.rotate)
                MMField(title: String(localized: "Макс. длина"), value: $model.photo.maxLengthMM)
            }
        }
    }

    static func pickImage(into model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.loadPhoto(url: url) }
    }

    static func pasteImage(into model: AppModel) {
        if let img = NSImage(pasteboard: .general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            model.photoImage = cg
            model.photoName = String(localized: "Из буфера обмена")
        } else {
            model.show(String(localized: "В буфере нет картинки"), error: true)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
