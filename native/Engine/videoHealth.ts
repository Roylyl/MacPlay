// SPDX-License-Identifier: GPL-3.0-or-later
export type VideoHealthSample = {
 receivedFrames:number;decodedFrames:number;errors:number;connected:boolean;
 disconnects:number;lastDisconnectFrames:number;
}
export type VideoHealthAction = {rebuild?:string;software?:boolean;requestKey?:boolean;failure?:string}

// Timeouts require actual traffic that has stopped producing decoded frames.
// A static map or paused stream with no incoming frames is healthy.
export class VideoHealth {
 private received=0;private decoded=0;private errors=0;private disconnects=0;
 private lastInput=0;private lastOutput=0;private blockedFrames=0;
 private awaitingOutput=true;private lastKey=-Infinity;
 private recoveryDeadline:number|undefined;private transportDeadline:number|undefined;
 private retries:number[]=[];private totalRetries=0;private failed=false;
 constructor(private now:()=>number=Date.now){this.lastOutput=this.now()}

 decoderStarted(receivedFrames:number):void {
  this.received=receivedFrames;this.decoded=0;this.errors=0;
  this.lastOutput=this.now();this.lastInput=0;this.blockedFrames=0;this.awaitingOutput=true;
 }

 sample(s:VideoHealthSample):VideoHealthAction {
  if(this.failed)return {};
  const now=this.now(), action:VideoHealthAction={};
  const freshOutput=s.decodedFrames>this.decoded;
  if(s.receivedFrames>this.received){this.lastInput=now;this.blockedFrames+=s.receivedFrames-this.received}
  this.received=s.receivedFrames;
  if(s.disconnects>this.disconnects){
   this.disconnects=s.disconnects;
   // Repeated short-lived TCP connections must not extend the recovery deadline.
   this.transportDeadline??=now+8000;
   this.awaitingOutput=true;
   action.rebuild='video-channel-ended';
  }
  if(freshOutput){
   this.lastOutput=now;this.blockedFrames=0;this.awaitingOutput=false;this.recoveryDeadline=undefined;
   // Buffered frames from the old socket do not prove a video reconnection.
   if(s.connected&&s.receivedFrames>s.lastDisconnectFrames)this.transportDeadline=undefined;
  }
  this.decoded=s.decodedFrames;
  if((this.transportDeadline!==undefined&&now>=this.transportDeadline)||
     (this.recoveryDeadline!==undefined&&now>=this.recoveryDeadline))return this.fail('视频恢复超时');
  const error=s.errors>this.errors;this.errors=s.errors;
  const stalled=this.blockedFrames>=3&&now-this.lastOutput>=2500&&now-this.lastInput<=1000;
  if(error||stalled){
   this.retries=this.retries.filter(at=>now-at<60000);
   if(this.retries.length>=3||this.totalRetries>=6)return this.fail('视频解码恢复失败');
   this.retries.push(now);this.totalRetries++;
   this.recoveryDeadline??=now+8000;
   this.awaitingOutput=true;
   action.rebuild=error?'decoder-error':'decoder-output-stalled';action.software=true;
  }
  if(this.awaitingOutput&&now-this.lastKey>=900){action.requestKey=true;this.lastKey=now}
  return action;
 }
 private fail(reason:string):VideoHealthAction {this.failed=true;return {failure:reason}}
 get recoveries(){return this.totalRetries}
}
