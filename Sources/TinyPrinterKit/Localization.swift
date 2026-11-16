import Foundation

extension Bundle {
    /// The bundle with the UI string tables (`<lang>.lproj/Localizable.strings`): the app itself.
    /// The CLI has no bundle of its own, so it borrows the tables of the app next to it or in /Applications.
    public static let tinyPrinter: Bundle = {
        let appID = "dev.tinyprinter.TinyPrinter"
        if Bundle.main.bundleIdentifier == appID { return .main }
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("TinyPrinter.app"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/TinyPrinter.app"))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/TinyPrinter.app"))
        for url in candidates {
            if let bundle = Bundle(url: url), bundle.bundleIdentifier == appID { return bundle }
        }
        return .main
    }()
}
