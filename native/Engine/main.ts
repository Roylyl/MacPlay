import { Discovery } from './discovery'
import fs from 'node:fs'
import path from 'node:path'
import net from 'node:net'
import os from 'node:os'
import { spawn } from 'node:child_process'
import readline from 'node:readline'
import { CpStack } from './protocol/cpStack'
import { loadOrCreateIdentity, accessoryDeviceId } from './protocol/identity'
import { CpHelperSock } from './CpHelperSock'
import { dataDir } from './storage'
import { addon, setVideoCallback, setVideoRecoveryCallbacks, pollVideoReady, showVideoWindow } from './media'
import { displayConfig } from './display'
import { FrameRateFallback, VideoWaitDeadline } from './frameRateFallback'
import { acceptsPhone } from './phoneSelection'
import { audioLevel, disconnectedAfterSession } from './runtimeControls'
import { validateWirelessNetwork } from './networkConfig'

const resources=process.env.MACPLAY_RESOURCES!
const settings=JSON.parse(fs.readFileSync(process.env.MACPLAY_SETTINGS_PATH || path.join(dataDir,'settings.json'),'utf8'))
const attempt=process.env.MACPLAY_ATTEMPT||'unknown',began=Date.now()
const diagnostic=(stage:string,detail:unknown='')=>console.log(JSON.stringify({attempt,elapsedMs:Date.now()-began,stage,detail}))
const log=(status:string,detail:string='')=>{diagnostic(status,detail);process.stdout.write(JSON.stringify({status,detail})+'\n')}
const networkCheck=validateWirelessNetwork(settings,os.networkInterfaces())
if (!networkCheck.ok) {
 diagnostic('network-validation',{code:networkCheck.code})
 log('网络连接配置无效',networkCheck.message)
 process.stdout.write(JSON.stringify({disconnected:true,reason:networkCheck.message})+'\n')
 process.exit(2)
}
diagnostic('network-validation',{interface:networkCheck.interface,families:networkCheck.families,receiverFamily:networkCheck.receiver?.family,alternate:!!networkCheck.receiver?.alternateHost})
let discovery:Discovery|undefined
let handoffStarted=false,networkConnected=false
let disconnectReason='连接已断开'
const videoDeadline=new VideoWaitDeadline(settings.fps>=90?25000:45000,()=>{
 if(!videoReady&&!stopping){disconnectReason=sessionReady?'CarPlay视频连接超时':'iPhone网络连接超时';diagnostic('handoff-summary',discovery?.summary());log(disconnectReason);process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}
})
const armDeadline=()=>{if(!videoReady)videoDeadline.arm()}

