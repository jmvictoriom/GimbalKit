import Foundation
import Testing
import GimbalKit

@Test func zoneStoreRoundTripAndCorruptBackup() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("zones.json")
    let store = ZoneStore(url: url)
    #expect(try await store.load().isEmpty)
    let zones = [Zone(name: "mesa", yaw: -10...10, pitch: -10...10)]
    try await store.save(zones)
    #expect(try await store.load() == zones)
    await #expect(throws: ZoneStoreError.invalidZone) { try await store.save(zones + zones) }
    #expect(try await store.load() == zones)
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: url)
    #expect(try await store.load().isEmpty)
    #expect(try Data(contentsOf: url.appendingPathExtension("corrupt")) == corrupt)
    try await store.save(zones)
    #expect(try await store.load() == zones)
}

@Test func zoneStorePreservesValidBackupAndRecoversFromCorruption() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("zones.json")
    let backup = url.appendingPathExtension("bak")
    let store = ZoneStore(url: url)
    let previous = [Zone(name: "anterior", yaw: -10...10, pitch: -10...10)]
    let current = [Zone(name: "actual", yaw: -20...20, pitch: -20...20)]
    try await store.save(previous)
    let previousBytes = try Data(contentsOf: url)
    try await store.save(current)
    #expect(try Data(contentsOf: backup) == previousBytes)
    let corrupt = Data("{broken with valid backup".utf8)
    try corrupt.write(to: url)
    #expect(try await store.load() == previous)
    #expect(try Data(contentsOf: url.appendingPathExtension("corrupt")) == corrupt)
    #expect(try Data(contentsOf: backup) == previousBytes)
    try await store.save(current)
    #expect(try await store.load() == current)
    #expect(try Data(contentsOf: backup) == previousBytes)
}

@Test func zoneStoreCorruptWithInvalidBackupReturnsEmpty() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("zones.json")
    let backup = url.appendingPathExtension("bak")
    let corrupt = Data("{broken".utf8)
    let invalidBackup = Data("{also broken".utf8)
    try corrupt.write(to: url)
    try invalidBackup.write(to: backup)
    let store = ZoneStore(url: url)
    #expect(try await store.load().isEmpty)
    #expect(try Data(contentsOf: url.appendingPathExtension("corrupt")) == corrupt)
    #expect(try Data(contentsOf: backup) == invalidBackup)
}

@Test func zoneStoreChecksDocumentAndBackupSizeLimits() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("zones.json")
    let backup = url.appendingPathExtension("bak")
    let store = ZoneStore(url: url)
    let zones = [Zone(name: "mesa", yaw: -10...10, pitch: -10...10)]
    try await store.save(zones)
    var bytes = try Data(contentsOf: url)
    bytes.append(Data(repeating: 0x20, count: 1_048_576 - bytes.count))
    try bytes.write(to: url)
    #expect(try await store.load() == zones)
    bytes.append(0x20)
    try bytes.write(to: url)
    try bytes.write(to: backup)
    #expect(try await store.load().isEmpty)
    #expect(try Data(contentsOf: url.appendingPathExtension("corrupt")) == bytes)
    try await store.save(zones)
    #expect(try await store.load() == zones)
    #expect(try Data(contentsOf: backup) == bytes)
}

@Test func zoneStoreChecksZoneCountWithoutOverwriting() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("zones.json")
    let store = ZoneStore(url: url)
    let zones = (0..<256).map { Zone(name: "zona-\($0)", yaw: -10...10, pitch: -10...10) }
    try await store.save(zones)
    #expect(try await store.load() == zones)
    let bytes = try Data(contentsOf: url)
    await #expect(throws: ZoneStoreError.invalidZone) {
        try await store.save(zones + [Zone(name: "extra", yaw: -10...10, pitch: -10...10)])
    }
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try await store.load() == zones)
}
