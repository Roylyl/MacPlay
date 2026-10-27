// clang -fobjc-arc -framework Foundation -framework AppKit -framework IOBluetooth
// native/macplay-bluetooth/main.test.m -o /tmp/macplay-bluetooth-test
#define main bluetoothBridgeMain
#include "main.m"
#undef main
#import <objc/runtime.h>
#import <fcntl.h>

@interface TestService : NSObject
@end
@implementation TestService
- (IOReturn)getRFCOMMChannelID:(BluetoothRFCOMMChannelID *)channel { *channel=7; return kIOReturnSuccess; }
@end

@interface TestDevice : NSObject
@property NSString *name;
@property NSString *addressString;
@property BOOL hasService;
@property NSUInteger opens;
@property NSUInteger queries;
@property BOOL queryPending;
@end
@implementation TestDevice
- (id)getServiceRecordForUUID:(id)uuid { return self.hasService ? [TestService new] : nil; }
- (IOReturn)performSDPQuery:(id)delegate uuids:(NSArray *)uuids {
    self.queries++;
    if(!self.queryPending) [delegate sdpQueryComplete:(IOBluetoothDevice *)self status:kIOReturnSuccess];
    return kIOReturnSuccess;
}
- (IOReturn)openRFCOMMChannelAsync:(id *)channel withChannelID:(BluetoothRFCOMMChannelID)channelID delegate:(id)delegate {
    self.opens++;
    return kIOReturnNotReady;
}
@end

@interface TestChannel : NSObject
@property TestDevice *device;
@property NSUInteger closes;
@end
@implementation TestChannel
- (id)getDevice { return self.device; }
- (IOReturn)closeChannel { self.closes++; return kIOReturnSuccess; }
@end

static NSArray *devices;
static NSUInteger scans;
static NSArray *pairedDevices(id object,SEL selector) { scans++; return devices; }

static Bridge *bridge(void) {
    Bridge *value=[Bridge new];
    value.fd=-1;
    value.pending=[NSMutableDictionary dictionary];
    value.results=[NSMutableDictionary dictionary];
    return value;
}

int main(void) { @autoreleasepool {
    // Substitute the inventory before it can access the user's Bluetooth stack.
    Method paired=class_getClassMethod(IOBluetoothDevice.class,@selector(pairedDevices));
    IMP original=method_setImplementation(paired,(IMP)pairedDevices);
    TestDevice *phone=[TestDevice new];
    phone.name=@"小董的手机";phone.addressString=@"AA-BB-CC-DD-EE-01";phone.hasService=YES;
    TestDevice *headphones=[TestDevice new];
    headphones.name=@"Headphones";headphones.addressString=@"AA-BB-CC-DD-EE-02";
    devices=@[phone,headphones];
    Bridge *value=bridge();
    [value scan];
    NSCAssert(phone.opens==1,@"A renamed phone with iAP2 must be probed");
    NSCAssert(headphones.opens==0,@"A device without iAP2 must not open RFCOMM");
    NSCAssert([value.results[headphones.addressString] containsString:@"skipped"],@"An unrelated device must not report a connection failure");
    [value sdpQueryComplete:(IOBluetoothDevice *)headphones status:kIOReturnNotReady];
    NSCAssert(![value.results[headphones.addressString] containsString:@"failed"],@"Unrelated SDP failure must not become the selected phone's error");

    TestChannel *pending=[TestChannel new];pending.device=phone;
    value.channel=(IOBluetoothRFCOMMChannel *)pending;
    value.pending[phone.addressString]=@"pending";
    [value suspendConnections];
    NSCAssert(pending.closes==1 && value.channel==nil && value.pending.count==0,@"Cancel only unfinished connection attempts");
    NSUInteger before=scans;
    [value scan];
    [value sdpQueryComplete:(IOBluetoothDevice *)phone status:kIOReturnSuccess];
    NSCAssert(scans==before && phone.opens==1,@"A network session blocks scans and late SDP completion");
    TestChannel *late=[TestChannel new];late.device=phone;
    [value rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)late status:kIOReturnSuccess];
    [value attach:(IOBluetoothRFCOMMChannel *)late];
    NSCAssert(late.closes==2 && value.channel==nil,@"Late incoming and outgoing channels must not restart iAP2");

    Bridge *connected=bridge();
    TestChannel *active=[TestChannel new];active.device=phone;
    connected.channel=(IOBluetoothRFCOMMChannel *)active;connected.fd=123;
    [connected suspendConnections];
    [connected attach:(IOBluetoothRFCOMMChannel *)active];
    [connected rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)late];
    NSCAssert(connected.channel==(id)active && active.closes==0,@"Keep the established channel and ignore another channel's late close");

    Bridge *retrying=bridge();
    headphones.queryPending=YES;headphones.queries=0;devices=@[headphones];
    [retrying scan];
    NSString *oldQuery=retrying.pending[headphones.addressString];
    [retrying scan];
    NSCAssert(headphones.queries==1,@"Do not duplicate an outstanding service query");
    [retrying expireSDPQuery:(IOBluetoothDevice *)headphones token:oldQuery];
    [retrying scan];
    NSCAssert(headphones.queries==2,@"A timed-out device must be eligible for another scan");
    [retrying expireSDPQuery:(IOBluetoothDevice *)headphones token:oldQuery];
    NSCAssert(retrying.pending[headphones.addressString]!=nil,@"An old deadline must not expire the next query");

    Bridge *replaced=bridge();
    int oldPair[2],newPair[2];
    NSCAssert(socketpair(AF_UNIX,SOCK_STREAM,0,oldPair)==0 && socketpair(AF_UNIX,SOCK_STREAM,0,newPair)==0,@"Create local test sockets");
    replaced.channel=(id)late;replaced.fd=oldPair[0];
    [replaced rfcommChannelClosed:(id)late];
    NSCAssert(replaced.fd==-1 && replaced.channel==nil,@"A closed channel cannot retain socket ownership");
    replaced.channel=(id)active;replaced.fd=newPair[0];
    [replaced rfcommChannelOpenComplete:(id)late status:kIOReturnNotReady];
    NSCAssert(replaced.channel==(id)active && replaced.fd==newPair[0],@"An old open result must not affect a newer connection");
    [replaced finishChannel:(id)late socket:oldPair[0]];
    NSCAssert(fcntl(oldPair[0],F_GETFD)==-1,@"Always reclaim the old socket after its reader exits");
    NSCAssert(replaced.channel==(id)active && replaced.fd==newPair[0] && fcntl(newPair[0],F_GETFD)>=0,@"Old cleanup must not close or detach a new channel");
    [replaced finishChannel:(id)active socket:newPair[0]];
    NSCAssert(replaced.channel==nil && replaced.fd==-1,@"The current channel must release its state on EOF");
    close(oldPair[1]);close(newPair[1]);
    method_setImplementation(paired,original);
    puts("Bluetooth selection, handoff, retry and socket ownership passed (mock devices only)");
} return 0; }
