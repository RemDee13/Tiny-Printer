import Foundation

/// Decodes JSON on top of default values, so missing keys keep their defaults.
/// Lets stored settings survive new fields and lets API clients send only what they care about.
public func decodeMerged<T: Codable>(_ defaults: T, from data: Data) -> T? {
    guard let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any],
          let patch = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let merged = base.merging(patch) { _, new in new }
    guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
    return try? JSONDecoder().decode(T.self, from: mergedData)
}

public extension UserDefaults {
    func load<T: Codable>(_ key: String, default value: T) -> T {
        guard let data = data(forKey: key) else { return value }
        return decodeMerged(value, from: data) ?? value
    }

    func save<T: Codable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, forKey: key) }
    }
}
