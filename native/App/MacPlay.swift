import SwiftUI
import AppKit
import CoreWLAN
import CoreLocation
import IOKit
import IOBluetooth
import Combine
import Security
import CoreAudio
import MediaPlayer
import Darwin

struct DisplayChoice: Identifiable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
    let builtIn: Bool
    let refresh: Double
    let size: CGSize
    var pixelsVerified: Bool
    var label: String { pixelsVerified ? "\(name)（\(width)×\(height)）" : name }
    var details: String {
        var items = [L(builtIn ? "内建显示器" : "外接显示器")]
        items.append(pixelsVerified ? "\(width)×\(height)" + L("物理像素") : L("物理像素尚未确认"))
        if refresh > 0 { items.append("\(Int(refresh))Hz") }
        if size.width > 0 && size.height > 0 { items.append("\(Int(size.width))×\(Int(size.height))mm") }
        return items.joined(separator: " · ")
    }
}
struct AudioChoice: Identifiable { let id: String; let name: String }


struct PlaySettings: Codable, Equatable {
    var language: String? = nil
    var autoReconnect: Bool? = nil
    var autoStartUSB: Bool? = nil
    var backgroundEnabled: Bool? = nil
    var closeBehavior: String? = nil
    var displayID: UInt32? = nil
    var inputDevice: String? = nil
    var outputDevice: String? = nil
    var callVolume: Double? = nil
    var strictPixels: Bool? = nil
    var resolution = "1280x720"
    var width = 1280
    var height = 720
    var screenPixelWidth: Int? = nil
    var screenPixelHeight: Int? = nil
    var screenWidthMm: Double? = nil
    var screenHeightMm: Double? = nil
    var screenPixelsVerified: Bool? = nil
    var screenLogicalWidth: Double? = nil
    var screenLogicalHeight: Double? = nil
    var presentationWidth: Double? = nil
    var presentationHeight: Double? = nil
    var fps = 60
    var selectedPhone: String? = nil
    var lastPhone: String? = nil
    var phones: [PhoneChoice]? = nil
    var targetBluetooth: String? = nil
    var targetUSB: String? = nil
    var wireless = false
    var ssid = ""
    var password = ""
    var channel = 36
    var wifiInterface = "en0"
    var networkInterfaceMode: String? = nil
    var wifiMAC = ""
    var accessPointMAC: String? = nil
    var accessPointOverride: String? = nil
    var bluetoothMAC = ""
    var audioEnabled = true
    var volume = 1.0
}

