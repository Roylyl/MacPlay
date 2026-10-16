import { waitForMicrophone } from './microphonePermission'
import fs from 'node:fs'
import path from 'node:path'
import { VideoHealth } from './videoHealth'
const root = process.env.MACPLAY_RESOURCES || path.resolve(__dirname, '../..')
const archDir = process.arch === 'x64' ? 'macos-x64' : 'macos-arm64'
let gst = path.join(root, 'gstreamer', archDir)
if (!fs.existsSync(gst)) {
  const armFallback = path.join(root, 'gstreamer/macos-arm64')
  if (fs.existsSync(armFallback)) {
    gst = armFallback
  } else {
    gst = path.join(root, 'gstreamer/macos')
  }
}
process.env.GST_PLUGIN_SYSTEM_PATH = ''
process.env.GST_PLUGIN_PATH = path.join(gst,'lib/gstreamer-1.0')
process.env.GST_PLUGIN_SCANNER = path.join(gst,'libexec/gstreamer-1.0/gst-plugin-scanner')
export const addon: any = require('livi-gst-video')
export const VIDEO_PLANE_MAIN = 1, VIDEO_PLANE_CLUSTER_RECV = 2
export type CpAudioCodec = 'aac-lc'|'opus'|'pcm'
export const gstHost: any = { onAudioStarted: () => {} }
const audioReceivers = new Map<number, object>()
let windowHandle: Buffer | undefined
let player: any, aspect=16/9
let videoGeneration=0, firstFramePending=false, presented=false
const receivers=new Map<number,object>()
let currentReceiver:number|undefined, configuration:{codec:string;atom:Buffer}|undefined
let health:VideoHealth|undefined, softwareDecoder=false, failedVideo=false
let requestVideoKey:(()=>void)|undefined, failVideo:((reason:string)=>void)|undefined
let lastHealthPoll=0,lastStatsAt=0,lastReceived=0,lastDecoded=0,retiredDecoded=0
export let onVideo: (()=>void)|undefined
export function setVideoCallback(callback:()=>void, ratio:number) { onVideo=callback; aspect=ratio }
export function setVideoRecoveryCallbacks(requestKey:()=>void,failed:(reason:string)=>void) {requestVideoKey=requestKey;failVideo=failed}

function failCurrentVideo(reason:string) {
 if(failedVideo)return
 failedVideo=true
 console.log(JSON.stringify({stage:'video-recovery-failed',reason}))
 failVideo?.(reason)
}

function createVideoPlayer(recovery=false):boolean {
 if(!configuration||currentReceiver===undefined||failedVideo)return false
 videoGeneration++;firstFramePending=true
 if(player){retiredDecoded+=Number(addon.decodedVideoStatistics(player).decodedFrames)||0;addon.stop(player);player=undefined}
 // A rebuilt decoder cannot safely consume delta frames left from the old GOP.
 if(recovery)addon.restartVideoFeed(currentReceiver)
 const handle=windowHandle ?? (windowHandle=addon.macplayPrepareVideoWindow(aspect))
 player=addon.createPlayer(configuration.codec,handle,configuration.atom,currentReceiver,softwareDecoder)
 if(!player){failCurrentVideo('无法创建CarPlay视频解码器');return false}
 const receiver:number[]=addon.videoReceiverStatistics(currentReceiver)
 health?.decoderStarted(receiver[0]||0)
 addon.start(player);addon.setContentRegion(player,0,0,aspect*1000,1000,aspect*1000,1000)
 return true
}