const usb=(usbStatus:string,usbError:string='')=>process.stdout.write(JSON.stringify({usbStatus,usbError})+'\n')
diagnostic('starting',{wireless:settings.wireless,interface:settings.wifiInterface,channel:settings.channel,width:settings.width,height:settings.height,fps:settings.fps})
const identity=loadOrCreateIdentity()
const icons=[256,512].map(size=>({widthPixels:size,heightPixels:size,data:fs.readFileSync(path.join(resources,'icons',`macplay-${size}.png`))}))
const helperControl=new CpHelperSock()
const config={deviceName:'MacPlay',deviceId:accessoryDeviceId(identity.pubRaw),btMac:settings.bluetoothMAC||'02:4d:50:00:00:02',sourceVersion:'950.7.1',hevc:true,h264:true,main:displayConfig(settings),port:17000,entertainmentSampleRate:48000 as const,disableAudioOutput:!settings.audioEnabled,audioVolume:(type:number)=>type===2 ? settings.callVolume??1 : type===3 ? settings.volume??1 : 1,audioDevice:()=>settings.outputDevice||undefined,audioInputDevice:()=>settings.inputDevice||undefined,mfi:helperControl,oemLabel:'MacPlay',icons,rightHandDrive:false}
const sessions=new Set<CpStack>()
let active: CpStack|undefined
let wiredReady=false
let videoReady=false
let sessionReady=false
let phoneInfo: {name:string;deviceId:string}|undefined
const frameRateGuard=new FrameRateFallback(settings.fps,fps=>{
 if(stopping||videoReady)return
 process.stdout.write(JSON.stringify({fallbackFps:String(fps),status:`${settings.fps}fps协商未启动视频，改用${fps}fps重连`,detail:"将自动降低帧率请求并重新连接。"})+"\n")
})
setVideoRecoveryCallbacks(()=>active?.forceMainKeyframe(),reason=>{
 if(stopping)return
 diagnostic('video-recovery-failed',{reason,videoReady})
 if(!videoReady && frameRateGuard.failed())return
 disconnectReason=reason;log(reason)
 process.stdout.write(JSON.stringify({disconnected:true,reason})+'\n');shutdown()
})
addon.macplaySelectDisplayOptions(settings.displayID||0)
addon.macplaySetWindowLanguage(process.env.MACPLAY_LANGUAGE||'system')
// Ordinary fitted windows do not depend on panel pixels; the native API still requires finite numbers.
const windowPanelWidth=Number.isFinite(settings.screenPixelWidth)&&settings.screenPixelWidth>0?settings.screenPixelWidth:config.main.widthPixels
const windowPanelHeight=Number.isFinite(settings.screenPixelHeight)&&settings.screenPixelHeight>0?settings.screenPixelHeight:config.main.heightPixels
addon.macplayConfigureWindowOptions(config.main.widthPixels,config.main.heightPixels,windowPanelWidth,windowPanelHeight,settings.resolution==='native',settings.strictPixels===true)
setVideoCallback(()=>{frameRateGuard.videoStarted();videoDeadline.cancel();const firstVideo = !videoReady;videoReady=true;if(firstVideo)process.stdout.write(JSON.stringify({showCarPlay:true})+'\n');if(phoneInfo?.deviceId){settings.targetBluetooth=phoneInfo.deviceId.replace(/-/g,':').toLowerCase();process.stdout.write(JSON.stringify({connectedPhone:phoneInfo.deviceId,phoneName:phoneInfo.name,connectedUSB:settings.wireless?'':settings.targetUSB||''})+'\n');}log('CarPlay已连接','首帧已解码，CarPlay画面窗口已打开');if(wiredReady)usb('已接收CarPlay视频，画面窗口已打开')},settings.width/settings.height)
const authDir=path.join(dataDir,'authentication')
if (!fs.existsSync(path.join(authDir,'identity.pk8')) || !fs.existsSync(path.join(authDir,'certificate.p7b'))) {
 log('缺少认证文件','请在关于页面打开认证目录，放入有使用权限的配套文件。');process.exit(2)
}
const helper=spawn(path.join(resources,'driver/livi-helperd'),[],{env:{...process.env,MACPLAY_AUTH_DIR:authDir,MACPLAY_RECEIVER_HOST:networkCheck.receiver?.host||'',MACPLAY_RECEIVER_ALTERNATE_HOST:networkCheck.receiver?.alternateHost||'',MACPLAY_WIFI_SSID:settings.ssid||'',MACPLAY_EXTERNAL_DISCOVERY:settings.wireless?'1':'0',LIVI_CP_NAME:'MacPlay',MACPLAY_SERIAL:'MACPLAY-'+identity.pairingId.toUpperCase(),LIVI_CP_DEVICE_ID:config.deviceId,LIVI_CP_AP_MAC:settings.wireless ? settings.accessPointMAC||'' : '',LIVI_CP_BT_MAC:config.btMac,LIVI_CP_PK:identity.pkHex,LIVI_CP_PI:identity.pairingId,LIVI_CP_AIRPLAY_PORT:'17000',LIVI_CP_WIRELESS:settings.wireless?'1':'0',LIVI_WIFI_IFACE:settings.wifiInterface||'en0',MACPLAY_TARGET_BT:settings.targetBluetooth||'',MACPLAY_TARGET_USB:settings.targetUSB||'',LIVI_PASSPHRASE:settings.password||'',LIVI_CHANNEL:String(settings.channel||36)},stdio:['ignore','pipe','pipe']})
for(const stream of [helper.stdout,helper.stderr]) readline.createInterface({input:stream!}).on('line',line=>{
 console.error(line)
 if(settings.wireless && networkConnected && line.includes('[cp-sock] listening on'))helperControl.networkConnected().catch(e=>diagnostic('network-handoff-cancel-error',String(e)))
 if(!videoReady && line.includes('Bluetooth SDP timed out')) log('蓝牙握手未完成','请在iPhone蓝牙页面与Mac完成配对，并确认两端配对码。')
 if(!videoReady && line.includes('Bluetooth RFCOMM timed out')) log('蓝牙重连超时','正在刷新iPhone服务信息，请保持iPhone蓝牙开启。')
 if(!videoReady && /failed|unavailable|error|refused|needs the shared/i.test(line) && !line.includes('iAP2 already runs over USB carkit')) log('连接需要检查',line)
 if(!videoReady && line.includes('MFi auth succeeded')) log('配件认证已通过','正在协商CarPlay连接')
 if(line.includes('CarPlayStartSession alternate address')){discovery?.announce();diagnostic('network-handoff-alternate',{family:'IPv6'})}
 if(!videoReady && line.includes('CarPlayStartSession sent')) {handoffStarted=true;discovery?.announce();diagnostic('network-handoff-started');frameRateGuard.negotiationStarted();armDeadline();log('已发送连接参数','等待iPhone连接接收端')}
 if(line.includes('usbmuxd carkit up')) {wiredReady=true;usb('USB通信已建立，正在识别配件')}
 if(line.includes('wired: identification accepted')) usb('iPhone已接受配件识别')
 if(line.includes('wired: MFi auth succeeded')) usb('配件认证已通过，正在建立CarPlay会话')
 if(line.includes('wired: CarPlayStartSession sent')) usb('已发送CarPlay连接参数')
 if(line.includes('usbmuxd carkit failed')) usb('USB通信失败','无法打开iPhone的CarPlay服务，请解锁并确认信任后重新连接。')
 if(line.includes('unplugged')) {const hadWired=wiredReady;wiredReady=false;usb('iPhone已拔出');if(!settings.wireless && hadWired && (videoReady||sessionReady)){process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}}
})
helper.on('error',e=>log('连接后端启动失败',e.message))
helper.on('exit',code=>{if(!stopping){log('连接后端已退出',String(code));process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}})
const server=net.createServer(socket=>{
 networkConnected=true;discovery?.networkConnected();
 if(settings.wireless)helperControl.networkConnected().catch(e=>diagnostic('network-handoff-cancel-error',String(e)));
 socket.once('close',()=>{if(!active&&!stopping){networkConnected=false;discovery?.announce()}})
 const usbSession=wiredReady && !socket.remoteAddress?.endsWith('%'+settings.wifiInterface)
 diagnostic('control-connected',{family:socket.remoteFamily});if(!videoReady)log('收到连接请求','正在协商认证与音视频')
 const stack=new CpStack(config);sessions.add(stack)
 stack.deviceFilter=id=>acceptsPhone(settings.targetBluetooth,id,!!active && active!==stack)
 stack.on('device-info',(info:{name:string;deviceId:string})=>{active=stack;phoneInfo=info})
 stack.setVideoActive(true);stack.setAudioActive(settings.audioEnabled)
 stack.on('session-active',()=>{sessionReady=true;frameRateGuard.negotiationStarted();armDeadline();stack.setStreamVolume(3,settings.volume??1,0);stack.setStreamVolume(2,settings.callVolume??1,0);if(!videoReady)log('CarPlay会话已建立','等待视频流');if(usbSession)usb('CarPlay会话已建立，等待视频流')})
 stack.on('disconnect-reason',(reason:string)=>{disconnectReason=reason})
 stack.on('session-ended',()=>{const hadVideo=videoReady;frameRateGuard.failed();sessions.delete(stack);if(active===stack){active=undefined;videoReady=false;sessionReady=false;log(disconnectReason,'重新启动接收可再次连接');if(disconnectedAfterSession(hadVideo,stopping,settings.fps)){process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}}if(usbSession)usb('CarPlay会话已断开，可点击“应用并重新连接”')})
 stack.on('host-ui-requested',()=>{process.stdout.write(JSON.stringify({showMain:true})+'\n');diagnostic('show-main')})
 stack.on('error',(e:Error)=>{diagnostic('session-error',e.message);if(!videoReady)log('会话错误',e.message)})
 stack.attachSocket(socket)
})
server.on('error',e=>{log('接收服务启动失败',e.message);shutdown()})
server.listen({port:17000,host:'::',ipv6Only:false},()=>{
 if(settings.wireless)discovery=new Discovery(settings.wifiInterface||'en0',{deviceId:config.deviceId,pk:identity.pkHex,pi:identity.pairingId,btMac:config.btMac},settings.targetBluetooth||'',()=>handoffStarted&&!networkConnected&&!stopping,s=>diagnostic('network-discovery',s))
 log('等待iPhone连接',settings.wireless?'无线CarPlay接收已启用，请在系统蓝牙中配对iPhone':'有线CarPlay接收已启用，请连接USB数据线')
})
let mediaTicks=0,lastCounts=[0,0]
const mediaStats=setInterval(()=>{
 const counts:number[]=addon.mediaActivity();mediaTicks++
 if(counts[0]>0 && lastCounts[0]===0)diagnostic('first-video-packet')
 if(counts[1]>0 && lastCounts[1]===0)diagnostic('first-audio-packet')
 if(mediaTicks%2===0){const streams=JSON.parse(addon.audioStatistics());process.stdout.write(JSON.stringify({type:'audioStatistics',streams})+'\n');if(mediaTicks%30===0){diagnostic('media-statistics',{videoPackets:counts[0],audioPackets:counts[1]});diagnostic('audio-statistics',streams)}}
 lastCounts=counts
},1000)
const pump=setInterval(()=>{
 try {
  pollVideoReady()
  const events:number[]=addon.macplayPumpEvents()
  for(let i=0;i<events.length;i+=3)active?.sendTouches([{x:events[i],y:events[i+1],down:events[i+2]===1,id:0}])
  if(addon.macplayTakeWindowAction()===1 && !stopping){process.stdout.write(JSON.stringify({disconnected:true,manual:true,reason:'主动断开连接'})+'\n');shutdown()}
 }catch(e){console.error(e)}
},8)
readline.createInterface({input:process.stdin}).on('line',line=>{
 if(line==='show'){if(videoReady)showVideoWindow();else log('等待CarPlay视频','视频尚未建立，暂不打开空白画面窗口。')}
 try {
  const update=JSON.parse(line)
  if(update.command==='language' && typeof update.language==='string')addon.macplaySetWindowLanguage(update.language)
  if(update.command==='seek' && active && videoReady && phoneInfo?.deviceId) {
   const ms=Number(update.positionMs),id=String(update.requestId||'')
   if(Number.isInteger(ms)&&ms>=0&&ms<=0xffffffff&&id) {
    helperControl.seekPlayback(phoneInfo.deviceId,ms,id,typeof update.trackId==='string'?update.trackId:undefined)
     .catch(()=>process.stdout.write(JSON.stringify({type:'seekResult',requestId:id,sent:false})+'\n'))
   }
  }
  if(update.command==='audio-devices') {
   if(typeof update.inputDevice==='string' && typeof update.outputDevice==='string') {
    settings.inputDevice=update.inputDevice;settings.outputDevice=update.outputDevice
    for(const stack of sessions)stack.setAudioDevices(update.inputChanged===true,update.outputChanged===true)
   }
  }
  if(update.command==='audio') {
   settings.volume=audioLevel(update.volume,settings.volume??1)
   settings.callVolume=audioLevel(update.callVolume,settings.callVolume??1)
   settings.audioEnabled=!!update.enabled
   for(const stack of sessions){stack.setStreamVolume(3,settings.volume,0);stack.setStreamVolume(2,settings.callVolume,0);stack.setAudioActive(settings.audioEnabled)}
  }
 } catch {}
 if(line.startsWith('media ')){const index=Number(line.slice(6));if(Number.isInteger(index)&&index>=1&&index<=5)active?.sendMedia(index)}
 if(line==='stop')shutdown()
})
const startupDeadline=setTimeout(()=>{if(!stopping&&!videoReady){disconnectReason='连接启动超时';diagnostic('handoff-summary',discovery?.summary());log(disconnectReason);process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}},90000)
let stopping=false
function shutdown(){if(stopping)return;stopping=true;discovery?.destroy();clearTimeout(startupDeadline);videoDeadline.cancel();frameRateGuard.cancel();clearInterval(pump);clearInterval(mediaStats);for(const s of sessions)s.stop();addon.macplayCloseVideoWindow();server.close();helper.kill('SIGTERM');setTimeout(()=>process.exit(0),300).unref()}
process.on('SIGTERM',shutdown);process.on('SIGINT',shutdown);process.stdin.on('end',shutdown)