@MainActor final class PlayModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var settings = PlaySettings() {
        didSet {
            if networkInput(oldValue) != networkInput(settings) { networkInputRevision &+= 1 }
        }
    }
    @Published var displays: [DisplayChoice] = []
    @Published var displayLoading = false
    @Published var displayStatus = ""
    private var displayRequest = 0
    private var lastDisplayPixels: [UInt32: DisplayPixels] = [:]
    @Published private var displayDeferredUSB = Set<String>()
    private var audioMonitor: AudioHardwareMonitor?
    @Published var mediaStatistics: [String:Any] = [:]
    @Published var preparingConnection = false
    private var startRequest: UInt64 = 0
    @Published var audioInputs: [AudioChoice] = []
    @Published var audioOutputs: [AudioChoice] = []
    private var nowPlaying: [String:Any] = [:]
    private var playingState=NowPlayingState()
    private var metadataFeed:NowPlayingFeed?
    private var mediaDiagnostic=""
    private var artworkBytes: Data?
    private var pendingSeekID: String?
    private var remoteTargets: [Any] = []
    @Published var status = "尚未启动接收"
    @Published var detail = "连接iPhone后启动接收端。"
    @Published var frameRateFallbackNote = ""
    private var reconnectTimer:Timer?
    private var reconnectBackoff=ReconnectBackoff()
    private var reconnectCycle=false
    private var successfulSettings:PlaySettings?
    private var appliedSettings:PlaySettings?
    private var attemptID=""
    private var attemptStart=Date()
    private var logWrite:DispatchWorkItem?
    private var mediaPublish:DispatchWorkItem?
    private var fallbackQueued=false
    var receivingOrWaiting:Bool {running || preparingConnection || reconnectCycle || !displayDeferredUSB.isEmpty}
    @Published var running = false
    @Published var page:Page? = .connection
    @Published var logs = ""
    @Published var credentialsReady = false
    @Published var readingPassword = false
    @Published var networkStatus = "尚未读取网络"
    @Published var networkInterfaces: [NetworkInterfaceChoice] = []
    @Published var readingNetwork = false
    private var networkInputRevision: UInt64 = 0
    private var networkQueryID: UInt64 = 0
    private var networkInventoryError: String?
    private var wifiDetails: WiFiNetworkDetails?
    @Published var passwordStatus = ""
    @Published var phoneChoices: [PhoneChoice] = []
    @Published var usbDevices: [String] = []
    @Published var usbStage = "接收服务未启动"
    @Published var usbError = ""
    private let locationManager = CLLocationManager()
    private var networkRequestPending = false
    private var networkPermissionGuard: NetworkReadGuard?
    private var deferredNetworkRead = DeferredNetworkRead()
    private var usbTimer: Timer?
    private var connectedUSBIDs = Set<String>()
    var currentUSBIDs:Set<String> {connectedUSBIDs}
    private var automaticStartReady = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pending = Data()
    private var logRedactor=DiagnosticRedactor.Stream()
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacPlay")
    var authDirectory: URL { directory.appendingPathComponent("authentication") }
    var configURL: URL { directory.appendingPathComponent("settings.json") }
    var logURL: URL { directory.appendingPathComponent("MacPlay.log") }
    override init() {
        super.init()
        locationManager.delegate = self
        try? FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: configURL), let decoded = try? JSONDecoder().decode(PlaySettings.self, from:data) { settings = decoded }
        if settings.closeBehavior == nil {settings.closeBehavior = FileManager.default.fileExists(atPath:configURL.path) ? (settings.backgroundEnabled == true ? "background" : "quit") : "ask"}
        if settings.networkInterfaceMode == nil { settings.networkInterfaceMode = settings.wifiInterface == "en0" ? "auto" : "manual" }
        MacPlayLocalization.language=settings.language ?? "system"
        if ![30,60,90,120].contains(settings.fps) { settings.fps=60 }
        if settings.resolution == "1920x720" { settings.resolution="custom" }
        if settings.resolution == "3840x2160" { settings.resolution="native" }
        configureRemoteCommands(); refreshHardware(); installBundledCredentials(); updateResolution(); inspectCredentials(); detectNetwork(); refreshUSB()
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in Task { @MainActor in self?.refreshHardware(); self?.updateResolution() }}
        audioMonitor=AudioHardwareMonitor { [weak self] inputChanged,outputChanged in
            Task { @MainActor in self?.audioHardwareChanged(inputChanged:inputChanged,outputChanged:outputChanged) }
        }
        usbTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUSB() }
        }
    }
    var selectedScreen: NSScreen? {
        NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==settings.displayID}) ?? NSScreen.screens.first
    }
    func installBundledCredentials() {
        guard let bundled=Bundle.main.resourceURL?.appendingPathComponent("authentication") else {return}
        let names=["identity.pk8","certificate.p7b"]
        guard names.allSatisfy({!FileManager.default.fileExists(atPath:authDirectory.appendingPathComponent($0).path)}) else {return}
        for name in names {
            let target=authDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:target.path),let data=try? Data(contentsOf:bundled.appendingPathComponent(name)) {
                try? data.write(to:target,options:.atomic)
                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
            }
        }
    }
    private var screenSignature: String {
        NSScreen.screens.map { "\($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0):\($0.frame):\($0.backingScaleFactor)" }.joined(separator: "|")
    }
    var exactDisplayAvailable: Bool {
        guard let panel=displays.first(where:{$0.id==settings.displayID}) else {return false}
        return DisplayCapabilities.permitsExactPixels(verified:panel.pixelsVerified,widthMm:panel.size.width,heightMm:panel.size.height,loading:displayLoading)
    }
    private func captureDisplays(confirmed: [UInt32:DisplayPixels]) {
        displays=NSScreen.screens.compactMap { screen in
            guard let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {return nil}
            let mode=CGDisplayCopyDisplayMode(id), pixels=confirmed[id] ?? lastDisplayPixels[id]
            return DisplayChoice(id:id,name:screen.localizedName,width:pixels?.width ?? mode?.pixelWidth ?? Int(screen.frame.width*screen.backingScaleFactor),height:pixels?.height ?? mode?.pixelHeight ?? Int(screen.frame.height*screen.backingScaleFactor),builtIn:CGDisplayIsBuiltin(id) != 0,refresh:mode?.refreshRate ?? 0,size:CGDisplayScreenSize(id),pixelsVerified:confirmed[id] != nil)
        }.sorted { $0.builtIn && !$1.builtIn }
        if !displays.contains(where:{$0.id==settings.displayID}) {settings.displayID=displays.first?.id}
    }
    func refreshDisplays() {
        displayRequest += 1
        let request=displayRequest, signature=screenSignature
        displayLoading=true;displayStatus="正在读取显示器参数…"
        captureDisplays(confirmed:[:]);updateResolution()
        Task {
            let result=await Task.detached(priority:.utility) {
                BoundedSystemQuery.run(executable:"/usr/sbin/system_profiler",arguments:["SPDisplaysDataType","-json"])
            }.value
            guard request==displayRequest else {return}
            guard signature==screenSignature else {refreshDisplays();return}
            displayLoading=false
            let confirmed=result.error == nil ? DisplayCapabilities.parse(result.data) : nil
            if let confirmed {lastDisplayPixels.merge(confirmed){_,new in new}}
            captureDisplays(confirmed:confirmed ?? [:])
            if !exactDisplayAvailable {
                settings.strictPixels=false
                if settings.resolution=="native" {settings.resolution="custom"}
                displayStatus=result.error=="TIMEOUT" ? "显示器查询超时，可使用普通窗口模式或重新读取。" : "无法确认显示器物理参数，可使用普通窗口模式或重新读取。"
            } else {displayStatus=""}
            appendDiagnostic("display-query result=\(result.error ?? (confirmed == nil ? "INVALID_OUTPUT" : "OK")) displays=\(displays.count)")
            updateResolution()
            let devices=displayDeferredUSB.intersection(connectedUSBIDs)
            displayDeferredUSB.removeAll()
            startForUSBIfNeeded(devices)
        }
    }
    func selectDisplay(_ id: UInt32) {
        settings.displayID=id
        if !displayLoading && !exactDisplayAvailable {
            settings.strictPixels=false
            if settings.resolution=="native" {settings.resolution="custom"}
            displayStatus="无法确认显示器物理参数，可使用普通窗口模式或重新读取。"
        } else if exactDisplayAvailable {displayStatus=""}
        updateResolution()
    }
    func refreshHardware() {
        refreshDisplays();refreshAudioDevices()
    }
    func refreshAudioDevices() {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var bytes: UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&bytes)==noErr else {return}
        var ids=[AudioDeviceID](repeating:0,count:Int(bytes)/MemoryLayout<AudioDeviceID>.size)
        let result=ids.withUnsafeMutableBytes {AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&bytes,$0.baseAddress!)}
        guard result==noErr else {return}
        func string(_ id:AudioDeviceID,_ selector:AudioObjectPropertySelector)->String? {
            var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var value:Unmanaged<CFString>?;var size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&value)==noErr else {return nil}
            return value?.takeUnretainedValue() as String?
        }
        func hasStreams(_ id:AudioDeviceID,_ scope:AudioObjectPropertyScope)->Bool {
            var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:scope,mElement:kAudioObjectPropertyElementMain);var size:UInt32=0
            return AudioObjectGetPropertyDataSize(id,&a,0,nil,&size)==noErr && size>0
        }
        audioInputs=[];audioOutputs=[]
        for id in ids {
            guard let uid=string(id,kAudioDevicePropertyDeviceUID),let name=string(id,kAudioObjectPropertyName) else {continue}
            let choice=AudioChoice(id:uid,name:name)
            if hasStreams(id,kAudioObjectPropertyScopeInput){audioInputs.append(choice)}
            if hasStreams(id,kAudioObjectPropertyScopeOutput){audioOutputs.append(choice)}
        }
        if let uid=settings.inputDevice,!uid.isEmpty,!audioInputs.contains(where:{$0.id==uid}){settings.inputDevice=nil}
        if let uid=settings.outputDevice,!uid.isEmpty,!audioOutputs.contains(where:{$0.id==uid}){settings.outputDevice=nil}
    }
    func audioHardwareChanged(inputChanged: Bool, outputChanged: Bool) {
        let oldInput=settings.inputDevice ?? "",oldOutput=settings.outputDevice ?? ""
        refreshAudioDevices()
        let inputLost=oldInput != (settings.inputDevice ?? ""),outputLost=oldOutput != (settings.outputDevice ?? "")
        applyAudioDevices(inputChanged:inputLost || (inputChanged && oldInput.isEmpty),outputChanged:outputLost || (outputChanged && oldOutput.isEmpty))
    }
    func applyAudioDevices(inputChanged: Bool = true, outputChanged: Bool = true) {
        if inputChanged {appliedSettings?.inputDevice=settings.inputDevice;successfulSettings?.inputDevice=settings.inputDevice}
        if outputChanged {appliedSettings?.outputDevice=settings.outputDevice;successfulSettings?.outputDevice=settings.outputDevice}
        persistPreferences()
        guard inputChanged || outputChanged else {return}
        let message:[String:Any]=["command":"audio-devices","inputDevice":settings.inputDevice ?? "","outputDevice":settings.outputDevice ?? "","inputChanged":inputChanged,"outputChanged":outputChanged]
        if let data=try? JSONSerialization.data(withJSONObject:message),let line=String(data:data,encoding:.utf8){command(line)}
    }
    var videoStatisticsText: String {
        guard let video=mediaStatistics["video"] as? [String:Any],let width=video["width"] as? Int,let height=video["height"] as? Int,width>0,height>0 else {return "—"}
        return "\(width)×\(height)"
    }
    func statisticFPS(_ key: String) -> String {
        guard let video=mediaStatistics["video"] as? [String:Any],let value=video[key] as? NSNumber else {return "—"}
        return String(format:"%.1ffps",value.doubleValue)
    }
    var attemptedFPS: Int {appliedSettings?.fps ?? settings.fps}
    var audioFormatText: String {
        guard let streams=mediaStatistics["audio"] as? [[String:Any]], !streams.isEmpty else {return "—"}
        return Array(Set(streams.compactMap { item -> String? in
            guard let codec=item["codec"] as? String,let rate=item["sampleRate"] as? NSNumber,let channels=item["channels"] as? NSNumber else {return nil}
            return "\(codec.uppercased()) · \(rate.intValue)Hz · \(channels.intValue)ch"
        })).sorted().joined(separator:" / ")
    }
    func applyLiveAudio() {
        appliedSettings?.volume=settings.volume;appliedSettings?.callVolume=settings.callVolume;appliedSettings?.audioEnabled=settings.audioEnabled
        successfulSettings?.volume=settings.volume;successfulSettings?.callVolume=settings.callVolume;successfulSettings?.audioEnabled=settings.audioEnabled
        let message:[String:Any]=["command":"audio","volume":settings.volume,"callVolume":settings.callVolume ?? 1,"enabled":settings.audioEnabled]
        if let data=try? JSONSerialization.data(withJSONObject:message),let line=String(data:data,encoding:.utf8){command(line)}
        if let data=try? JSONEncoder().encode(settings){try? data.write(to:configURL,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)}
    }
    func showCarPlayWindow() {
        guard let task=process,task.isRunning else {return}
        MacPlayApplicationDelegate.shared?.prepareCarPlayPresentation()
        if let receiver=NSRunningApplication(processIdentifier:task.processIdentifier) {
            NSApp.yieldActivation(to:receiver)
            receiver.activate(options:.activateIgnoringOtherApps)
        }
        command("show")
    }
    func showMainWindow() {
        if MacPlayApplicationDelegate.shared?.restoreMainWindow() == true {return}
        NSApp.activate()
        for window in NSApp.windows where !(window is NSPanel) && (window.canBecomeMain || window.isMiniaturized) {
            if window.isMiniaturized {window.deminiaturize(nil)}
            window.makeKeyAndOrderFront(nil)
        }
    }
    func persistPreferences() {
        guard let data=try? JSONEncoder().encode(settings) else {return}
        try? data.write(to:configURL,options:.atomic)
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)
    }
    func setLanguage(_ value:String) {
        guard ["system","zh-Hans","zh-Hant","en"].contains(value) else {return}
        MacPlayLocalization.language=value
        settings.language=value
        persistPreferences()
        if let data=try? JSONSerialization.data(withJSONObject:["command":"language","language":MacPlayLocalization.effectiveLanguage]),let line=String(data:data,encoding:.utf8){command(line)}
        MacPlayApplicationDelegate.shared?.preferencesChanged()
    }
    func enableAutomaticUSBStart() {
        guard !automaticStartReady else {return}
        automaticStartReady=true
        startForUSBIfNeeded(connectedUSBIDs)
    }
    func startForUSBIfNeeded(_ devices:Set<String>) {
        guard automaticStartReady,settings.autoStartUSB == true,!running,!preparingConnection,!reconnectCycle,!devices.isEmpty else {return}
        let selected=settings.selectedPhone ?? settings.lastPhone
        let preferred=phoneChoices.first(where:{$0.id==selected})
        if settings.selectedPhone != nil,preferred?.usb == nil {return}
        if let serial=preferred?.usb {
            guard devices.contains(serial.replacingOccurrences(of:"-",with:"").lowercased()) else {return}
        } else {
            guard devices.count==1,let serial=devices.first,let phone=phoneChoices.first(where:{$0.usb?.replacingOccurrences(of:"-",with:"").lowercased()==serial}) else {return}
            settings.selectedPhone=phone.id
        }
        if displayLoading && (settings.strictPixels == true || settings.resolution=="native") {
            displayDeferredUSB.formUnion(devices)
            status="正在读取显示器参数…";detail="显示器检测完成后自动启动USB连接。"
            return
        }
        displayDeferredUSB.removeAll()
        settings.wireless=false
        start()
    }
    func configureRemoteCommands() {
        let center=MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled=false
        remoteTargets.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event=event as? MPChangePlaybackPositionCommandEvent,event.positionTime.isFinite else {return .commandFailed}
            let position=event.positionTime
            Task { @MainActor in self?.requestSeek(position) }
            return .success
        })
        for (command,index) in [(center.playCommand,1),(center.pauseCommand,2),(center.togglePlayPauseCommand,3),(center.nextTrackCommand,4),(center.previousTrackCommand,5)] {
            command.isEnabled=true
            remoteTargets.append(command.addTarget { [weak self] _ in
                Task { @MainActor in self?.command("media \(index)") }
                return .success
            })
        }
    }
    func requestSeek(_ seconds:Double) {
        guard running,playingState.canSeek,playingState.duration>0,seconds.isFinite else {return}
        let id=UUID().uuidString
        var message:[String:Any]=["command":"seek","requestId":id,"positionMs":Int(max(0,min(seconds,playingState.duration))*1000)]
        if let track=playingState.trackID {message["trackId"]=track}
        if let data=try? JSONSerialization.data(withJSONObject:message),let line=String(data:data,encoding:.utf8){pendingSeekID=id;command(line)}
    }
    func clearNowPlaying() {
        mediaPublish?.cancel();mediaPublish=nil
        metadataFeed?.stop();metadataFeed=nil
        mediaDiagnostic=""
        playingState=NowPlayingState();artworkBytes=nil;pendingSeekID=nil;nowPlaying=[:]
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled=false
        MPNowPlayingInfoCenter.default().nowPlayingInfo=nil;MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    func publishNowPlaying(_ event:[String:Any]) {
        let now=ProcessInfo.processInfo.systemUptime
        if event["type"] as? String == "seekResult" {
            guard event["requestId"] as? String == pendingSeekID else {return}
            pendingSeekID=nil
            if event["sent"] as? Bool == true,let ms=event["positionMs"] as? Double {playingState.acceptSeek(ms/1000,at:now)}
            else {logs += "[媒体] iPhone当前不接受播放位置跳转。\n"}
        } else {
            let oldID=playingState.trackID,oldApp=playingState.appID
            playingState.receive(event,at:now)
            if oldID != playingState.trackID || oldApp != playingState.appID {pendingSeekID=nil}
        }
        guard mediaPublish==nil else {return}
        let work=DispatchWorkItem { [weak self] in self?.mediaPublish=nil;self?.flushNowPlaying() }
        mediaPublish=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:work)
    }
    private func flushNowPlaying() {
        guard running else {return}
        playingState.advance(to:ProcessInfo.processInfo.systemUptime)
        nowPlaying[MPMediaItemPropertyTitle]=playingState.title
        nowPlaying[MPMediaItemPropertyArtist]=playingState.artist
        nowPlaying[MPMediaItemPropertyAlbumTitle]=playingState.album
        nowPlaying[MPMediaItemPropertyPlaybackDuration]=playingState.duration
        nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime]=playingState.position
        nowPlaying[MPNowPlayingInfoPropertyPlaybackRate]=playingState.rate
        nowPlaying[MPNowPlayingInfoPropertyDefaultPlaybackRate]=1.0
        nowPlaying[MPNowPlayingInfoPropertyIsLiveStream]=playingState.duration<=0
        if let id=playingState.trackID {nowPlaying[MPNowPlayingInfoPropertyExternalContentIdentifier]=id}
        else {nowPlaying.removeValue(forKey:MPNowPlayingInfoPropertyExternalContentIdentifier)}
        if artworkBytes != playingState.artwork {
            artworkBytes=playingState.artwork
            if let bytes=artworkBytes,let image=NSImage(data:bytes) {nowPlaying[MPMediaItemPropertyArtwork]=MPMediaItemArtwork(boundsSize:image.size){_ in image}}
            else {nowPlaying.removeValue(forKey:MPMediaItemPropertyArtwork)}
        }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled=running && playingState.canSeek && playingState.duration>0
        MPNowPlayingInfoCenter.default().nowPlayingInfo=nowPlaying
        MPNowPlayingInfoCenter.default().playbackState=playingState.rate>0 ? .playing : .paused
        let diagnostic="总时长\(Int(playingState.duration))秒，封面\(nowPlaying[MPMediaItemPropertyArtwork] == nil ? "未收到" : "已发布")，进度跳转\(playingState.canSeek ? "可用" : "不可用")"
        if diagnostic != mediaDiagnostic {
            mediaDiagnostic=diagnostic;logs += "[媒体] \(diagnostic)\n"
            queueLogWrite()
        }
    }
    func inspectCredentials() { credentialsReady = ["identity.pk8","certificate.p7b"].allSatisfy { FileManager.default.fileExists(atPath: authDirectory.appendingPathComponent($0).path) } }
    func updateResolution() {
            guard let screen=selectedScreen else {return}
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let physicalWidth=displays.first(where:{$0.id==id})?.width ?? Int(screen.frame.width*screen.backingScaleFactor)
            let physicalHeight=displays.first(where:{$0.id==id})?.height ?? Int(screen.frame.height*screen.backingScaleFactor)
            settings.screenPixelWidth=physicalWidth
            settings.screenPixelHeight=physicalHeight
            settings.screenPixelsVerified=exactDisplayAvailable
            settings.screenLogicalWidth=screen.frame.width
            settings.screenLogicalHeight=screen.frame.height
            if let display=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let size=CGDisplayScreenSize(CGDirectDisplayID(display.uint32Value))
                settings.screenWidthMm=size.width>0 ? size.width : nil
                settings.screenHeightMm=size.height>0 ? size.height : nil
            }
        if settings.resolution == "native" {
            guard exactDisplayAvailable else {return}
            // Map macOS safe-area points to physical panel pixels, rather than
            // subtracting points from pixels or using the scaled desktop size.
            let insets=screen.safeAreaInsets
            let usableWidth=max(0,screen.frame.width-insets.left-insets.right)
            let usableHeight=max(0,screen.frame.height-insets.top-insets.bottom)
            settings.width=Int(Double(physicalWidth)*usableWidth/screen.frame.width)/2*2
            settings.height=Int(Double(physicalHeight)*usableHeight/screen.frame.height)/2*2
        } else if settings.resolution != "custom" {
            let parts=settings.resolution.split(separator:"x");if parts.count==2,let w=Int(parts[0]),let h=Int(parts[1]){settings.width=w;settings.height=h}
        }
        let fitted=DisplayCapabilities.fittedSize(width:settings.width,height:settings.height,visibleWidth:screen.visibleFrame.width,visibleHeight:screen.visibleFrame.height)
        settings.presentationWidth=fitted.0
        settings.presentationHeight=fitted.1
    }
    private func networkInput(_ value: PlaySettings) -> NetworkInputSnapshot {
        NetworkInputSnapshot(mode:value.networkInterfaceMode ?? "auto",interface:value.wifiInterface,
            ssid:value.ssid,password:value.password,channel:value.channel,bssid:value.accessPointOverride ?? value.accessPointMAC)
    }
    private var networkReadGuard: NetworkReadGuard { NetworkReadGuard(revision:networkInputRevision,input:networkInput(settings)) }
    private func acceptsNetworkRead(_ guardValue: NetworkReadGuard) -> Bool {
        guardValue.accepts(revision:networkInputRevision,input:networkInput(settings))
    }
    var selectedNetwork: NetworkInterfaceChoice? {
        NetworkSelection.resolve(manual:settings.networkInterfaceMode == "manual",name:settings.wifiInterface,interfaces:networkInterfaces)
    }
    func selectNetworkInterface(_ name: String?) {
        settings.networkInterfaceMode = name == nil ? "auto" : "manual"
        if let name { settings.wifiInterface=name }
        settings.accessPointMAC=nil;wifiDetails=nil
        networkRequestPending=false;networkPermissionGuard=nil
        deferredNetworkRead.cancel()
        networkQueryID &+= 1;readingNetwork=false
        persistPreferences();detectNetwork()
    }
    func networkLabel(_ choice: NetworkInterfaceChoice) -> String {
        "\(choice.name)（\(choice.id)） · \(L(choice.wireless ? "Wi-Fi" : "以太网")) · \(L(choice.ready ? "已连接" : "未连接"))"
    }
    func detectNetwork(requestPermission: Bool = false, readCredentials: Bool = false) {
        guard !readingNetwork else {return}
        readingNetwork=true;networkQueryID &+= 1
        let queryID=networkQueryID, guardValue=networkReadGuard, began=Date()
        BoundedNetworkQuery.run(work:{NetworkInterfaceReader.read()}) { [weak self] result in
            Task { @MainActor in
                guard let self,self.networkQueryID == queryID else {return}
                defer {self.consumeDeferredNetworkRead()}
                switch result {
                case .failure:
                    self.readingNetwork=false;self.networkInventoryError="TIMEOUT"
                    self.networkStatus="网络接口查询超时，已保留当前设置，请重试。"
                    self.appendDiagnostic("network-query stage=interfaces code=TIMEOUT elapsedMs=\(Int(Date().timeIntervalSince(began)*1000))")
                case .success(let inventory):
                    self.networkInventoryError=inventory.error
                    self.appendDiagnostic("network-query stage=interfaces code=\(inventory.error ?? "OK") elapsedMs=\(Int(Date().timeIntervalSince(began)*1000)) count=\(inventory.interfaces.count)")
                    guard inventory.error == nil else {
                        self.readingNetwork=false;self.networkStatus="无法读取网络接口状态，已保留当前设置，请重试。";return
                    }
                    self.networkInterfaces=inventory.interfaces
                    let importAllowed=(requestPermission || readCredentials) && self.acceptsNetworkRead(guardValue)
                    guard let selected=self.selectedNetwork else {
                        self.readingNetwork=false
                        self.networkStatus=self.settings.networkInterfaceMode == "manual" ? "所选网络接口暂不可用，请重新连接设备或选择其他接口。" : "没有可用的Wi-Fi或以太网接口，请先连接网络。"
                        return
                    }
                    if self.settings.networkInterfaceMode != "manual" {self.settings.wifiInterface=selected.id}
                    self.settings.wifiMAC=selected.hardwareAddress ?? ""
                    if !selected.wireless {
                        self.readingNetwork=false;self.wifiDetails=nil;self.settings.accessPointMAC=nil
                        self.networkStatus=selected.ready ? "当前使用以太网。请填写iPhone所连Wi-Fi的SSID、密码和实际信道，并确保两端位于同一局域网。" : "所选以太网未连接或尚未获得网络地址。"
                        return
                    }
                    self.queryWiFiDetails(selected.id,queryID:queryID,importAllowed:importAllowed,requestPermission:requestPermission)
                }
            }
        }
    }
    private func queryWiFiDetails(_ interface: String, queryID: UInt64, importAllowed: Bool, requestPermission: Bool) {
        let guardValue=networkReadGuard,began=Date()
        BoundedNetworkQuery.run(work:{NetworkInterfaceReader.wifiDetails(interface:interface)}) { [weak self] result in
            Task { @MainActor in
                guard let self,self.networkQueryID == queryID else {return}
                defer {self.consumeDeferredNetworkRead()}
                self.readingNetwork=false
                guard self.settings.wifiInterface == interface else {return}
                switch result {
                case .failure:
                    self.wifiDetails=nil;self.networkStatus="Wi-Fi详情查询超时，网络接口仍可用，请重试或手动填写。"
                    self.appendDiagnostic("network-query stage=wifi code=TIMEOUT elapsedMs=\(Int(Date().timeIntervalSince(began)*1000))")
                case .success(let details):
                    self.wifiDetails=details
                    self.appendDiagnostic("network-query stage=wifi code=\(details == nil ? "UNAVAILABLE" : "OK") elapsedMs=\(Int(Date().timeIntervalSince(began)*1000))")
                    guard let details else {self.networkStatus="系统未返回所选Wi-Fi接口信息，请重试。";return}
                    guard details.powered else {self.networkStatus="所选Wi-Fi未开启，请先开启Wi-Fi。";return}
                    if let ssid=details.ssid,!ssid.isEmpty {
                        guard importAllowed else {
                            self.networkStatus=ssid == self.settings.ssid ? "当前Wi-Fi与连接配置一致。" : "当前Wi-Fi与连接配置不同，请读取当前网络或核对设置。"
                            return
                        }
                        guard self.acceptsNetworkRead(guardValue) else {self.networkStatus="网络设置已修改，未覆盖新填写的内容。";return}
                        if self.settings.ssid != ssid {self.settings.password="";self.settings.accessPointOverride=nil;self.passwordStatus="网络已切换，请读取或填写当前网络密码。"}
                        self.settings.ssid=ssid;self.settings.accessPointMAC=details.bssid
                        if let channel=details.channel {self.settings.channel=channel}
                        self.networkStatus="已读取当前Wi-Fi名称和信道";self.networkRequestPending=false;self.networkPermissionGuard=nil
                    } else {
                        self.explainWiFiAccess(requestPermission:requestPermission && importAllowed && self.acceptsNetworkRead(guardValue))
                    }
                }
            }
        }
    }
    private func explainWiFiAccess(requestPermission: Bool) {
        guard CLLocationManager.locationServicesEnabled() else {
            networkStatus="系统定位服务已关闭。读取Wi-Fi名称需要在系统设置中开启定位服务。";return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            networkStatus="读取Wi-Fi名称需要定位权限；点击“读取当前网络”后按系统提示允许。"
            if requestPermission {
                networkRequestPending=true;networkPermissionGuard=networkReadGuard
                locationManager.requestWhenInUseAuthorization();locationManager.requestLocation()
            }
        case .denied,.restricted:
            networkStatus="定位权限未允许。请在“隐私与安全性→定位服务”中允许MacPlay后重试。"
        default:
            networkStatus="系统未返回Wi-Fi名称，请确认连接与定位权限，或手动填写。"
        }
    }
    var currentNetworkIsEnterprise: Bool {
        guard let wifiDetails,wifiDetails.interface == settings.wifiInterface,wifiDetails.ssid == settings.ssid else {return false}
        return wifiDetails.enterprise
    }
    func readSavedNetworkPassword() {
        guard !readingPassword else { return }
        guard !readingNetwork else {passwordStatus="正在读取网络状态，请稍后重试。";return}
        if currentNetworkIsEnterprise {
            passwordStatus="当前网络使用802.1X企业认证（用户名/密码或证书）。MacPlay的无线握手不支持发送这类凭据，请改用个人Wi-Fi、热点或USB连接。"
            return
        }
        if selectedNetwork?.wireless == true, let wifiDetails, let actual=wifiDetails.ssid, actual != settings.ssid {
            passwordStatus="当前Wi-Fi与连接配置不同，请先读取当前网络。";return
        }
        let ssid=settings.ssid,guardValue=networkReadGuard
        guard !ssid.isEmpty else {passwordStatus="请先读取当前网络名称。";return}
        readingPassword=true
        passwordStatus="正在读取钥匙串；如有系统提示，请授权MacPlay访问该网络密码。"
        Task {
            let result=await Task.detached { () -> (OSStatus, String?) in
                var length: UInt32=0
                var bytes: UnsafeMutableRawPointer?
                let service="AirPort"
                let status=service.withCString { servicePtr in
                    ssid.withCString { accountPtr in
                        SecKeychainFindGenericPassword(nil,UInt32(service.utf8.count),servicePtr,UInt32(ssid.utf8.count),accountPtr,&length,&bytes,nil)
                    }
                }
                defer { if let bytes {SecKeychainItemFreeContent(nil,bytes)} }
                let password=bytes.flatMap {String(data:Data(bytes:$0,count:Int(length)),encoding:.utf8)}
                return (status,password)
            }.value
            readingPassword=false
            guard acceptsNetworkRead(guardValue) else {passwordStatus="网络设置已修改，未覆盖新填写的内容。";return}
            if result.0==errSecSuccess,let password=result.1,!password.isEmpty {
                settings.password=password
                passwordStatus="已读取保存的密码，点击“应用并重新连接”使用网络凭据。"
            } else if result.0==errSecSuccess {
                passwordStatus="钥匙串未返回可用密码，请手动填写。"
            } else if result.0==errSecItemNotFound {
                passwordStatus="钥匙串未找到该网络的可读取密码，请手动填写。"
            } else if result.0==errSecUserCanceled || result.0==errSecAuthFailed || result.0==errSecInteractionNotAllowed {
                passwordStatus="未获准读取网络密码（系统状态码\(result.0)），请重新授权或手动填写。"
            } else {
                let explanation=SecCopyErrorMessageString(result.0,nil) as String? ?? ""
                passwordStatus="无法读取网络密码（系统状态码\(result.0)），请手动填写。"+(explanation.isEmpty ? "" : "\n"+explanation)
            }
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else {return}
            if self.networkRequestPending { self.resumeNetworkPermission() }
        }
    }
    private func resumeNetworkPermission() {
        guard networkRequestPending else {return}
        let unchanged=networkPermissionGuard.map(acceptsNetworkRead) ?? false
        if !unchanged {
            networkRequestPending=false;networkPermissionGuard=nil
            deferredNetworkRead.cancel()
            networkStatus="网络设置已修改，未覆盖新填写的内容。"
            return
        }
        if let networkPermissionGuard {deferredNetworkRead.enqueue(networkPermissionGuard)}
        consumeDeferredNetworkRead()
    }
    private func consumeDeferredNetworkRead() {
        guard deferredNetworkRead.takeIfIdle(reading:readingNetwork,revision:networkInputRevision,input:networkInput(settings)) != nil else {return}
        detectNetwork(readCredentials:true)
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.resumeNetworkPermission() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.resumeNetworkPermission() }
    }
    func refreshUSB() {
        var iterator: io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&iterator)==KERN_SUCCESS else {
            usbError="无法读取系统USB设备列表"; return
        }
        defer {IOObjectRelease(iterator)}
        var phones:[String]=[]
        var serials=Set<String>()
        var choices=settings.phones ?? []
        while case let device=IOIteratorNext(iterator), device != 0 {
            defer {IOObjectRelease(device)}
            guard let value=IORegistryEntryCreateCFProperty(device,"USB Product Name" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String else {continue}
            if value.localizedCaseInsensitiveContains("iPhone") {
                phones.append(value)
                if let serial=IORegistryEntryCreateCFProperty(device,"USB Serial Number" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String {
                    serials.insert(serial.replacingOccurrences(of:"-",with:"").lowercased())
                    if !choices.contains(where:{$0.usb?.replacingOccurrences(of:"-",with:"")==serial.replacingOccurrences(of:"-",with:"")}) {choices.append(PhoneChoice(id:"usb:"+serial,name:value,usb:serial))}
                }
            }
        }
        let changed=phones.count != usbDevices.count
        usbDevices=phones
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) {
            let address=device.addressString?.replacingOccurrences(of:"-",with:":").lowercased() ?? ""
            guard !address.isEmpty else {continue}
            let name=device.name?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            if let index=choices.firstIndex(where:{$0.bluetooth?.replacingOccurrences(of:"-",with:":").lowercased()==address}) {
                if !name.isEmpty {choices[index].name=name}
            } else {
                choices.append(PhoneChoice(id:address,name:name.isEmpty ? address : name,bluetooth:address))
            }
        }
        phoneChoices=choices
        let added=serials.subtracting(connectedUSBIDs)
        connectedUSBIDs=serials
        let hadDeferredUSB = !displayDeferredUSB.isEmpty
        displayDeferredUSB.formIntersection(serials)
        if hadDeferredUSB && displayDeferredUSB.isEmpty {status="尚未启动接收";detail="连接iPhone后启动接收端。"}
        if changed && !running {usbError="";usbStage="接收服务未启动"}
        startForUSBIfNeeded(added)
    }
    var usbStatus: String {
        guard !usbDevices.isEmpty else {return "未检测到USB连接的iPhone"}
        return "已检测到\(usbDevices.count)台iPhone"
    }
    func readUSBEvent(_ value:[String:String]) {
        if let stage=value["usbStatus"] {usbStage=stage;usbError=""}
        if let error=value["usbError"] {usbError=error}
    }
    func save() throws {
        updateResolution()
        if (settings.strictPixels == true || settings.resolution == "native") && !exactDisplayAvailable {
            throw NSError(domain:"MacPlay",code:3,userInfo:[NSLocalizedDescriptionKey:"无法确认显示器物理参数，请刷新显示器或使用普通窗口模式。"])
        }
        settings.width=max(320,min(7680,settings.width/2*2));settings.height=max(200,min(4320,settings.height/2*2))
        if settings.strictPixels == true,settings.resolution != "native",let screen=selectedScreen,
           let physicalWidth=settings.screenPixelWidth,let physicalHeight=settings.screenPixelHeight {
            let content=NSRect(x:0,y:0,width:Double(settings.width)*screen.frame.width/Double(physicalWidth),height:Double(settings.height)*screen.frame.height/Double(physicalHeight))
            let frame=NSWindow.frameRect(forContentRect:content,styleMask:[.borderless,.closable,.miniaturizable])
            if frame.width>screen.visibleFrame.width || frame.height>screen.visibleFrame.height {
                throw NSError(domain:"MacPlay",code:2,userInfo:[NSLocalizedDescriptionKey:"所选分辨率超过当前屏幕的可见区域，无法按物理像素比例显示。请选择较低分辨率，或使用原生像素全屏模式。"])
            }
        }
        let phone: PhoneChoice?
        if settings.wireless {
            let selected=settings.selectedPhone ?? settings.lastPhone
            phone=phoneChoices.first(where:{$0.id==selected})
        } else {
            do {
                phone=try USBPhoneSelection.resolve(choices:phoneChoices,selectedID:settings.selectedPhone,lastID:settings.lastPhone,connectedIDs:connectedUSBIDs)
            } catch USBPhoneSelection.Failure.ambiguous {
                throw NSError(domain:"MacPlay",code:5,userInfo:[NSLocalizedDescriptionKey:"检测到多台USB连接的iPhone，请先选择要连接的设备。"])
            } catch {
                throw NSError(domain:"MacPlay",code:4,userInfo:[NSLocalizedDescriptionKey:"所选iPhone缺少当前连接方式的设备记录，请选择已配对或USB接入的设备完成首次连接。"])
            }
        }
        settings.targetBluetooth=phone?.bluetooth
        settings.targetUSB=phone?.usb
        if let phone,settings.wireless ? phone.bluetooth==nil : phone.usb==nil {
            throw NSError(domain:"MacPlay",code:4,userInfo:[NSLocalizedDescriptionKey:"所选iPhone缺少当前连接方式的设备记录，请选择已配对或USB接入的设备完成首次连接。"])
        }
        let data=try JSONEncoder().encode(settings);try data.write(to:configURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)
    }
    func setAutoReconnect(_ enabled:Bool) {
        settings.autoReconnect=enabled;persistPreferences()
        if !enabled && reconnectCycle {let waiting = !running;cancelReconnect(clearSession:!running);if waiting {status="接收已停止";detail=""}}
    }
    private func cancelReconnect(clearSession:Bool=true) {
        startRequest &+= 1;preparingConnection=false
        reconnectTimer?.invalidate();reconnectTimer=nil;reconnectBackoff.reset();reconnectCycle=false;if clearSession {successfulSettings=nil}
    }
    private func scheduleReconnect() {
        guard settings.autoReconnect == true,successfulSettings?.wireless == true,reconnectTimer==nil else {return}
        reconnectCycle=true
        let seconds=reconnectBackoff.nextDelay()
        let previousReason=status
        status="等待自动重连";detail=L(previousReason)+"\n"+L("将在\(seconds)秒后重试连接。")
        appendDiagnostic("reconnect-wait seconds=\(seconds) attempt=\(reconnectBackoff.attempts)")
        reconnectTimer=Timer.scheduledTimer(withTimeInterval:Double(seconds),repeats:false){[weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {return};self.reconnectTimer=nil
                guard self.settings.autoReconnect == true,let config=self.successfulSettings else {return}
                self.refreshUSB()
                let draft=self.settings
                self.settings=config;self.settings.autoReconnect=true
                self.start(isAutomatic:true)
                self.settings=draft
                self.persistPreferences()
            }
        }
    }
    private func passiveDisconnect(_ reason:String) {
        let retry=ReconnectBackoff.permitted(enabled:settings.autoReconnect == true,successfulWirelessSession:successfulSettings?.wireless == true)
        stop(preserveReconnect:retry)
        status=reason;detail=""
        appendDiagnostic("disconnected: \(reason)")
        if retry {scheduleReconnect()}
    }
    private func appendDiagnostic(_ value:String) {
        logs += "[\(attemptID)] +\(Int(Date().timeIntervalSince(attemptStart)*1000))ms \(value)\n"
        queueLogWrite()
    }
    private func queueLogWrite() {
        let lines=logs.split(separator:"\n",omittingEmptySubsequences:false)
        if lines.count>1000 {logs=lines.suffix(1000).joined(separator:"\n")}
        guard logWrite==nil else {return}
        let work=DispatchWorkItem { [weak self] in
            guard let self else {return};self.logWrite=nil
            try? MacPlayUpdates.redactedLog(self.logs).write(to:self.logURL,atomically:true,encoding:.utf8)
        }
        logWrite=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    private func reportStartProblem(_ title: String, _ message: String) {
        if running {networkStatus=message;detail=message}
        else {status=title;detail=message}
    }
    func start(isFallback:Bool=false,isAutomatic:Bool=false) {
        if !settings.wireless {launchStart(isFallback:isFallback,isAutomatic:isAutomatic);return}
        if !isFallback && !isAutomatic {cancelReconnect(clearSession:false)}
        startRequest &+= 1
        let request=startRequest,snapshot=settings
        preparingConnection=true;networkStatus="正在检查连接网络…"
        BoundedNetworkQuery.run(work:{ () -> (NetworkInventory,NetworkInterfaceChoice?,WiFiNetworkDetails?) in
            let inventory=NetworkInterfaceReader.read()
            let selected=NetworkSelection.resolve(manual:snapshot.networkInterfaceMode == "manual",name:snapshot.wifiInterface,interfaces:inventory.interfaces)
            let details=selected.flatMap{$0.wireless ? NetworkInterfaceReader.wifiDetails(interface:$0.id) : nil}
            return (inventory,selected,details)
        }) { [weak self] result in
            Task { @MainActor in
                guard let self,self.startRequest == request else {return}
                defer {if !self.running && self.reconnectCycle {self.scheduleReconnect()}}
                self.preparingConnection=false
                guard !isAutomatic || self.settings.autoReconnect == true else {return}
                var current=self.settings
                current.autoReconnect=snapshot.autoReconnect
                guard isFallback || isAutomatic || current == snapshot else {self.networkStatus="设置已修改，请重新启动接收。";return}
                switch result {
                case .failure:
                    self.reportStartProblem("无法确认网络接口状态","连接前网络检查超时，请重试。");if isAutomatic {self.scheduleReconnect()};return
                case .success(let (inventory,selected,details)):
                    self.networkInterfaces=inventory.interfaces;self.networkInventoryError=inventory.error;self.wifiDetails=details
                    guard inventory.error == nil,let selected,selected.ready else {
                        self.reportStartProblem("所选网络尚未连接","请检查Wi-Fi或网线连接，等待接口获得网络地址。");return
                    }
                    var prepared=snapshot
                    prepared.autoReconnect=self.settings.autoReconnect
                    if isFallback || isAutomatic {
                        prepared.inputDevice=self.settings.inputDevice;prepared.outputDevice=self.settings.outputDevice
                        prepared.volume=self.settings.volume;prepared.callVolume=self.settings.callVolume;prepared.audioEnabled=self.settings.audioEnabled
                    }
                    if selected.wireless,let details {
                        guard !details.enterprise else {self.reportStartProblem("当前Wi-Fi采用企业认证","无线CarPlay握手不支持802.1X用户名/密码或证书，请改用个人Wi-Fi、热点或USB连接。");return}
                        guard details.powered else {self.reportStartProblem("所选网络尚未连接","所选Wi-Fi未开启，请先开启Wi-Fi。");return}
                        if let ssid=details.ssid,!ssid.isEmpty {
                            guard ssid == snapshot.ssid else {self.reportStartProblem("当前Wi-Fi与连接配置不一致","请读取当前网络并填写对应密码。");return}
                            if let channel=details.channel {prepared.channel=channel}
                        }
                    }
                    self.networkStatus="连接网络检查完成"
                    let draft=self.settings;self.settings=prepared
                    self.launchStart(isFallback:isFallback,isAutomatic:isAutomatic)
                    if isFallback || isAutomatic {self.settings=draft;self.persistPreferences()}
                }
            }
        }
    }
    private func launchStart(isFallback:Bool=false,isAutomatic:Bool=false) {
        if !isFallback && !isAutomatic {cancelReconnect(clearSession:false)}
        defer {if !running && reconnectCycle {scheduleReconnect()}}

        if !isFallback {frameRateFallbackNote=""}
        fallbackQueued=false
        inspectCredentials()
        settings.bluetoothMAC=IOBluetoothHostController.default()?.addressAsString()?.replacingOccurrences(of:"-",with:":") ?? ""
        guard credentialsReady else {reportStartProblem("缺少认证文件", "请在关于页面导入有使用权限的配套认证文件。");return}
        if settings.wireless && currentNetworkIsEnterprise {
            reportStartProblem("当前Wi-Fi采用企业认证", "无线CarPlay握手不支持802.1X用户名/密码或证书，请改用个人Wi-Fi、热点或USB连接。");return
        }
        if settings.wireless && settings.ssid.isEmpty {
            reportStartProblem("无线连接缺少网络信息", "请先读取当前Wi-Fi名称。");return
        }
        if settings.wireless {
            guard !readingNetwork else {reportStartProblem("正在读取网络状态", "请等待读取完成后启动接收。");return}
            guard networkInventoryError == nil else {reportStartProblem("无法确认网络接口状态", "请重新读取网络，确认接口状态后再启动接收。");return}
            guard let selected=selectedNetwork else {reportStartProblem("所选网络接口暂不可用", "请连接网络或选择其他接口。");return}
            guard selected.ready else {reportStartProblem("所选网络尚未连接", "请检查Wi-Fi或网线连接，等待接口获得网络地址。");return}
            settings.wifiInterface=selected.id;settings.wifiMAC=selected.hardwareAddress ?? ""
            if selected.wireless, let wifiDetails, wifiDetails.interface == selected.id,
               let actual=wifiDetails.ssid,!actual.isEmpty {
                guard actual == settings.ssid else {reportStartProblem("当前Wi-Fi与连接配置不一致", "请读取当前网络并填写对应密码。");return}
                settings.accessPointMAC=wifiDetails.bssid
            } else {settings.accessPointMAC=nil}
            if let manual=settings.accessPointOverride?.trimmingCharacters(in:.whitespacesAndNewlines),!manual.isEmpty {
                guard manual.range(of:#"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#,options:.regularExpression) != nil else {reportStartProblem("接入点BSSID格式无效","请填写六组十六进制地址，或留空自动读取。");return}
                settings.accessPointMAC=manual.uppercased()
            }
        }
        do {
            try save()
            stop(restoreMain:false,preserveReconnect:isFallback || isAutomatic)
            appliedSettings=settings;mediaStatistics=[:];logRedactor=DiagnosticRedactor.Stream()
            let sessionURL=directory.appendingPathComponent("session-settings.json")
            try JSONEncoder().encode(settings).write(to:sessionURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:sessionURL.path)
            attemptID=UUID().uuidString.prefix(8).description;attemptStart=Date()
            appendDiagnostic("starting wireless=\(settings.wireless) interface=\(settings.wifiInterface) channel=\(settings.channel) video=\(settings.width)x\(settings.height) fps=\(settings.fps)")
            guard let resources=Bundle.main.resourceURL else {throw NSError(domain:"MacPlay",code:1,userInfo:[NSLocalizedDescriptionKey:"找不到应用资源目录"])}
            let task=Process();task.executableURL=resources.appendingPathComponent("runtime/MacPlayReceiver.app/Contents/MacOS/MacPlayReceiver");task.arguments=[resources.appendingPathComponent("engine/main.js").path]
            var environment=ProcessInfo.processInfo.environment;environment["MACPLAY_RESOURCES"]=resources.path;environment["MACPLAY_DATA"]=directory.path
            environment["MACPLAY_SETTINGS_PATH"]=sessionURL.path
            environment["MACPLAY_ATTEMPT"]=attemptID
            environment["MACPLAY_LANGUAGE"]=MacPlayLocalization.effectiveLanguage
            let gstLibPath: String = {
                #if arch(x86_64)
                let x64Path = resources.appendingPathComponent("gstreamer/macos-x64/lib")
                if FileManager.default.fileExists(atPath: x64Path.path) { return x64Path.path }
                #else
                let arm64Path = resources.appendingPathComponent("gstreamer/macos-arm64/lib")
                if FileManager.default.fileExists(atPath: arm64Path.path) { return arm64Path.path }
                #endif
                let armFallback = resources.appendingPathComponent("gstreamer/macos-arm64/lib")
                if FileManager.default.fileExists(atPath: armFallback.path) { return armFallback.path }
                let uniFallback = resources.appendingPathComponent("gstreamer/macos/lib")
                if FileManager.default.fileExists(atPath: uniFallback.path) { return uniFallback.path }
                return resources.appendingPathComponent("gstreamer/macos-x64/lib").path
            }()
            environment["DYLD_LIBRARY_PATH"]=gstLibPath
            task.environment=environment
            let stdin=try ReceiverCommandPipe.make(),stdout=Pipe();task.standardInput=stdin;task.standardOutput=stdout;task.standardError=stdout
            output=stdout;input=stdin;process=task
            stdout.fileHandleForReading.readabilityHandler={ [weak self] handle in
                let data=handle.availableData
                guard !data.isEmpty else {return}
                Task { @MainActor in
                    guard self?.process === task else {return}
                    self?.consume(data)
                }
            }
            task.terminationHandler={ [weak self] task in Task { @MainActor in
                guard self?.process === task else {return};self?.passiveDisconnect("接收进程已退出")
            }}
            try task.run();running=true;usbStage="等待USB握手，请保持iPhone解锁";usbError="";status="正在启动接收服务";detail=settings.wireless ? "准备蓝牙握手与共用Wi-Fi连接。" : "准备USB连接与配件认证。"
        } catch {reportStartProblem("启动失败",error.localizedDescription)}
    }
    func stop(restoreMain:Bool=true,preserveReconnect:Bool=false) {
        startRequest &+= 1;preparingConnection=false
        displayDeferredUSB.removeAll()
        if !preserveReconnect {cancelReconnect()}
        if let task=process,task.isRunning {
            // Give the receiver time to close its window and USB/Bluetooth helpers
            // before starting another receiver on the same ports.
            command("stop")
            let deadline=Date().addingTimeInterval(2)
            while task.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
            if task.isRunning {kill(task.processIdentifier,SIGKILL)}
            task.waitUntilExit()
        }
        output?.fileHandleForReading.readabilityHandler=nil;process=nil;input=nil;output=nil;running=false;pending.removeAll()
        status="接收已停止";detail="可以调整设置后重新启动。"
        usbStage="接收服务未启动";usbError=""
        mediaStatistics=[:];clearNowPlaying();if restoreMain {page = .connection;showMainWindow()}
    }
    func consume(_ data:Data) {
        pending.append(data)
        while let newline=pending.firstIndex(of:0x0a) {
            let line=String(decoding:pending[..<newline],as:UTF8.self);pending.removeSubrange(...newline)
            if let eventData=line.data(using:.utf8),let event=(try? JSONSerialization.jsonObject(with:eventData)) as? [String:Any] {
                if event["type"] as? String == "videoStatistics" {mediaStatistics["video"]=event;continue}
                if event["type"] as? String == "audioStatistics" {mediaStatistics["audio"]=event["streams"] ?? [];continue}
                if let kind=event["type"] as? String,kind=="seekResult" {publishNowPlaying(event);continue}
                if let kind=event["type"] as? String,kind=="nowplaying" || kind=="albumart" {continue}
                if event["showCarPlay"] as? Bool == true {
                    successfulSettings=appliedSettings;reconnectBackoff.reset();reconnectCycle=false
                    reconnectTimer?.invalidate();reconnectTimer=nil
                    showCarPlayWindow();continue
                }
                if event["showMain"] as? Bool == true {showMainWindow();continue}
                if event["disconnected"] as? Bool == true {
                    if event["manual"] as? Bool == true {stop()}
                    else {passiveDisconnect(event["reason"] as? String ?? "连接已断开")}
                    return
                }
            }
            if let data=line.data(using:.utf8),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:String] {
                if let message=value["status"] {status=message;detail=value["detail"] ?? ""}
                if let nextText=value["fallbackFps"],let next=Int(nextText),running,!fallbackQueued,
                   (appliedSettings?.fps==120 && next==90 || appliedSettings?.fps==90 && next==60) {
                    fallbackQueued=true
                    let failedTask=process
                    let previous=appliedSettings?.fps ?? settings.fps
                    Task { @MainActor [weak self] in
                        guard let self,self.running,self.process === failedTask,self.appliedSettings?.fps==previous else {return}
                        let draft=self.settings
                        self.settings=self.appliedSettings ?? self.settings
                        self.settings.fps=next
                        let note="\(previous)fps协商未启动视频，已改用\(next)fps重连。"
                        self.frameRateFallbackNote += self.frameRateFallbackNote.isEmpty ? note : "\n"+note
                        self.start(isFallback:true)
                        self.settings=draft;self.persistPreferences()
                    }
                }
                if let deviceId=value["connectedPhone"],!deviceId.isEmpty {
                    if metadataFeed==nil {
                        let receiver=process
                        let feed=NowPlayingFeed(phone:deviceId) { [weak self] event in
                            guard let self,self.running,self.process === receiver else {return}
                            self.publishNowPlaying(event)
                        }
                        metadataFeed=feed;feed.start()
                    }
                    var known=settings.phones ?? []
                    let bt=deviceId.replacingOccurrences(of:"-",with:":").lowercased()
                    let udid=value["connectedUSB"].flatMap{$0.isEmpty ? nil : $0} ?? known.first(where:{$0.bluetooth==bt})?.usb
                    let name=value["phoneName"].flatMap{$0.isEmpty ? nil : $0} ?? "iPhone"
                    known.removeAll{$0.id==bt || $0.bluetooth==bt || (udid != nil && $0.usb==udid)}
                    known.append(PhoneChoice(id:bt,name:name,bluetooth:bt,usb:udid))
                    successfulSettings?.phones=known;successfulSettings?.lastPhone=bt
                    successfulSettings?.selectedPhone=bt;successfulSettings?.targetBluetooth=bt;successfulSettings?.targetUSB=udid
                    settings.phones=known;settings.lastPhone=bt
                    if settings.selectedPhone != nil {settings.selectedPhone=bt}
                    refreshUSB()
                    if let encoded=try? JSONEncoder().encode(settings){try? encoded.write(to:configURL,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)}
                }
                readUSBEvent(value)
            }
            if let safeLine=logRedactor.consume(line) {logs += safeLine+"\n"}
        }
        queueLogWrite()
    }
    func command(_ command:String) {
        guard let task=process,task.isRunning,let pipe=input else {return}
        do {try ReceiverCommandPipe.write(command,to:pipe)}
        catch {
            input=nil
            try? pipe.fileHandleForWriting.close()
            let failure=error as NSError
            let cause=failure.userInfo[NSUnderlyingErrorKey] as? NSError ?? failure
            appendDiagnostic("receiver-command failed domain=\(cause.domain) code=\(cause.code)")
        }
    }
    func importCredentials() {
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=true;panel.message=L("选择identity.pk8和certificate.p7b")
        guard panel.runModal() == .OK else {return}
        for source in panel.urls where ["identity.pk8","certificate.p7b"].contains(source.lastPathComponent) {
            do {let data=try Data(contentsOf:source);let target=authDirectory.appendingPathComponent(source.lastPathComponent);try data.write(to:target,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)}catch{detail=error.localizedDescription}
        }
        inspectCredentials()
    }
}

