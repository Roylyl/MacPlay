#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <IOBluetooth/IOBluetooth.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <stdio.h>

@interface Bridge : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic,strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic,strong) IOBluetoothSDPServiceRecord *record;
@property(nonatomic,strong) IOBluetoothSDPServiceRecord *carplayRecord;
@property(nonatomic,strong) IOBluetoothUserNotification *carplayNotification;
@property(nonatomic,strong) IOBluetoothUserNotification *notification;
@property(nonatomic,strong) NSMutableDictionary *pending;
@property(nonatomic,strong) NSMutableDictionary *results;
@property(nonatomic,assign) IOReturn advertiseResult;
@property(nonatomic,assign) BOOL attaching;
@property(nonatomic,assign) BOOL networkConnected;
@property(nonatomic,assign) int fd;
@property(nonatomic,strong) NSString *path;
@end
@implementation Bridge
- (BOOL)isSelectedDevice:(IOBluetoothDevice *)device {
    NSString *target=NSProcessInfo.processInfo.environment[@"MACPLAY_TARGET_BT"];
    NSString *address=[device.addressString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
    return target.length && [target.lowercaseString isEqual:address.lowercaseString];
}
- (void)suspendConnections {
    if(self.networkConnected) return;
    self.networkConnected=YES;
    [self.pending removeAllObjects];
    // Keep an established iAP2 channel until the phone releases it. A pending
    // outbound connection must not restart the handshake after Wi-Fi takes over.
    if(self.channel && self.fd<0) {
        IOBluetoothRFCOMMChannel *channel=self.channel;
        self.channel=nil;
        [channel closeChannel];
    }
    NSLog(@"MacPlay Bluetooth discovery paused: network session established");
}
- (void)finishChannel:(IOBluetoothRFCOMMChannel *)channel socket:(int)fd {
    if(self.fd==fd && self.channel==channel) {
        self.fd=-1;
        self.channel=nil;
        [channel closeChannel];
    }
    close(fd);
}
- (void)attach:(IOBluetoothRFCOMMChannel *)channel {
    if(self.networkConnected) {
        if(self.channel!=channel || self.fd<0) [channel closeChannel];
        return;
    }
    NSString *target=NSProcessInfo.processInfo.environment[@"MACPLAY_TARGET_BT"];
    NSString *address=[[[channel getDevice] addressString] stringByReplacingOccurrencesOfString:@"-" withString:@":"];
    if(target.length && ![target.lowercaseString isEqual:address.lowercaseString]) {[channel closeChannel];return;}
    if(self.attaching || (self.channel==channel && self.fd>=0)) return;
    if (self.channel && self.channel != channel) { [channel closeChannel]; return; }
    self.attaching=YES;
    self.channel = channel;
    [channel setDelegate:self];
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, self.path.UTF8String, sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); [channel closeChannel]; self.channel=nil; self.attaching=NO; return; }
    int one=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    self.fd=fd;
    self.attaching=NO;
    NSString *line=[NSString stringWithFormat:@"%@|%@\n", [[IOBluetoothHostController defaultController] addressAsString], [[channel getDevice] addressString]];
    NSData *header=[line dataUsingEncoding:NSUTF8StringEncoding]; send(fd,header.bytes,header.length,0);
    NSLog(@"MacPlay RFCOMM connected: %@",[[channel getDevice] name]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        uint8_t buf[1024]; ssize_t count;
        while ((count=recv(fd,buf,sizeof(buf),0))>0) {
            NSData *data=[NSData dataWithBytes:buf length:count];
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (self.fd != fd) return;
                const uint8_t *bytes=data.bytes; NSUInteger offset=0;
                while(offset<data.length) {
                    UInt16 size=(UInt16)MIN(data.length-offset,[channel getMTU]);
                    if (!size || [channel writeSync:(void *)(bytes+offset) length:size] != kIOReturnSuccess) { shutdown(fd,SHUT_RDWR); break; }
                    offset+=size;
                }
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishChannel:channel socket:fd]; });
    });
}
- (void)opened:(IOBluetoothUserNotification *)note channel:(IOBluetoothRFCOMMChannel *)channel { [self attach:channel]; }
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status {
    if(self.channel && self.channel!=channel) { [channel closeChannel]; return; }
    [self.pending removeObjectForKey:[[channel getDevice] addressString]];
    if(self.networkConnected) {
        if(self.channel!=channel || self.fd<0) {
            if(self.channel==channel) self.channel=nil;
            [channel closeChannel];
        }
        return;
    }
    if(status==kIOReturnSuccess) [self attach:channel];
    else {
        [self rfcommChannelClosed:channel];
        NSLog(@"MacPlay RFCOMM open error: %d",status);
    }
}
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)dataPointer length:(size_t)dataLength {
    if(self.channel!=channel || self.fd<0) return; size_t sent=0;
    while(sent<dataLength) { ssize_t n=send(self.fd,(uint8_t *)dataPointer+sent,dataLength-sent,0); if(n<=0) {shutdown(self.fd,SHUT_RDWR);break;} sent+=n; }
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    if(self.channel!=channel) return;
    if(self.fd>=0) { shutdown(self.fd,SHUT_RDWR); self.fd=-1; }
    self.channel=nil;
}
- (void)expireSDPQuery:(IOBluetoothDevice *)device token:(NSString *)token {
    if(self.networkConnected || ![self.pending[device.addressString] isEqual:token]) return;
    [self.pending removeObjectForKey:device.addressString];
    if([self isSelectedDevice:device]) NSLog(@"MacPlay Bluetooth SDP timed out; confirm pairing on both devices");
    else NSLog(@"MacPlay Bluetooth device skipped after SDP timeout: %@",device.name);
}
- (void)queryService:(IOBluetoothDevice *)device UUID:(IOBluetoothSDPUUID *)uuid {
    NSString *token=NSUUID.UUID.UUIDString;
    self.pending[device.addressString]=token;
    IOReturn status=[device performSDPQuery:self uuids:@[uuid]];
    if(status!=kIOReturnSuccess) [self sdpQueryComplete:device status:status];
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        [self expireSDPQuery:device token:token];
    });
}
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    [self.pending removeObjectForKey:[device addressString]];
    if(self.networkConnected || self.channel) return;
    NSString *result;
    if(status!=kIOReturnSuccess) {
        result=[NSString stringWithFormat:[self isSelectedDevice:device] ? @"Bluetooth SDP failed for %@: %d" : @"Bluetooth device skipped after SDP query (%@, status=%d)",device.name,status];
        if(![self.results[device.addressString] isEqual:result]) NSLog(@"MacPlay %@",result);
        self.results[device.addressString]=result;
        return;
    }
    unsigned char raw[]={0,0,0,0,0xde,0xca,0xfa,0xde,0xde,0xca,0xde,0xaf,0xde,0xca,0xca,0xfe};
    IOBluetoothSDPUUID *serviceUUID=[IOBluetoothSDPUUID uuidWithBytes:raw length:16];
    IOBluetoothSDPServiceRecord *record=[device getServiceRecordForUUID:serviceUUID];
    BluetoothRFCOMMChannelID channelID=0;
    if(record && [record getRFCOMMChannelID:&channelID]==kIOReturnSuccess) {
        NSLog(@"MacPlay iAP2 service found: %@ channel=%u",device.name,channelID);
        IOBluetoothRFCOMMChannel *channel=nil;
        IOReturn result=[device openRFCOMMChannelAsync:&channel withChannelID:channelID delegate:self];
        if(result==kIOReturnSuccess) {
            self.channel=channel;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                if(!self.networkConnected && self.channel==channel && self.fd<0) {
                    NSLog(@"MacPlay Bluetooth RFCOMM timed out; refreshing iPhone service records");
                    [channel closeChannel];self.channel=nil;
                    self.results[device.addressString]=@"refresh";
                    [self queryService:device UUID:serviceUUID];
                }
            });
        }
        else NSLog(@"MacPlay RFCOMM request failed: %d", result);
    } else {
        result=[NSString stringWithFormat:[self isSelectedDevice:device] ? @"Bluetooth iAP2 service unavailable for %@; open CarPlay settings on iPhone" : @"Bluetooth device skipped: %@ does not advertise iAP2",device.name];
        if(![self.results[device.addressString] isEqual:result]) NSLog(@"MacPlay %@",result);
        self.results[device.addressString]=result;
    }
}
- (void)scan {
    if(self.networkConnected || self.channel) return;
    for(IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
        if(self.channel) return;
        NSString *target=NSProcessInfo.processInfo.environment[@"MACPLAY_TARGET_BT"];
        NSString *address=[device.addressString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
        if(target.length && ![target.lowercaseString isEqual:address.lowercaseString]) continue;
        if(!address.length || self.pending[device.addressString]) continue;
        unsigned char raw[]={0,0,0,0,0xde,0xca,0xfa,0xde,0xde,0xca,0xde,0xaf,0xde,0xca,0xca,0xfe};
        IOBluetoothSDPUUID *uuid=[IOBluetoothSDPUUID uuidWithBytes:raw length:16];
        if(![self.results[device.addressString] isEqual:@"refresh"] && [device getServiceRecordForUUID:uuid]) { [self sdpQueryComplete:device status:kIOReturnSuccess]; continue; }
        if(!self.results[device.addressString]) {NSLog(@"MacPlay querying iAP2 Bluetooth service: %@",device.name ?: address);self.results[device.addressString]=@"querying";}
        [self queryService:device UUID:uuid];
    }
}
- (void)start {
    self.fd=-1; self.pending=[NSMutableDictionary dictionary]; self.results=[NSMutableDictionary dictionary];
    NSLog(@"MacPlay paired Bluetooth devices: %lu",(unsigned long)[IOBluetoothDevice pairedDevices].count);
    // Apple's public API temporarily advertises the receiver as an in-car A/V device.
    // The controller automatically restores its original class after the interval.
    self.advertiseResult=[[IOBluetoothHostController defaultController] setClassOfDevice:0x200408 forTimeInterval:120];
    NSLog(@"MacPlay CarPlay Bluetooth device class result: %d",self.advertiseResult);
    if(self.advertiseResult==kIOReturnSuccess) [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *timer){
        IOReturn result=[[IOBluetoothHostController defaultController] setClassOfDevice:0x200408 forTimeInterval:120];
        if(result!=self.advertiseResult) NSLog(@"MacPlay CarPlay Bluetooth device class result: %d",result);
        self.advertiseResult=result;
    }];
    unsigned char raw[]={0,0,0,0,0xde,0xca,0xfa,0xde,0xde,0xca,0xde,0xaf,0xde,0xca,0xca,0xff};
    self.record=[IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:@{
        @"0001":@[[IOBluetoothSDPUUID uuidWithBytes:raw length:16]],
        @"0004":@[@[[IOBluetoothSDPUUID uuid16:0x0100]],@[[IOBluetoothSDPUUID uuid16:0x0003],@{ @"DataElementType":@1,@"DataElementSize":@1,@"DataElementValue":@18 }]],
        @"0100":@"MacPlay", @"LocalAttributes":@{@"Persistent":@NO}
    }];
    unsigned char cpUUID[]={0xec,0x88,0x43,0x48,0xcd,0x41,0x40,0xa2,0x97,0x27,0x57,0x5d,0x50,0xbf,0x1f,0xd3};
    self.carplayRecord=[IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:@{
        @"0001":@[[IOBluetoothSDPUUID uuidWithBytes:cpUUID length:16]],
        @"0004":@[@[[IOBluetoothSDPUUID uuid16:0x0100]],@[[IOBluetoothSDPUUID uuid16:0x0003],@{@"DataElementType":@1,@"DataElementSize":@1,@"DataElementValue":@19}]],
        @"0005":@[[IOBluetoothSDPUUID uuid16:0x1002]],@"0100":@"MacPlay CarPlay"
    }];
    BluetoothRFCOMMChannelID cpChannel=0;
    if(self.carplayRecord && [self.carplayRecord getRFCOMMChannelID:&cpChannel]==kIOReturnSuccess)
        self.carplayNotification=[IOBluetoothRFCOMMChannel registerForChannelOpenNotifications:self selector:@selector(opened:channel:) withChannelID:cpChannel direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    BluetoothRFCOMMChannelID channelID=0;
    if(self.record && [self.record getRFCOMMChannelID:&channelID]==kIOReturnSuccess) {
        self.notification=[IOBluetoothRFCOMMChannel registerForChannelOpenNotifications:self selector:@selector(opened:channel:) withChannelID:channelID direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
        NSLog(@"MacPlay Bluetooth service registered on channel %u",channelID);
    } else NSLog(@"MacPlay Bluetooth service registration failed");
    [NSTimer scheduledTimerWithTimeInterval:12 repeats:YES block:^(NSTimer *timer){ [self scan]; }];
    [self scan];
}
@end
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2) return 2;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    Bridge *bridge=[Bridge new]; bridge.path=[NSString stringWithUTF8String:argv[1]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        char *line=NULL; size_t capacity=0;
        while(getline(&line,&capacity,stdin)>=0) {
            if(strcmp(line,"network-connected\n")==0)
                dispatch_async(dispatch_get_main_queue(),^{[bridge suspendConnections];});
        }
        free(line);
    });
    // IOBluetooth initializes CoreBluetooth synchronously and waits for callbacks.
    // Bootstrap off the main thread while AppKit services the main run loop.
    NSLog(@"MacPlay Bluetooth bridge initializing");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        [IOBluetoothDevice pairedDevices];
        dispatch_async(dispatch_get_main_queue(),^{[bridge start];});
    });
    [NSApp run];
} return 0; }
