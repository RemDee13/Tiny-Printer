import AppKit
import Foundation

/// Exposes the thermal printer to macOS as a regular printer.
///
/// macOS has no driver for a Bluetooth LE label printer, so we run Apple's own `ippeveprinter`
/// (an IPP Everywhere printer emulator) on 127.0.0.1. CUPS talks to it like to any network printer
/// and hands it a PDF of the right page size; `ippeveprinter` calls our handler script, which posts
/// the PDF to this app over the local API, and the app prints it over Bluetooth.
/// No root, no kernel extensions, nothing visible on the network.
final class SystemPrinter {
    static let queueName = "Tiny_Printer"
    static let ippPort = 8613
    static let apiPort: UInt16 = 8614

    private var process: Process?
    private var stopping = false
    private var quickExits = 0
    private var startedAt = Date()
    private(set) var lastError: String?
    var onLog: ((String) -> Void)?

    private var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TinyPrinter/ipp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var isRunning: Bool { process?.isRunning == true }

    // MARK: ippeveprinter lifecycle

    func start() {
        guard !isRunning else { return }
        stopping = false
        // A previous app instance that did not exit cleanly may have left its ippeveprinter holding the port.
        Self.run("/usr/bin/pkill", ["-f", "TinyPrinter/ipp/tiny-printer.conf"])
        Thread.sleep(forTimeInterval: 0.3)
        do {
            let conf = supportDir.appendingPathComponent("tiny-printer.conf")
            try Self.attributesConf().write(to: conf, atomically: true, encoding: .utf8)
            let handler = try installHandlerScript()
            let spool = supportDir.appendingPathComponent("spool", isDirectory: true)
            try? FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ippeveprinter")
            p.arguments = ["-n", "localhost", "-p", String(Self.ippPort), "-r", "off",
                           "-a", conf.path, "-c", handler.path, "-d", spool.path,
                           "Tiny Printer"]   // note: -M/-m/-f are rejected together with -a
            var env = ProcessInfo.processInfo.environment
            env["TINYPRINTER_API_PORT"] = String(Self.apiPort)
            p.environment = env
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                // Skip per-request chatter; keep job info and errors.
                for line in s.split(separator: "\n") where !line.hasPrefix("localhost ") || line.lowercased().contains("error") {
                    self?.onLog?("ipp: " + line)
                }
            }
            p.terminationHandler = { [weak self] proc in
                guard let self, !self.stopping else { return }
                self.quickExits = Date().timeIntervalSince(self.startedAt) < 10 ? self.quickExits + 1 : 0
                guard self.quickExits < 3 else {
                    self.lastError = String(localized: "ippeveprinter падает при запуске (код \(proc.terminationStatus))")
                    self.onLog?(self.lastError!)
                    return
                }
                self.onLog?("ippeveprinter exited (\(proc.terminationStatus)), restarting in 3 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.process = nil; self.start() }
            }
            startedAt = Date()
            try p.run()
            process = p
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            onLog?("ippeveprinter failed: \(error)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    /// The handler lives in Application Support (stable path even if the app is moved).
    private func installHandlerScript() throws -> URL {
        let url = supportDir.appendingPathComponent("ipp-handler.sh")
        let script = """
        #!/bin/bash
        # Called by ippeveprinter for every print job. $1 = document file (usually PDF).
        PORT="${TINYPRINTER_API_PORT:-\(Self.apiPort)}"
        Q="source=ipp&copies=${IPP_COPIES:-1}&quality=${IPP_PRINT_QUALITY:-normal}"
        echo "INFO: job '${IPP_JOB_NAME}' ${CONTENT_TYPE}" >&2
        /usr/bin/curl -sS --fail-with-body --max-time 600 -H "Expect:" \\
          -H "Content-Type: ${CONTENT_TYPE:-application/octet-stream}" \\
          --data-binary @"$1" "http://127.0.0.1:${PORT}/print?${Q}" >&2
        STATUS=$?
        if [ $STATUS -ne 0 ]; then echo "ERROR: Tiny Printer app did not print the job" >&2; exit 1; fi
        exit 0
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: CUPS queue

    var isInstalled: Bool {
        let out = Self.run("/usr/bin/lpstat", ["-p", Self.queueName])
        return out.status == 0
    }

    /// Adds the queue to CUPS. Admin users on macOS are in `_lpadmin`, so no password is needed.
    func install() -> String? {
        if !isRunning { start(); Thread.sleep(forTimeInterval: 1.5) }
        let r = Self.run("/usr/sbin/lpadmin", [
            "-p", Self.queueName, "-E",
            "-v", "ipp://localhost:\(Self.ippPort)/ipp/print",
            "-m", "everywhere",
            "-D", "Tiny Printer",
            "-L", String(localized: "Bluetooth, 57 мм"),
            "-o", "printer-is-shared=false",
            "-o", "media-default=57x40mm",
        ])
        return r.status == 0 ? nil : (r.output.isEmpty ? String(localized: "lpadmin завершился с кодом \(r.status)") : r.output)
    }

    func uninstall() {
        _ = Self.run("/usr/sbin/lpadmin", ["-x", Self.queueName])
    }

    // MARK: "PDF" menu of the print dialog

    static var pdfServicesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/PDF Services")
    }

    /// The menu item is named in the current language, so look for any of our links, whatever they are called.
    static var pdfServiceLinks: [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: pdfServicesDir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { url in
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return false }
            return URL(fileURLWithPath: dest).lastPathComponent == Bundle.main.bundleURL.lastPathComponent
        }
    }

    var pdfServiceInstalled: Bool { !Self.pdfServiceLinks.isEmpty }

    func installPDFService() throws {
        let name = String(localized: "Печать на Tiny Printer") + ".app"
        try FileManager.default.createDirectory(at: Self.pdfServicesDir, withIntermediateDirectories: true)
        uninstallPDFService()
        try FileManager.default.createSymbolicLink(at: Self.pdfServicesDir.appendingPathComponent(name),
                                                   withDestinationURL: Bundle.main.bundleURL)
    }

    func uninstallPDFService() {
        for link in Self.pdfServiceLinks { try? FileManager.default.removeItem(at: link) }
    }

    // MARK: helpers

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// IPP attributes: 57 mm continuous roll, 203 dpi, monochrome. Head prints the middle 48 mm,
    /// hence 4.5 mm side margins. Several common label lengths plus a custom range for anything else.
    static func attributesConf() -> String {
        let lengths = [20, 30, 40, 50, 60, 80, 100, 150]
        func col(_ y: String, _ tag: String = "integer") -> String {
            "{ MEMBER collection media-size { MEMBER integer x-dimension 5700 MEMBER \(tag) y-dimension \(y) } "
                + "MEMBER integer media-left-margin 450 MEMBER integer media-right-margin 450 "
                + "MEMBER integer media-top-margin 0 MEMBER integer media-bottom-margin 0 }"
        }
        func size(_ y: String, _ tag: String = "integer") -> String {
            "{ MEMBER integer x-dimension 5700 MEMBER \(tag) y-dimension \(y) }"
        }
        let names = lengths.map { "custom_57x\($0)mm_57x\($0)mm" } + ["custom_min_57x10mm", "custom_max_57x1000mm"]
        let database = lengths.map { col(String($0 * 100)) } + [col("1000-100000", "rangeOfInteger")]
        let sizes = lengths.map { size(String($0 * 100)) } + [size("1000-100000", "rangeOfInteger")]
        return """
        ATTR mimeMediaType document-format-supported application/pdf,image/jpeg,image/png,application/octet-stream
        ATTR mimeMediaType document-format-default application/octet-stream
        ATTR keyword media-supported \(names.joined(separator: ","))
        ATTR collection media-col-database \(database.joined(separator: ","))
        ATTR collection media-size-supported \(sizes.joined(separator: ","))
        ATTR collection media-col-default \(col("4000"))
        ATTR collection media-col-ready \(col("4000"))
        ATTR keyword media-default custom_57x40mm_57x40mm
        ATTR keyword media-ready custom_57x40mm_57x40mm
        ATTR integer media-bottom-margin-supported 0
        ATTR integer media-top-margin-supported 0
        ATTR integer media-left-margin-supported 450
        ATTR integer media-right-margin-supported 450
        ATTR keyword print-color-mode-supported monochrome
        ATTR keyword print-color-mode-default monochrome
        ATTR boolean color-supported false
        ATTR keyword sides-supported one-sided
        ATTR keyword sides-default one-sided
        ATTR resolution printer-resolution-supported 203dpi
        ATTR resolution printer-resolution-default 203dpi
        ATTR enum print-quality-supported 3,4,5
        ATTR enum print-quality-default 4
        ATTR rangeOfInteger copies-supported 1-99
        ATTR text printer-make-and-model "Tiny Printer 57mm Thermal"
        ATTR text printer-info "Tiny Printer"
        """
    }
}
