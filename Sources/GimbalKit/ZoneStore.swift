import Foundation

public enum ZoneStoreError: Error, Sendable, Equatable { case invalidZone }
public struct ZoneRecord: Sendable, Codable, Equatable {
    public let name: String
    public let yawLower: Double
    public let yawUpper: Double
    public let pitchLower: Double
    public let pitchUpper: Double
    public let forbidden: Bool
    public init(_ zone: Zone) {
        name = zone.name; yawLower = zone.yaw.lowerBound; yawUpper = zone.yaw.upperBound
        pitchLower = zone.pitch.lowerBound; pitchUpper = zone.pitch.upperBound; forbidden = zone.forbidden
    }
    public func zone() throws -> Zone {
        guard !name.isEmpty, name.count <= 64, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              [yawLower, yawUpper, pitchLower, pitchUpper].allSatisfy(\.isFinite),
              yawLower < yawUpper, pitchLower < pitchUpper,
              yawLower >= -180, yawUpper <= 180, pitchLower >= -90, pitchUpper <= 90 else {
            throw ZoneStoreError.invalidZone
        }
        return Zone(name: name, yaw: yawLower...yawUpper, pitch: pitchLower...pitchUpper, forbidden: forbidden)
    }
}
public actor ZoneStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GimbalKit/zones.json")
    }
    private struct Document: Codable { let version: Int; let zones: [ZoneRecord] }
    private let url: URL
    public init(url: URL = ZoneStore.defaultURL) { self.url = url }
    public func load() throws -> [Zone] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do { data = try readData(at: url) }
        catch ZoneStoreError.invalidZone { return try recoverFromCorruption() }
        do {
            return try decode(data)
        } catch {
            return try recoverFromCorruption(data: data)
        }
    }
    public func save(_ zones: [Zone]) throws {
        try validate(zones)
        let data = try JSONEncoder().encode(Document(version: 1, zones: zones.map(ZoneRecord.init)))
        guard data.count <= 1_048_576 else { throw ZoneStoreError.invalidZone }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = try? readData(at: url), (try? decode(previous)) != nil {
            try previous.write(to: url.appendingPathExtension("bak"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
    private func readData(at source: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0, size.int64Value <= 1_048_576 else { throw ZoneStoreError.invalidZone }
        let data = try Data(contentsOf: source)
        guard data.count <= 1_048_576 else { throw ZoneStoreError.invalidZone }
        return data
    }
    private func decode(_ data: Data) throws -> [Zone] {
        let doc = try JSONDecoder().decode(Document.self, from: data)
        guard doc.version == 1 else { throw ZoneStoreError.invalidZone }
        let zones = try doc.zones.map { try $0.zone() }
        try validate(zones)
        return zones
    }
    private func recoverFromCorruption(data: Data? = nil) throws -> [Zone] {
        let corrupt = url.appendingPathExtension("corrupt")
        if let data {
            try data.write(to: corrupt, options: .atomic)
        } else {
            // Copiar archivos demasiado grandes conserva sus bytes sin leerlos enteros en memoria.
            if FileManager.default.fileExists(atPath: corrupt.path) {
                try FileManager.default.removeItem(at: corrupt)
            }
            try FileManager.default.copyItem(at: url, to: corrupt)
        }
        guard let backup = try? readData(at: url.appendingPathExtension("bak")),
              let zones = try? decode(backup) else { return [] }
        return zones
    }
    private func validate(_ zones: [Zone]) throws {
        guard zones.count <= 256, Set(zones.map(\.name)).count == zones.count else { throw ZoneStoreError.invalidZone }
        for zone in zones { _ = try ZoneRecord(zone).zone() }
    }
}
