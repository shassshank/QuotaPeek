import QuotaPeekCore
import Foundation

/// Receives readings from the statusline hooks over a Unix datagram socket.
///
/// Fire-and-forget by design: hooks send non-blocking and ignore errors, so a
/// closed or busy app never slows an agent down - readings sent while the app
/// is not running are simply dropped. Each datagram arrives whole or not at
/// all, and the single receive queue serializes concurrent senders.
final class DatagramListener {
    /// Largest datagram accepted; hooks send a few hundred bytes.
    static let maxDatagramBytes = 16 * 1024

    private let path: String
    private let onMessage: (Data) -> Void
    private let queue = DispatchQueue(label: "com.quotapeek.datagram", qos: .utility)
    private var source: DispatchSourceRead?

    init(path: String, onMessage: @escaping (Data) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    deinit { stop() }

    func start() throws {
        guard source == nil else { return }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        var ok = false
        defer { if !ok { close(fd) } }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var receiveBuffer: Int32 = 64 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw DatagramError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // The app is single-instance (app.lock), so any socket file here is a
        // leftover from a previous run.
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw posixError("bind \(path)") }
        // Only this user may send readings.
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd) }
        let socketPath = path
        source.setCancelHandler {
            close(fd)
            unlink(socketPath)
        }
        self.source = source
        source.resume()
        ok = true
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: Self.maxDatagramBytes)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                onMessage(Data(buffer[0..<n]))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return // EAGAIN (drained) or error
            }
        }
    }

    private func posixError(_ what: String) -> Error {
        DatagramError.system("\(what): \(String(cString: strerror(errno)))")
    }
}

enum DatagramError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case system(String)

    var description: String {
        switch self {
        case .pathTooLong(let path): return "socket path too long: \(path)"
        case .system(let message): return message
        }
    }
}
