import Foundation
import XCTest

/// Every language table must have the same keys as the English one, with the same format specifiers.
/// Keys are the Russian source strings from the code (`scripts/check-localization.sh` finds new ones).
final class LocalizationTests: XCTestCase {
    private let languages: Set<String> = ["en", "ru", "de", "es", "fr", "zh-Hans"]

    private var dir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization")
    }

    private func table(_ lang: String, _ name: String = "Localizable") throws -> [String: String] {
        let url = dir.appendingPathComponent("\(lang).lproj/\(name).strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(lang)/\(name).strings does not parse")
    }

    private func specifiers(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|ld|d|u|@|lf|f|%)")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s))
            .map { String(s[Range($0.range, in: s)!]) }
            .sorted()
    }

    func testAllLanguagesMatchEnglish() throws {
        let english = try table("en")
        XCTAssertGreaterThan(english.count, 400)
        let found = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
        XCTAssertEqual(Set(found), languages)
        for lang in found {
            let t = try table(lang)
            XCTAssertEqual(Set(t.keys), Set(english.keys), "\(lang): keys differ from en")
            for (key, value) in t {
                XCTAssertEqual(specifiers(value), specifiers(key), "\(lang): \(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(lang): empty value for \(key)")
            }
            XCTAssertNotNil(try table(lang, "InfoPlist")["NSBluetoothAlwaysUsageDescription"], "\(lang): InfoPlist.strings")
        }
    }
}
