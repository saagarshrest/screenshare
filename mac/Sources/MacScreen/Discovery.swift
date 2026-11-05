import Darwin
import Foundation

/// Lets the Android app find this Mac without typing an IP.
/// Every second it broadcasts "MACSCREEN 8780" on UDP 8782, and it answers
/// "MACSCREEN?" queries directly. Works on home Wi‑Fi and on a phone hotspot,
/// with no internet needed.
final class Discovery {
    static let port: UInt16 = 8782
    private var socketFD: Int32 = -1
    private var timer: DispatchSourceTimer?
    private let message = Data("MACSCREEN \(StreamServer.httpPort) \(Host.current().localizedName ?? "Mac")".utf8)

    func start() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Discovery.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { close(fd); return }
        socketFD = fd

        Thread.detachNewThread { [weak self] in self?.listen(fd) }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.announce() }
        timer.resume()
        self.timer = timer
    }

    private func announce() {
        guard socketFD >= 0 else { return }
        var targets = Set(NetInfo.broadcastAddresses())
        targets.insert("255.255.255.255")
        for target in targets { send(message, to: target, port: Discovery.port) }
    }

    private func listen(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 512)
        while socketFD == fd {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard n > 0 else { if n < 0 { return } else { continue } }
            guard String(decoding: buffer[0..<n], as: UTF8.self).hasPrefix("MACSCREEN?") else { continue }
            var reply = from
            _ = message.withUnsafeBytes { bytes in
                withUnsafePointer(to: &reply) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, length)
                    }
                }
            }
        }
    }

    private func send(_ data: Data, to ip: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

/// Small helpers for the Mac's own network addresses.
enum NetInfo {
    struct Address { let interface: String; let ip: String; let broadcast: String? }

    static func addresses() -> [Address] {
        var result: [Address] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            // Skip VPN/tunnel and virtual bridge interfaces.
            guard !name.hasPrefix("utun"), !name.hasPrefix("bridge"), !name.hasPrefix("awdl"),
                  !name.hasPrefix("llw") else { continue }
            let ip = string(from: sa)
            var broadcast: String?
            if flags & IFF_BROADCAST != 0, let b = entry.ifa_dstaddr { broadcast = string(from: b) }
            if let ip { result.append(Address(interface: name, ip: ip, broadcast: broadcast)) }
        }
        return result
    }

    static func broadcastAddresses() -> [String] { addresses().compactMap(\.broadcast) }

    /// The address most likely to work for the phone (Wi‑Fi first).
    static func primaryIP() -> String? {
        let all = addresses()
        return (all.first { $0.interface == "en0" } ?? all.first { $0.interface.hasPrefix("en") } ?? all.first)?.ip
    }

    private static func string(from sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return ok == 0 ? String(cString: host) : nil
    }
}
