import Foundation
import CoreWLAN
import SystemConfiguration
import Darwin

struct NetworkInterfaceChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let wireless: Bool
    let active: Bool
    let ipv4: String?
    let linkLocalIPv6: String?
    let hardwareAddress: String?
    let primary: Bool
    var ready: Bool { active && (ipv4 != nil || linkLocalIPv6 != nil) }
}

struct NetworkInventory: Sendable {
    let interfaces: [NetworkInterfaceChoice]
    let error: String?
}

struct WiFiNetworkDetails: Sendable {
    let interface: String
    let powered: Bool
    let ssid: String?
    let bssid: String?
    let channel: Int?
    let enterprise: Bool
}

struct NetworkInputSnapshot: Equatable, Sendable {
    let mode: String
    let interface: String
    let ssid: String
    let password: String
    let channel: Int
    let bssid: String?
}

struct NetworkReadGuard: Sendable {
    let revision: UInt64
    let input: NetworkInputSnapshot
    func accepts(revision: UInt64, input: NetworkInputSnapshot) -> Bool {
        self.revision == revision && self.input == input
    }
}

/// A permission callback can race the refresh started when the app regains
/// focus. Keep its original input guard until the current query finishes.
struct DeferredNetworkRead {
    private var request: NetworkReadGuard?
    mutating func enqueue(_ value: NetworkReadGuard) { request = value }
    mutating func cancel() { request = nil }
    mutating func takeIfIdle(reading: Bool, revision: UInt64, input: NetworkInputSnapshot) -> NetworkReadGuard? {
        guard let value = request else { return nil }
        guard value.accepts(revision: revision, input: input) else {request = nil;return nil}
        guard !reading else { return nil }
        request = nil
        return value
    }
}

enum NetworkSelection {
    static func resolve(manual: Bool, name: String, interfaces: [NetworkInterfaceChoice]) -> NetworkInterfaceChoice? {
        if manual { return interfaces.first { $0.id == name } }
        return interfaces.sorted {
            let leftEligible = $0.ready
            let rightEligible = $1.ready
            if leftEligible != rightEligible { return leftEligible }
            if $0.ready != $1.ready { return $0.ready }
            if $0.primary != $1.primary { return $0.primary }
            if $0.wireless != $1.wireless { return $0.wireless }
            return $0.id < $1.id
        }.first
    }
}

enum NetworkInterfaceReader {
    /// Native address enumeration does not depend on Wi-Fi/location authorization.
    static func read() -> NetworkInventory {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return NetworkInventory(interfaces: [], error: "ADDRESSES_\(errno)") }
        defer { freeifaddrs(head) }
        struct Addresses { var active = false; var ipv4: String?; var ipv6: String? }
        var addresses: [String: Addresses] = [:]
        var pointer = head
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let entry = current.pointee
            guard let raw = entry.ifa_addr, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            var item = addresses[name] ?? Addresses()
            item.active = entry.ifa_flags & UInt32(IFF_UP) != 0 && entry.ifa_flags & UInt32(IFF_RUNNING) != 0
            if raw.pointee.sa_family == UInt8(AF_INET) || raw.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(raw, socklen_t(raw.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if raw.pointee.sa_family == UInt8(AF_INET), !value.hasPrefix("169.254."), !value.hasPrefix("127."), value != "0.0.0.0" { item.ipv4 = value }
                    if raw.pointee.sa_family == UInt8(AF_INET6), isLinkLocalIPv6(value) { item.ipv6 = value }
                }
            }
            addresses[name] = item
        }
        guard let metadata = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return NetworkInventory(interfaces: [], error: "INTERFACE_METADATA_UNAVAILABLE")
        }
        let store = SCDynamicStoreCreate(nil, "MacPlay network selection" as CFString, nil, nil)
        let primary: String? = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].compactMap { key in
            guard let store, let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { return nil }
            return value["PrimaryInterface"] as? String
        }.first
        var seen = Set<String>()
        let choices = metadata.compactMap { interface -> NetworkInterfaceChoice? in
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let kind = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  kind == (kSCNetworkInterfaceTypeIEEE80211 as String) || kind == (kSCNetworkInterfaceTypeEthernet as String),
                  seen.insert(name).inserted else { return nil }
            let address = addresses[name] ?? Addresses()
            return NetworkInterfaceChoice(id: name, name: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? name,
                wireless: kind == (kSCNetworkInterfaceTypeIEEE80211 as String), active: address.active,
                ipv4: address.ipv4, linkLocalIPv6: address.ipv6,
                hardwareAddress: SCNetworkInterfaceGetHardwareAddressString(interface) as String?, primary: name == primary)
        }
        return NetworkInventory(interfaces: choices.sorted { $0.id < $1.id }, error: nil)
    }

    static func isLinkLocalIPv6(_ value: String) -> Bool {
        let address = String(value.split(separator: "%", maxSplits: 1).first ?? "")
        var parsed = in6_addr()
        guard inet_pton(AF_INET6, address, &parsed) == 1 else { return false }
        return withUnsafeBytes(of: parsed) { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }
    }

    static func wifiDetails(interface name: String) -> WiFiNetworkDetails? {
        guard let interface = CWWiFiClient.shared().interface(withName: name) else { return nil }
        return WiFiNetworkDetails(interface: name, powered: interface.powerOn(), ssid: interface.ssid(),
            bssid: interface.bssid(), channel: interface.wlanChannel().map { Int($0.channelNumber) },
            enterprise: [7,8,9,10,12].contains(Int(interface.security().rawValue)))
    }
}

enum NetworkQueryFailure: Error { case timeout }

/// CoreWLAN may wait for a system service. Bound the UI wait and discard late
/// results; the address inventory remains usable if only Wi-Fi details fail.
enum BoundedNetworkQuery {
    static func run<Value: Sendable>(timeout: TimeInterval = 4, work: @escaping @Sendable () -> Value,
                                    completion: @escaping @Sendable (Result<Value, NetworkQueryFailure>) -> Void) {
        let gate = NetworkQueryGate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if gate.finish() { completion(.failure(.timeout)) }
        }
        DispatchQueue.global(qos: .utility).async {
            let value = work()
            if gate.finish() { completion(.success(value)) }
        }
    }
}

private final class NetworkQueryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}
