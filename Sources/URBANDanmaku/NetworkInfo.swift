import Darwin
import Foundation

/// 找出手機可以連到的本機 IPv4 位址（同一個 Wi-Fi / 區域網路）。
enum NetworkInfo {
    struct Interface: Equatable {
        let name: String
        let address: String

        /// 選單上的顯示名稱。
        var label: String {
            if name == "en0" { return "\(address)（en0，通常是 Wi-Fi）" }
            if name.hasPrefix("bridge") { return "\(address)（\(name)，網際網路共享）" }
            return "\(address)（\(name)）"
        }
    }

    /// 可用介面：en*（Wi-Fi / 乙太網路）與 bridge*（網際網路共享）。
    /// VPN（utun）、AirDrop（awdl）、自我指派位址（169.254.x.x）手機連不到，排除。
    static func candidateInterfaces() -> [Interface] {
        var result: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            result.append(Interface(name: name, address: ip))
        }
        // en0 優先，其次其他 en*，最後 bridge*
        return result.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ interface: Interface) -> Int {
        if interface.name == "en0" { return 0 }
        if interface.name.hasPrefix("en") { return 1 }
        return 2
    }

    static func preferredInterface(named preferred: String?) -> Interface? {
        let candidates = candidateInterfaces()
        if let preferred, let match = candidates.first(where: { $0.name == preferred }) {
            return match
        }
        return candidates.first
    }
}
