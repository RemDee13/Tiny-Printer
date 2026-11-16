import Foundation

extension Bundle {
    /// The bundle with the UI string tables (`<lang>.lproj/Localizable.strings`): the app itself.
    /// The CLI has no bundle of its own, so it borrows the tables of the app next to it or in /Applications,
    /// in the language chosen in the app's settings (or the macOS language when none is chosen).
    public static let tinyPrinter: Bundle = {
        let appID = "dev.tinyprinter.TinyPrinter"
        if Bundle.main.bundleIdentifier == appID { return .main }
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("TinyPrinter.app"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/TinyPrinter.app"))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/TinyPrinter.app"))
        guard let app = candidates.lazy.compactMap({ Bundle(url: $0) }).first(where: { $0.bundleIdentifier == appID }) else {
            return .main
        }
        if let chosen = (UserDefaults.standard.persistentDomain(forName: appID)?["AppleLanguages"] as? [String])?.first,
           let path = app.path(forResource: chosen, ofType: "lproj"),
           let tables = Bundle(path: path) {
            return tables
        }
        return app
    }()
}