enum Page: String,CaseIterable,Identifiable {
    case connection="连接",display="显示",audio="音频",about="关于",donation="捐赠"
    var id:String{rawValue}
    var icon:String {switch self{case .connection:return "iphone.radiowaves.left.and.right";case .display:return "display";case .audio:return "speaker.wave.2";case .about:return "info.circle";case .donation:return "heart"}}
}

struct SettingsView: View {
    @ObservedObject var model:PlayModel
    @StateObject private var updates=MacPlayUpdates()
    var body:some View {
        NavigationSplitView {
            List(Page.allCases,selection:$model.page){ item in Label(L(item.rawValue),systemImage:item.icon).tag(item) }
                .navigationTitle("MacPlay").navigationSplitViewColumnWidth(min:150,ideal:165,max:200)
        } detail: {
            VStack(spacing:0) {
                Form {
                    switch model.page ?? .connection {
                    case .connection:
                        Section(L("接收端")) {
                            LabeledContent(L("状态"),value:L(model.status))
                            Text(L(model.detail)).foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
                            Picker(L("iPhone"),selection:Binding(get:{model.settings.selectedPhone ?? "auto"},set:{model.settings.selectedPhone=$0=="auto" ? nil : $0})) {
                                Text(L("自动（上次连接的iPhone）")).tag("auto")
                                ForEach(model.phoneChoices){phone in Text(phone.name+"（"+String(phone.id.suffix(5))+"）").tag(phone.id)}
                            }
                            Button(L("刷新iPhone列表")){model.refreshUSB()}
                            Text(L("自动模式优先连接上次成功显示画面的iPhone。切换设备后点击“应用并重新连接”。")).font(.callout).foregroundStyle(.secondary)
                            Picker(L("连接方式"),selection:$model.settings.wireless) {
                                Text(L("有线CarPlay")).tag(false)
                                Text(L("无线CarPlay")).tag(true)
                            }.pickerStyle(.segmented)
                            Text(L(model.settings.wireless ? "通过蓝牙配对后使用共用Wi-Fi连接。" : "通过USB数据线连接，无需填写Wi-Fi信息。")).foregroundStyle(.secondary)
                        }
                        Section(L("应用")) {
                            Picker(L("语言"),selection:Binding(get:{model.settings.language ?? "system"},set:{model.setLanguage($0)})) {
                                Text(L("跟随系统")).tag("system")
                                Text(L("简体中文")).tag("zh-Hans")
                                Text(L("繁體中文")).tag("zh-Hant")
                                Text(L("English")).tag("en")
                            }
                            Toggle(L("USB接入时自动启动CarPlay"),isOn:Binding(get:{model.settings.autoStartUSB ?? false},set:{model.settings.autoStartUSB=$0;model.persistPreferences();if $0 {model.startForUSBIfNeeded(model.currentUSBIDs)}}))
                            Picker(L("关闭主窗口时"),selection:Binding(get:{model.settings.closeBehavior ?? "ask"},set:{model.settings.closeBehavior=$0;if $0 == "background" {model.settings.backgroundEnabled=true};MacPlayApplicationDelegate.shared?.preferencesChanged()})) {
                                Text(L("每次询问")).tag("ask")
                                Text(L("保持后台运行")).tag("background")
                                Text(L("退出MacPlay")).tag("quit")
                            }
                            Toggle(L("允许后台运行"),isOn:Binding(get:{model.settings.backgroundEnabled ?? false},set:{model.settings.backgroundEnabled=$0;MacPlayApplicationDelegate.shared?.preferencesChanged()}))
                            Text(L("关闭主窗口后继续接收，可从菜单栏图标打开窗口或退出。自动启动需要MacPlay保持运行，并在iPhone上解锁和完成信任。")).font(.callout).foregroundStyle(.secondary)
                        }
                        if !model.settings.wireless {Section(L("USB直连")) {
                            LabeledContent(L("设备"),value:L(model.usbStatus))
                            if !model.usbDevices.isEmpty {LabeledContent(L("连接阶段"),value:L(model.usbError.isEmpty ? model.usbStage : model.usbError))}
                            Button(L("刷新USB设备")){model.refreshUSB()}
                            Text(L("连接数据线后点击“启动接收”，并在iPhone上解锁、确认信任。USB设备检测会自动刷新。")).foregroundStyle(.secondary)
                        }}
                        if model.settings.wireless {
                            Section(L("共用Wi-Fi")) {
                                Toggle(L("无线连接被动断开时自动重连"),isOn:Binding(get:{model.settings.autoReconnect ?? false},set:{model.setAutoReconnect($0)}))
                                Picker(L("网络接口模式"),selection:Binding(get:{model.settings.networkInterfaceMode ?? "auto"},set:{model.selectNetworkInterface($0 == "auto" ? nil : model.settings.wifiInterface)})) {
                                    Text(L("自动选择（推荐）")).tag("auto")
                                    Text(L("手动选择网卡（高级）")).tag("manual")
                                }
                                if model.settings.networkInterfaceMode == "manual" {
                                    Picker(L("网络接口"),selection:Binding(get:{model.settings.wifiInterface},set:{model.selectNetworkInterface($0)})) {
                                        ForEach(model.networkInterfaces) {network in Text(model.networkLabel(network)).tag(network.id)}
                                        if !model.networkInterfaces.contains(where:{$0.id == model.settings.wifiInterface}) {
                                            Text("\(model.settings.wifiInterface) · \(L("暂不可用"))").tag(model.settings.wifiInterface)
                                        }
                                    }
                                }
                                if let selected=model.selectedNetwork {LabeledContent(L("当前接口"),value:model.networkLabel(selected))}
                                TextField(L("网络名称（SSID）"),text:Binding(get:{model.settings.ssid},set:{if model.settings.ssid != $0 {model.settings.password="";model.settings.accessPointMAC=nil;model.settings.accessPointOverride=nil};model.settings.ssid=$0}))
                                SecureField(L("网络密码"),text:$model.settings.password)
                                Stepper(L("信道：\(model.settings.channel)"),value:$model.settings.channel,in:1...196)
                                DisclosureGroup(L("高级网络设置")) {
                                    TextField(L("接入点BSSID（可选）"),text:Binding(get:{model.settings.accessPointOverride ?? ""},set:{model.settings.accessPointOverride=$0}))
                                }
                                HStack {
                                    Button(L(model.readingNetwork ? "正在读取网络…" : "读取当前网络")){model.detectNetwork(requestPermission:true)}.disabled(model.readingNetwork)
                                    Button(L(model.readingPassword ? "正在读取密码…" : "读取已保存密码")){model.readSavedNetworkPassword()}.disabled(model.readingPassword || model.readingNetwork || model.settings.ssid.isEmpty)
                                    Button(L("打开定位设置")){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)}
                                    Button(L("打开蓝牙设置")){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.BluetoothSettings")!)}
                                }
                                Text(L(model.networkStatus)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if !model.passwordStatus.isEmpty {Text(L(model.passwordStatus)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)}
                                Text(L("Mac与iPhone需位于同一局域网，并在两端确认蓝牙配对码。Mac使用以太网时，请手动填写iPhone所连Wi-Fi的SSID、共享密码和实际信道。802.1X企业Wi-Fi不支持此无线握手，请使用个人Wi-Fi、热点或USB。")).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    case .display:
                        Section(L("显示器")) {
                            Picker(L("显示位置"),selection:Binding(get:{model.settings.displayID ?? model.displays.first?.id ?? 0},set:{model.selectDisplay($0)})) {
                                ForEach(model.displays){Text($0.label).tag($0.id)}
                            }
                            if let panel=model.displays.first(where:{$0.id==model.settings.displayID}) {Text(L(panel.details)).font(.callout).foregroundStyle(.secondary)}
                            if !model.displayStatus.isEmpty {Text(L(model.displayStatus)).font(.callout).foregroundStyle(.secondary)}
                            Button(L("刷新显示器")){model.refreshDisplays()}.disabled(model.displayLoading)
                            Text(L("默认内建显示器；切换显示器后应用并重新连接。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section(L("视频分辨率")) {
                            Picker(L("分辨率"),selection:$model.settings.resolution) {
                                Text(L("屏幕原生像素（避开刘海）")).tag("native").disabled(!model.exactDisplayAvailable)
                                ForEach(["1280x720","1920x1080","2560x1440"],id:\.self){Text($0.replacingOccurrences(of:"x",with:"×")).tag($0)}
                                Text(L("自定义")).tag("custom")
                            }.onChange(of:model.settings.resolution){_,_ in model.updateResolution()}
                            if model.settings.resolution == "custom" {
                                TextField(L("宽度（像素）"),value:$model.settings.width,format:.number)
                                TextField(L("高度（像素）"),value:$model.settings.height,format:.number)
                            }
                            Toggle(L("严格按屏幕物理像素显示"),isOn:Binding(get:{model.settings.strictPixels ?? false},set:{model.settings.strictPixels=$0})).disabled(model.settings.resolution == "native" || (!model.exactDisplayAvailable && model.settings.strictPixels != true))
                            LabeledContent(L("请求像素"),value:"\(model.settings.width)×\(model.settings.height)")
                            Text(L("原生像素模式全屏显示。关闭严格像素显示后，窗口适配屏幕并可等比例调整大小，不改变请求分辨率。")).font(.callout).foregroundStyle(.secondary)
                        }
                        Section(L("流畅度")) {
                            Picker(L("最高帧率"),selection:$model.settings.fps){ForEach([30,60,90,120],id:\.self){Text(L("\($0)fps")).tag($0)}}
                            Text(L("高帧率为实验请求：120fps视频启动失败后尝试90fps，再失败则尝试60fps。")).font(.callout).foregroundStyle(.secondary)
                            DisclosureGroup(L("接收统计")) {
                                LabeledContent(L("请求帧率"),value:"\(model.settings.fps)fps")
                                LabeledContent(L("本次尝试"),value:"\(model.attemptedFPS)fps")
                                LabeledContent(L("实际接收"),value:model.statisticFPS("receivedFps"))
                                LabeledContent(L("解码输出"),value:model.statisticFPS("decodedFps"))
                                LabeledContent(L("视频尺寸"),value:model.videoStatisticsText)
                            }
                            if !model.frameRateFallbackNote.isEmpty {Text(L(model.frameRateFallbackNote)).font(.callout).foregroundStyle(.secondary)}
                            Text(L("分辨率决定请求的视频尺寸。CarPlay内的“智能缩放显示”会影响实际输出，帧率为请求上限。")).font(.callout).foregroundStyle(.secondary)
                        }
                    case .audio:
                        Section(L("CarPlay声音")) {
                            Toggle(L("播放iPhone音频"),isOn:$model.settings.audioEnabled).onChange(of:model.settings.audioEnabled){_,_ in model.applyLiveAudio()}
                            LabeledContent(L("媒体音量")){Slider(value:$model.settings.volume,in:0...1).onChange(of:model.settings.volume){_,_ in model.applyLiveAudio()};Text(L("\(Int(model.settings.volume*100))%")).monospacedDigit().frame(width:42)}
                            LabeledContent(L("通话音量")){Slider(value:Binding(get:{model.settings.callVolume ?? 1},set:{model.settings.callVolume=$0;model.applyLiveAudio()}),in:0...1);Text(L("\(Int((model.settings.callVolume ?? 1)*100))%")).monospacedDigit().frame(width:42)}
                            Picker(L("输出设备"),selection:Binding(get:{model.settings.outputDevice ?? ""},set:{model.settings.outputDevice=$0;model.applyAudioDevices(inputChanged:false)})) {Text(L("系统默认设备")).tag("");ForEach(model.audioOutputs){Text($0.name).tag($0.id)}}
                            Picker(L("输入设备"),selection:Binding(get:{model.settings.inputDevice ?? ""},set:{model.settings.inputDevice=$0;model.applyAudioDevices(outputChanged:false)})) {Text(L("系统默认设备")).tag("");ForEach(model.audioInputs){Text($0.name).tag($0.id)}}
                            Button(L("刷新设备")){model.audioHardwareChanged(inputChanged:true,outputChanged:true)}
                            LabeledContent(L("音频格式"),value:model.audioFormatText)
                            Text(L("媒体与通话音量、输入输出设备实时生效。麦克风使用需要系统授权。")).font(.callout).foregroundStyle(.secondary)
                        }
                    case .about:
                        MacPlayAboutView(model:model,updates:updates)
                    case .donation:
                        MacPlayDonationView()
                    }
                }.formStyle(.grouped)
                if model.page != .about && model.page != .donation {
                Divider()
                HStack {
                    if model.receivingOrWaiting {Button(L("停止接收")){model.stop()}}
                    if model.running {Button(L("显示画面")){model.showCarPlayWindow()}}
                    Spacer()
                    Button(L(model.running ? "应用并重新连接" : "启动接收")){model.start()}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.preparingConnection)
                }.padding(16)
                }
            }.navigationTitle(L((model.page ?? .connection).rawValue))
        }.frame(minWidth:900,minHeight:560)
        .environment(\.locale,Locale(identifier:MacPlayLocalization.effectiveLanguage))
        .onChange(of:model.settings.ssid){_,_ in model.passwordStatus=""}
        .onAppear{updates.startAutomaticChecks()}
        .alert(L("发现新版本"),isPresented:$updates.showPrompt){
            Button(L(updates.installer == nil ? "查看发行说明" : "下载更新")){updates.openDownload()}
            Button(L("稍后"),role:.cancel){updates.dismissPrompt()}
        } message:{Text("MacPlay \(updates.release?.version?.description ?? "")")}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in model.detectNetwork();model.refreshUSB();model.refreshHardware();if model.settings.language == nil || model.settings.language == "system" {model.setLanguage("system")}}
    }
}

private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: PlayModel
    let delegate: MacPlayApplicationDelegate

    var body: some View {
        SettingsView(model:model).onAppear {
            let openScene=openWindow
            delegate.install(model,openMainWindow:{openScene(id:"main")})
        }
    }
}

@main struct MacPlayApp: App {
    @NSApplicationDelegateAdaptor(MacPlayApplicationDelegate.self) private var delegate
    @StateObject private var model=PlayModel()
    var body:some Scene {
        Window("MacPlay",id:"main") {MainWindowContent(model:model,delegate:delegate)}
            .defaultSize(width:820,height:650)
            .commands {CommandGroup(replacing:.newItem){};CommandGroup(after:.appInfo){Button(L("启动接收")){model.start()};Button(L("停止接收")){model.stop()}}}
    }
}
