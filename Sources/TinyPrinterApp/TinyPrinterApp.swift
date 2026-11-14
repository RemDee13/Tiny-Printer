import AppKit
import SwiftUI
import TinyPrinterKit

@main
struct TinyPrinterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some Scene {
        Window("Tiny Printer", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .printItem) {
                Button("Печать") { model.printCurrent() }.keyboardShortcut("p")
                Button("Печать из буфера обмена") { model.printClipboard() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Тестовая печать") { model.testPrint() }
            }
            CommandGroup(before: .sidebar) {
                ForEach(EditorTab.allCases) { tab in
                    Button(tab.title) { model.tab = tab }
                        .keyboardShortcut(KeyEquivalent(tab.shortcut))
                }
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Picker("Оформление", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
            }
            SidebarCommands()
            InspectorCommands()
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.busy ? "printer.dotmatrix.fill" : "printer")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Divider()
        Button("Открыть Tiny Printer") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Печать из буфера обмена") { model.printClipboard() }
        Button(model.printer.isConnected ? "Отключить принтер" : "Подключить принтер") {
            if model.printer.isConnected { model.printer.disconnect() } else { model.connectPrinter() }
        }
        Divider()
        SettingsLink { Text("Настройки…") }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    var statusLine: String {
        let dot = model.printerTone == .ok ? "● " : ""
        let battery = model.printer.status.battery.map { " · \($0)%" } ?? ""
        return dot + model.printerTitle + (model.printer.isConnected ? battery : "")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppAppearance.stored.apply()
            AppModel.shared.start()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.open(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.system.stop() }
    }
}
