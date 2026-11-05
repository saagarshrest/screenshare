import Foundation
import Darwin

/// Finds a computer running ShareScreen without UDP broadcast (which iOS only allows
/// with a special entitlement): try the last address, then every address on this
/// Wi‑Fi's /24 subnet with GET http://<ip>:8780/ping.
@MainActor
final class HostFinder: ObservableObject {
    @Published var message = "Looking for your computer…"
    @Published var searching = false
    @Published var found: String?

    /// Overridable for testing with launch arguments: -httpPort 9780 -videoPort 9783
    nonisolated static var port: Int { UserDefaults.standard.integer(forKey: "httpPort").nonZero ?? 8780 }
    nonisolated static var videoPort: UInt16 { UInt16(UserDefaults.standard.integer(forKey: "videoPort").nonZero ?? 8783) }

    func search() {
        guard !searching else { return }
        found = nil
        searching = true
        message = "Looking for your computer…"
        Task {
            var candidates: [String] = []
            if let last = UserDefaults.standard.string(forKey: "lastHost") { candidates.append(last) }
            candidates.append("127.0.0.1") // USB tethering / port forwarding
            if let hit = await firstAlive(candidates, timeout: 1.0) { finish(hit); return }
            guard let me = Self.wifiAddress() else {
                fail("Connect to the same Wi‑Fi as your computer, or tap Enter address.")
                return
            }
            let prefix = me.split(separator: ".").prefix(3).joined(separator: ".")
            let subnet = (1...254).map { "\(prefix).\($0)" }.filter { $0 != me }
            if let hit = await firstAlive(subnet, timeout: 1.5) { finish(hit); return }
            fail("Couldn't find your computer.\n\nMake sure ShareScreen is running on it and both are on the same Wi‑Fi or hotspot.")
        }
    }

    func check(_ ip: String) {
        guard !ip.isEmpty else { return }
        searching = true
        message = "Connecting to \(ip)…"
        Task {
            if await Self.ping(ip, timeout: 3) { finish(ip) } else { fail("No ShareScreen at \(ip).") }
        }
    }

    private func finish(_ ip: String) { searching = false; found = ip }
    private func fail(_ text: String) { searching = false; message = text }

    private func firstAlive(_ ips: [String], timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for ip in ips { group.addTask { await Self.ping(ip, timeout: timeout) ? ip : nil } }
            for await result in group { if let result { group.cancelAll(); return result } }
            return nil
        }
    }

    nonisolated static func ping(_ ip: String, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://\(ip):\(port)/ping") else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return String(decoding: data, as: UTF8.self).hasPrefix("macscreen")
    }

    /// IPv4 address of Wi‑Fi (en0) or the hotspot/bridge interface.
    nonisolated static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name == "en0" || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if name == "en0" { return ip }
                best = best ?? ip
            }
        }
        return best
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
