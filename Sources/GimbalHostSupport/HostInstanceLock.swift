import Foundation
import Darwin

public enum HostInstanceError: Error, Sendable, Equatable { case alreadyRunning, unsafeFile }
public final class HostInstanceLock: Sendable {
    private let descriptor: Int32
    public init(directory: URL) throws {
        let fd = open(directory.appendingPathComponent("host.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostInstanceError.unsafeFile }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o777 == 0o600 else {
            close(fd); throw HostInstanceError.unsafeFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw HostInstanceError.alreadyRunning }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
