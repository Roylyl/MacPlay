import Foundation
@main struct ConnectionPolicyTests {
    static func main() {
        var policy=ReconnectBackoff()
        precondition((0..<8).map{_ in policy.nextDelay()} == [5,10,20,30,60,60,60,60])
        policy.reset();precondition(policy.nextDelay()==5)
        precondition(!ReconnectBackoff.permitted(enabled:true,successfulWirelessSession:false))
        precondition(!ReconnectBackoff.permitted(enabled:false,successfulWirelessSession:true))
        precondition(ReconnectBackoff.permitted(enabled:true,successfulWirelessSession:true))
        print("Reconnect: bounded backoff, reset, first-failure and disabled gates passed")
        let wireless=PhoneChoice(id:"bluetooth",name:"Renamed phone",bluetooth:"02:00:00:00:00:01")
        let usb=PhoneChoice(id:"usb",name:"iPhone",usb:"AB-CD")
        let other=PhoneChoice(id:"other",name:"iPhone",usb:"EE-FF")
        let choices=[wireless,usb,other]
        precondition(try! USBPhoneSelection.resolve(choices:choices,selectedID:nil,lastID:wireless.id,connectedIDs:["abcd"]) == usb)
        precondition(try! USBPhoneSelection.resolve(choices:choices,selectedID:nil,lastID:other.id,connectedIDs:["abcd"]) == usb)
        precondition(try! USBPhoneSelection.resolve(choices:choices,selectedID:nil,lastID:usb.id,connectedIDs:["abcd","eeff"]) == usb)
        precondition(try! USBPhoneSelection.resolve(choices:choices,selectedID:other.id,lastID:usb.id,connectedIDs:["abcd"]) == other)
        precondition(try! USBPhoneSelection.resolve(choices:choices,selectedID:nil,lastID:usb.id,connectedIDs:[]) == nil)
        do {
            _=try USBPhoneSelection.resolve(choices:choices,selectedID:nil,lastID:wireless.id,connectedIDs:["abcd","eeff"])
            preconditionFailure("Multiple connected phones must require a selection")
        } catch {precondition(error is USBPhoneSelection.Failure)}
        for selected in [wireless.id,"unknown"] {
            do {
                _=try USBPhoneSelection.resolve(choices:choices,selectedID:selected,lastID:usb.id,connectedIDs:["abcd"])
                preconditionFailure("An explicit selection must not silently connect another phone")
            } catch {precondition(error is USBPhoneSelection.Failure)}
        }
        print("USB selection: transport fallback, connected devices, explicit selection and ambiguity passed")
    }
}
