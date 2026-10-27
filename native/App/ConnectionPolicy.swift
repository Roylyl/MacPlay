import Foundation

struct PhoneChoice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var bluetooth: String? = nil
    var usb: String? = nil
}

enum USBPhoneSelection {
    enum Failure: Error { case ambiguous, missingRecord }

    static func resolve(choices: [PhoneChoice], selectedID: String?, lastID: String?, connectedIDs: Set<String>) throws -> PhoneChoice? {
        if let selectedID {
            guard let selected=choices.first(where:{$0.id==selectedID}),let usb=selected.usb,!usb.isEmpty else {throw Failure.missingRecord}
            return selected
        }
        func normalized(_ serial: String) -> String {serial.replacingOccurrences(of:"-",with:"").lowercased()}
        let connected=Set(connectedIDs.map(normalized))
        let available=choices.filter {phone in
            guard let usb=phone.usb else {return false}
            return connected.contains(normalized(usb))
        }
        if let last=available.first(where:{$0.id==lastID}) {return last}
        let serials=Set(available.compactMap(\.usb).map(normalized))
        guard serials.count<=1 else {throw Failure.ambiguous}
        return available.first
    }
}

struct ReconnectBackoff {
    private(set) var attempts=0
    mutating func nextDelay()->Int {
        let delay=[5,10,20,30,60][min(attempts,4)]
        attempts += 1
        return delay
    }
    mutating func reset(){attempts=0}
    static func permitted(enabled:Bool,successfulWirelessSession:Bool)->Bool {
        enabled && successfulWirelessSession
    }
}