export function openScreenReceiver(id:number,key:Buffer):number {
 const token={};receivers.set(id,token)
 currentReceiver=id;configuration=undefined;health=new VideoHealth();softwareDecoder=false;failedVideo=false
 lastHealthPoll=0;lastStatsAt=Date.now();lastReceived=0;lastDecoded=0;retiredDecoded=0
 return addon.openVideoReceiver(id,key,(codec:number,atom:Buffer)=>{
  if(receivers.get(id)!==token||currentReceiver!==id||failedVideo)return
  configuration={codec:codec===1?'h265':'h264',atom}
  createVideoPlayer()
 })
}
export function closeScreenReceiver(id:number) {
 receivers.delete(id);addon.closeVideoReceiver(id)
 if(currentReceiver!==id)return
 currentReceiver=undefined;health=undefined;configuration=undefined;videoGeneration++;firstFramePending=false;presented=false
 if(player){addon.stop(player);player=null} addon.macplayCloseVideoWindow();windowHandle=undefined
}
export function openAudioReceiver(key:Buffer,o:any,started?:(id:number,sample:number)=>void):any {
 // The native receiver owns this callback; another control connection must not
 // replace its media-clock or microphone owner. Also reject callbacks already
 // queued on the JS thread before close, including after a native ID is reused.
 const token = {}
 const receiver = addon.openAudioReceiver(key,o.codec,o.payloadType,o.clockRate,o.channels,o.latencyMs,o.realtime,o.device,(id:number,sample:number)=>{
  if(audioReceivers.get(id)!==token)return
  started?.(id,sample)
 })
 if(receiver)audioReceivers.set(receiver.streamId,token)
 return receiver
}
export function closeAudioReceiver(id:number) {audioReceivers.delete(id);addon.closeAudioReceiver(id)}
export function setAudioReceiverActive(id:number,active:boolean) {addon.setAudioReceiverActive(id,active)}
export function setAudioReceiverVolume(id:number,level:number,ms:number) {addon.setAudioReceiverVolume(id,level,ms)}
export async function openMicUplink(key:Buffer,o:any,current:()=>boolean):Promise<number|null> {
 if(!await waitForMicrophone(current,()=>addon.microphonePermission())) {
  if(current())console.warn('[cp_mic] microphone permission denied')
  return null
 }
 if(!current())return null
 return addon.openMicUplink(key,o.codec,o.payloadType,o.sampleRate,o.channels,o.bitrate,o.frameMs,o.port,o.phone,o.device)
}
export function closeMicUplink(id:number){addon.closeMicUplink(id)}

// Called from the main-thread event pump. Decoder buffers are observed on the
// decoder output pad, never inferred from codec configuration or TCP packets.
export function pollVideoReady() {
 pollVideoHealth()
 if(!player||!firstFramePending||failedVideo)return
 const generation=videoGeneration, current=player
 const [width,height]:number[]=addon.decodedVideoSize(current)
 if(width<=0||height<=0||generation!==videoGeneration||current!==player)return
 firstFramePending=false;aspect=width/height
 addon.setContentRegion(player,0,0,width,height,width,height)
 if(!presented){addon.macplayWindowHandle(aspect);presented=true}
 else addon.macplayPrepareVideoWindow(aspect)
 console.log(JSON.stringify({stage:'first-decoded-frame',width,height}))
 onVideo?.()
}

function pollVideoHealth() {
 if(currentReceiver===undefined||!health||failedVideo)return
 const now=Date.now();if(now-lastHealthPoll<250)return;lastHealthPoll=now
 const receiver:number[]=addon.videoReceiverStatistics(currentReceiver)
 if(receiver.length<6)return
 const decoded=player?addon.decodedVideoStatistics(player):{decodedFrames:0,errors:0,width:0,height:0,decoder:''}
 const action=health.sample({receivedFrames:receiver[0],decodedFrames:decoded.decodedFrames,errors:decoded.errors,
  connected:receiver[2]===1,disconnects:receiver[4],lastDisconnectFrames:receiver[5]})
 if(action.failure){failCurrentVideo(action.failure);return}
 if(action.rebuild&&configuration){
  if(action.software&&addon.probeCodecs()[configuration.codec]?.sw)softwareDecoder=true
  console.log(JSON.stringify({stage:'video-recovery',reason:action.rebuild,software:softwareDecoder,recoveries:health.recoveries}))
  createVideoPlayer(true)
 }
 if(failedVideo||!health||currentReceiver===undefined)return
 if(action.requestKey&&configuration)requestVideoKey?.()
 if(now-lastStatsAt>=2000){
  // Use cumulative decoded frames across decoder replacements. These are measured
  // output frames, not the monitor refresh rate or requested CarPlay frame rate.
  const total=retiredDecoded+(player?Number(addon.decodedVideoStatistics(player).decodedFrames)||0:0)
  const elapsed=(now-lastStatsAt)/1000
  console.log(JSON.stringify({type:'videoStatistics',codec:configuration?.codec||'',decoder:decoded.decoder,
   width:decoded.width,height:decoded.height,receivedFps:Math.round(Math.max(0,receiver[0]-lastReceived)/elapsed*10)/10,
   decodedFps:Math.round(Math.max(0,total-lastDecoded)/elapsed*10)/10,receivedFrames:receiver[0],decodedFrames:total,
   receivedBytes:receiver[1],connected:receiver[2]===1,decoderRecoveries:health.recoveries,software:!!decoded.software}))
  lastStatsAt=now;lastReceived=receiver[0];lastDecoded=total
 }
}

export function showVideoWindow(){if(presented&&player)addon.macplayWindowHandle(aspect)}
