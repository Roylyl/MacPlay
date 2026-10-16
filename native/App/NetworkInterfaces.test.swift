import Foundation

@main struct NetworkInterfaceTests {
    static func main() {
        let wifi=NetworkInterfaceChoice(id:"en0",name:"Wi-Fi",wireless:true,active:true,ipv4:"192.0.2.1",linkLocalIPv6:"fe80::1%en0",hardwareAddress:nil,primary:false)
        let ethernet=NetworkInterfaceChoice(id:"en5",name:"Ethernet",wireless:false,active:true,ipv4:"192.0.2.2",linkLocalIPv6:"fe80::2%en5",hardwareAddress:nil,primary:true)
        let offline=NetworkInterfaceChoice(id:"en9",name:"Disconnected",wireless:false,active:false,ipv4:"192.0.2.3",linkLocalIPv6:nil,hardwareAddress:nil,primary:true)
        precondition(NetworkSelection.resolve(manual:false,name:"en9",interfaces:[offline,wifi,ethernet])?.id == "en5")
        precondition(NetworkSelection.resolve(manual:true,name:"en0",interfaces:[wifi,ethernet])?.id == "en0")
        precondition(NetworkSelection.resolve(manual:true,name:"en9",interfaces:[wifi,ethernet]) == nil)
        precondition(NetworkSelection.resolve(manual:true,name:"en9",interfaces:[wifi,offline])?.ready == false)
        let ipv4OnlyPrimary=NetworkInterfaceChoice(id:"en6",name:"IPv4 Ethernet",wireless:false,active:true,ipv4:"192.0.2.4",linkLocalIPv6:nil,hardwareAddress:nil,primary:true)
        precondition(NetworkSelection.resolve(manual:false,name:"",interfaces:[ipv4OnlyPrimary,wifi])?.id == "en6")
        precondition(NetworkInterfaceReader.isLinkLocalIPv6("fe80::1%en5"))
        precondition(NetworkInterfaceReader.isLinkLocalIPv6("febf::1"))
        precondition(!NetworkInterfaceReader.isLinkLocalIPv6("fec0::1"))
        precondition(!NetworkInterfaceReader.isLinkLocalIPv6("192.0.2.1"))
        func snapshot(password: String=" old: password ",channel: Int=36,interface: String="en0") -> NetworkInputSnapshot {
            NetworkInputSnapshot(mode:"manual",interface:interface,ssid:" Network: Name ",password:password,channel:channel,bssid:"00:11:22:33:44:55")
        }
        let original=snapshot(),guardValue=NetworkReadGuard(revision:5,input:original)
        precondition(guardValue.accepts(revision:5,input:original))
        precondition(!guardValue.accepts(revision:6,input:original)) // A→B→A still rejects the old read.
        precondition(!guardValue.accepts(revision:5,input:snapshot(password:"new")))
        precondition(!guardValue.accepts(revision:5,input:snapshot(channel:149)))
        precondition(!guardValue.accepts(revision:5,input:snapshot(interface:"en5")))
        precondition(original.ssid == " Network: Name " && original.password == " old: password ")
        var deferred=DeferredNetworkRead()
        deferred.enqueue(guardValue)
        precondition(deferred.takeIfIdle(reading:true,revision:5,input:original) == nil)
        precondition(deferred.takeIfIdle(reading:false,revision:5,input:original) != nil)
        precondition(deferred.takeIfIdle(reading:false,revision:5,input:original) == nil)
        deferred.enqueue(guardValue)
        precondition(deferred.takeIfIdle(reading:true,revision:6,input:original) == nil)
        precondition(deferred.takeIfIdle(reading:false,revision:5,input:original) == nil)
        deferred.enqueue(guardValue);deferred.cancel()
        precondition(deferred.takeIfIdle(reading:false,revision:5,input:original) == nil)
        let finished=DispatchSemaphore(value:0),calls=Calls()
        BoundedNetworkQuery.run(timeout:0.02,work:{Thread.sleep(forTimeInterval:0.08);return 1}) { result in
            calls.increment()
            if case .success = result {preconditionFailure("Timed out result must not be accepted")}
            finished.signal()
        }
        precondition(finished.wait(timeout:.now()+1) == .success)
        Thread.sleep(forTimeInterval:0.1)
        precondition(calls.count == 1)
        print("Network: default/manual selection, disconnected retention, IPv6, stale-read and bounded-query checks passed")
    }
}
private final class Calls: @unchecked Sendable {
    private let lock=NSLock();private var value=0
    func increment() {lock.lock();value+=1;lock.unlock()}
    var count: Int {lock.lock();defer {lock.unlock()};return value}
}
