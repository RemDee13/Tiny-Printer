import AppKit
import SwiftUI
import TinyPrinterKit

// Settings window (⌘,): everything that is set once — the printer, printing from macOS, AI keys, the log.

enum SettingsTab: String, CaseIterable {
    case printer, printing, ai, log
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settings.tab") private var tab: SettingsTab = .printer
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        TabView(selection: $tab) {
            PrinterSettingsPane()
                .tabItem { Label("Принтер", systemImage: "printer") }
                .tag(SettingsTab.printer)
            PrintingSettingsPane()
                .tabItem { Label("Основные", systemImage: "gearshape") }
                .tag(SettingsTab.printing)
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            LogPane()
                .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }
                .tag(SettingsTab.log)
        }
        .frame(width: 620, height: 640)
        .tint(.brand)
        .onChange(of: appearance) { _, v in v.apply() }
    }
}

// MARK: - Printer

struct PrinterSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var printer = AppModel.shared.printer
    @State private var forcedDriver = AppModel.shared.printer.forcedDriverID

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        IconTile(systemName: model.output == .virtual ? "doc.on.doc.fill" : "printer.fill",
                                 tint: model.output == .virtual ? .purple : .gray, size: 48)
                        StatusDot(tone: model.printerTone, size: 12)
                            .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.printerTitle).font(.title3.weight(.semibold))
                        if let d = model.printerDetail {
                            Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let b = printer.status.battery, model.output == .bluetooth { BatteryBadge(level: b) }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                HStack {
                    if printer.isConnected {
                        Button("Отключить") { printer.disconnect() }
                    } else {
                        Button("Подключить") { model.connectPrinter() }
                            .buttonStyle(.borderedProminent)
                            .disabled(printer.state.isBusy || model.output == .virtual)
                    }
                    Button("Тестовая печать") { model.testPrint() }.disabled(model.busy)
                    Spacer()
                    Button("Забыть принтер", role: .destructive) { printer.forget() }
                        .disabled(printer.rememberedID == nil)
                }
            }

            Section {
                Picker("Куда печатать", selection: $model.output) {
                    ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
                }
                if model.output == .virtual {
                    HStack {
                        Text("Задания сохраняются как PNG — удобно проверять макеты без принтера.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Открыть папку") { NSWorkspace.shared.open(AppModel.virtualDir) }
                    }
                }
            }

            Section {
                if printer.candidates.isEmpty {
                    Text(printer.state == .scanning ? "Ищу устройства…" : "Нажмите «Искать», чтобы увидеть устройства рядом.")
                        .foregroundStyle(.secondary)
                }
                ForEach(printer.candidates) { c in
                    HStack {
                        Image(systemName: c.likelyPrinter ? "printer.fill" : "dot.radiowaves.left.and.right")
                            .foregroundStyle(c.likelyPrinter ? Color.brand : .secondary)
                            .frame(width: 20)
                        Text(c.name)
                        Text("\(c.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Подключить") {
                            Task { do { try await printer.connect(id: c.id) } catch { model.show(error.localizedDescription) } }
                        }
                        .disabled(printer.state.isBusy)
                    }
                }
            } header: {
                HStack {
                    Text("Устройства рядом")
                    Spacer()
                    if printer.state == .scanning { ProgressView().controlSize(.small) }
                    Button("Искать") { Task { try? await printer.scan(duration: 8) } }
                        .disabled(printer.state.isBusy)
                        .controlSize(.small)
                }
            } footer: {
                Text("Принтер держит одно подключение: если он подключён к телефону, отключите его там.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Протокол", selection: $forcedDriver) {
                    Text("Определять автоматически").tag("")
                    ForEach(DriverRegistry.all.map { ($0.id, $0.displayName) }, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: forcedDriver) { _, v in printer.forcedDriverID = v; printer.disconnect() }
                if let gatt = printer.gattDescription.nilIfEmpty {
                    DisclosureGroup("GATT-профиль устройства") {
                        Text(gatt).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Для опытных")
            } footer: {
                Text("Менять протокол нужно, только если принтер подключается, но не печатает.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Printing

struct PrintingSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Section("Приложение") {
                LabeledContent("Оформление") {
                    HStack(spacing: 10) {
                        ForEach(AppAppearance.allCases) { a in
                            AppearanceTile(appearance: a, selected: appearance == a) { appearance = a }
                        }
                    }
                }
                Toggle("Запускать при входе в систему", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }

            Section {
                Picker("Бумага", selection: $model.settings.paper) {
                    ForEach(PrintSettings.Paper.allCases) { Text($0.title).tag($0) }
                }
                Picker("Плотность", selection: $model.settings.density) {
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                MMField(title: "Прогон после печати", value: $model.settings.feedAfterMM, range: 0...40, zeroMeansAuto: false)
            } header: {
                Text("Бумага")
            } footer: {
                Text("Плотность: 1 — светлее, 5 — темнее. Самоклейке обычно нужно на шаг темнее, чем чековой ленте. Прогон — чтобы край вышел за нож.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                integrationRow(
                    title: "Принтер «Tiny Printer» в системе",
                    detail: model.systemPrinterInstalled
                        ? "Выбирайте его в ⌘P любого приложения. Размеры бумаги: 57×20…150 мм и свой."
                        : "Добавит принтер в список macOS (без пароля, только для этого Mac).",
                    installed: model.systemPrinterInstalled,
                    install: {
                        if let err = model.system.install() { model.show("Не удалось: \(err)") }
                        model.refreshIntegrationState()
                    },
                    remove: { model.system.uninstall(); model.refreshIntegrationState() })
                integrationRow(
                    title: "Пункт в меню «PDF» диалога печати",
                    detail: "Запасной путь: ⌘P → PDF → «Печать на Tiny Printer».",
                    installed: model.pdfServiceInstalled,
                    install: {
                        do { try model.system.installPDFService() } catch { model.show(error.localizedDescription) }
                        model.refreshIntegrationState()
                    },
                    remove: { model.system.uninstallPDFService(); model.refreshIntegrationState() })
                LabeledContent("Служба печати") {
                    HStack(spacing: 6) {
                        Circle().fill(model.system.isRunning ? Color.green : .red).frame(width: 7, height: 7)
                        Text(model.system.isRunning ? "работает · ipp://localhost:\(SystemPrinter.ippPort)" : "остановлена")
                            .foregroundStyle(.secondary)
                    }
                }
                if let e = model.serverError { Text(e).foregroundStyle(.red) }
            } header: {
                Text("Печать из других приложений")
            }

            Section("Как печатать документы") {
                Picker("Страницы", selection: $model.docOptions.mode) {
                    ForEach(DocumentRenderOptions.Mode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Фото в документах", selection: $model.docOptions.photoDither) {
                    ForEach(DitherMethod.allCases.filter { $0 != .threshold }) { Text($0.title).tag($0) }
                }
                Toggle("Обрезать пустое место внизу страницы", isOn: $model.docOptions.trimBottom)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshIntegrationState() }
    }

    private func integrationRow(title: String, detail: String, installed: Bool,
                                install: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(installed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if installed { Button("Убрать", action: remove) } else { Button("Добавить", action: install) }
        }
    }
}

/// Miniature window in light, dark or half-and-half, like the Appearance setting of macOS.
struct AppearanceTile: View {
    let appearance: AppAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    switch appearance {
                    case .light: mini(dark: false)
                    case .dark: mini(dark: true)
                    case .system:
                        mini(dark: false)
                            .overlay(alignment: .trailing) {
                                mini(dark: true).mask(Rectangle().frame(width: 31).frame(maxWidth: .infinity, alignment: .trailing))
                            }
                    }
                }
                .frame(width: 62, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color.brand : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1))
                Text(appearance.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(appearance.title)
    }

    private func mini(dark: Bool) -> some View {
        let bg = dark ? Color(white: 0.17) : Color(white: 0.93)
        let side = dark ? Color(white: 0.24) : Color(white: 0.86)
        return HStack(spacing: 0) {
            side.frame(width: 16)
            ZStack(alignment: .top) {
                bg
                RoundedRectangle(cornerRadius: 1.5).fill(.white).frame(width: 14, height: 22)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1).padding(.top, 7)
                RoundedRectangle(cornerRadius: 2).fill(dark ? Color(white: 0.08) : Color(white: 0.35))
                    .frame(width: 20, height: 4).padding(.top, 5)
            }
        }
        .overlay(alignment: .topTrailing) {
            Capsule().fill(Color.brand).frame(width: 10, height: 4).padding(4)
        }
    }
}

// MARK: - Log

struct LogPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var printer = AppModel.shared.printer

    var body: some View {
        Form {
            Section("Последние задания") {
                if model.history.isEmpty {
                    Text("Пока ничего не печаталось.").foregroundStyle(.secondary)
                }
                ForEach(model.history.prefix(30)) { j in
                    HStack {
                        Image(systemName: j.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(j.ok ? .green : .red)
                        Text(j.source)
                        Spacer()
                        Text(j.ok ? "\(Int(j.lengthMM)) мм" : j.message)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(j.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ScrollView {
                    Text(printer.log.suffix(300).joined(separator: "\n").nilIfEmpty ?? "Журнал пуст.")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220)
            } header: {
                HStack {
                    Text("Журнал Bluetooth")
                    Spacer()
                    Button("Скопировать") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(printer.log.joined(separator: "\n") + "\n\n" + printer.gattDescription,
                                                       forType: .string)
                        model.show("Журнал скопирован")
                    }
                    .controlSize(.small)
                }
            } footer: {
                Text("Пригодится, если принтер не печатает: журнал и GATT-профиль помогут подобрать протокол.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI

struct AISettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyInput = ""
    @State private var checking = false
    @State private var note: String?
    @State private var noteIsError = false

    private var provider: AIProvider { model.ai.provider }

    var body: some View {
        Form {
            Section {
                Picker("Сервис", selection: $model.ai.provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Картинки для открыток и стикеров рисует выбранный сервис по вашему ключу API; оплата — по тарифам сервиса. Надписи приложение набирает само.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ключ API \(provider.shortTitle)") {
                if let mask = model.keyMasks[provider] {
                    LabeledContent("Сохранён") {
                        HStack {
                            Image(systemName: "key.fill").foregroundStyle(.green)
                            Text(mask).monospaced()
                            Button("Удалить", role: .destructive) {
                                model.deleteKey(provider)
                                note = nil
                            }
                        }
                    }
                }
                SecureField(model.keyMasks[provider] == nil ? "Вставьте ключ" : "Заменить ключ", text: $keyInput)
                    .onSubmit(save)
                HStack {
                    Button("Сохранить и проверить", action: save)
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                    if model.keyMasks[provider] != nil {
                        Button("Проверить", action: check).disabled(checking)
                    }
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Link("Где взять ключ →", destination: provider.keyPage)
                }
                if let note {
                    Label(note, systemImage: noteIsError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(noteIsError ? .red : .green).textSelection(.enabled)
                }
                Text("Ключ хранится в Связке ключей macOS и отправляется только на \(provider.host).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Модель") {
                Picker("Модель", selection: modelBinding) {
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }
                TextField("Или впишите название", text: modelBinding)
                Button("Обновить список с сервера", action: check)
                    .disabled(checking || model.keyMasks[provider] == nil)
                if provider == .openAI {
                    Picker("Качество", selection: $model.ai.quality) {
                        ForEach(AIQuality.allCases) { Text($0.title).tag($0) }
                    }
                }
                Picker("Формат", selection: $model.ai.aspect) {
                    ForEach(AIAspect.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Без надписей на картинке", isOn: $model.ai.noText)
            }

            Section {
                LabeledContent("Нарисовано картинок", value: "\(model.aiLedger.count)")
                LabeledContent("Потрачено (оценка)", value: "≈ " + AIPricing.format(model.aiSpent))
                if let last = model.aiLedger.last {
                    LabeledContent("Последняя", value: "\(last.costText) · \(last.model)")
                }
                HStack {
                    Button("Сбросить счётчик") { model.resetLedger() }.disabled(model.aiLedger.isEmpty)
                    Spacer()
                    Link("Точные расходы в кабинете \(provider.shortTitle) →", destination: provider.usagePage)
                }
            } header: {
                Text("Расходы")
            } footer: {
                Text("Оценка по токенам из ответа сервиса и прайсу на ноябрь 2026. Сколько списано на самом деле — в кабинете сервиса.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.ai.provider) {
            keyInput = ""
            note = nil
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { provider == .openAI ? model.ai.openAIModel : model.ai.googleModel },
                set: { if provider == .openAI { model.ai.openAIModel = $0 } else { model.ai.googleModel = $0 } })
    }

    private var modelChoices: [String] {
        var list = model.aiModels[provider] ?? provider.knownModels
        let current = modelBinding.wrappedValue
        if !current.isEmpty && !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    private func save() {
        do {
            try model.saveKey(keyInput, for: provider)
            keyInput = ""
            check()
        } catch {
            note = error.localizedDescription
            noteIsError = true
        }
    }

    private func check() {
        checking = true
        note = nil
        let p = provider
        Task {
            let result = await model.refreshModels(p)
            checking = false
            note = result.message
            noteIsError = !result.ok
        }
    }
}
