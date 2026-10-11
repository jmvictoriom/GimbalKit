import Foundation
import Darwin
import Testing
@testable import GimbalKitMCP

@Test func tokenIsPrivateStableRandomAndRejectsSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try LocalFiles(directory: root)
    #expect(throws: LocalFileError.missing) { try files.token(create: false) }
    let token = try files.token(create: true)
    #expect(token.utf8.count == 64 && token.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(try files.token(create: false) == token)
    let url = root.appendingPathComponent("token")
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try files.writeEndpoint(port: 12345)
    #expect(try files.readEndpoint() == 12345)
    try files.removeEndpoint()
    #expect(throws: LocalFileError.missing) { try files.readEndpoint() }
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("other"))
    #expect(throws: LocalFileError.unsafeFile) { try files.token(create: true) }
}

@Test func tokenRejectsOversizedPrivateFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try LocalFiles(directory: root)
    _ = try files.token(create: true)
    let url = root.appendingPathComponent("token")
    try Data(repeating: 0x61, count: 65).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #expect(throws: LocalFileError.unsafeFile) { try files.token(create: false) }
    #expect(throws: LocalFileError.unsafeFile) { try files.token(create: true) }
    #expect(try Data(contentsOf: url).count == 65)
}
