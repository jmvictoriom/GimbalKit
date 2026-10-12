#if os(macOS)
import Foundation
import Security
import Darwin

public enum LocalFileError: Error, Sendable, Equatable { case missing, unsafeFile, io, random }
public struct LocalFiles: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GimbalKit")
    }
    public let directory: URL
    public init(directory: URL = LocalFiles.defaultDirectory) throws {
        self.directory = directory
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { throw LocalFileError.unsafeFile }
    }
    public func token(create: Bool) throws -> String {
        let path = directory.appendingPathComponent("token").path
        if create {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 {
                var random = [UInt8](repeating: 0, count: 32)
                let rc = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
                guard rc == errSecSuccess else { close(fd); unlink(path); throw LocalFileError.random }
                let value = random.map { String(format: "%02x", $0) }.joined()
                do { try writeAll(Data(value.utf8), fd: fd); guard fsync(fd) == 0 else { throw LocalFileError.io } }
                catch { close(fd); unlink(path); throw error }
                close(fd)
            } else if errno != EEXIST { throw LocalFileError.unsafeFile }
        }
        let data = try readPrivate(path, maxBytes: 64)
        guard let value = String(data: data, encoding: .utf8), value.utf8.count == 64,
              value.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw LocalFileError.unsafeFile }
        return value
    }
    public func writeEndpoint(port: UInt16) throws {
        guard port > 0 else { throw LocalFileError.unsafeFile }
        let data = try JSONEncoder().encode(["port": port])
        let temp = directory.appendingPathComponent(".endpoint-\(UUID().uuidString)").path
        let destination = directory.appendingPathComponent("endpoint.json").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalFileError.io }
        defer { close(fd); unlink(temp) }
        try writeAll(data, fd: fd)
        guard fsync(fd) == 0, rename(temp, destination) == 0 else { throw LocalFileError.io }
    }
    public func readEndpoint() throws -> UInt16 {
        let data = try readPrivate(directory.appendingPathComponent("endpoint.json").path, maxBytes: 128)
        guard let port = try JSONDecoder().decode([String: UInt16].self, from: data)["port"], port > 0 else {
            throw LocalFileError.unsafeFile
        }
        return port
    }
    public func removeEndpoint() throws {
        if unlink(directory.appendingPathComponent("endpoint.json").path) != 0, errno != ENOENT { throw LocalFileError.io }
    }
    private func readPrivate(_ path: String, maxBytes: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? LocalFileError.missing : LocalFileError.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o777 == 0o600,
              info.st_size >= 0, info.st_size <= maxBytes else { throw LocalFileError.unsafeFile }
        var bytes = [UInt8](repeating: 0, count: maxBytes + 1)
        var total = 0
        while total < bytes.count {
            let capacity = bytes.count - total
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: total), capacity) }
            if n < 0 { if errno == EINTR { continue }; throw LocalFileError.io }
            if n == 0 { break }
            total += n
        }
        guard total <= maxBytes else { throw LocalFileError.unsafeFile }
        return Data(bytes.prefix(total))
    }
    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw LocalFileError.io }
                guard n > 0 else { throw LocalFileError.io }
                offset += n
            }
        }
    }
}
#endif
