/** Retry only after the authenticated accessory has asked iPhone to start CarPlay. */
export class FrameRateFallback {
 private timer:ReturnType<typeof setTimeout>|undefined
 private armed=false
 private finished=false
 constructor(private fps:number,private retry:(fps:number)=>void,private delayMs=20000){}
 negotiationStarted(){
  if(this.finished||this.armed||![90,120].includes(this.fps))return
  this.armed=true;this.timer=setTimeout(()=>this.failed(),this.delayMs)
 }
 failed(){
  if(!this.armed||this.finished)return false
  this.cancel();this.retry(this.fps===120?90:60);return true
 }
 videoStarted(){this.cancel()}
 cancel(){this.finished=true;this.armed=false;if(this.timer)clearTimeout(this.timer);this.timer=undefined}
}

/** One deadline per negotiation: repeated handshake messages never extend it. */
export class VideoWaitDeadline {
 private timer:ReturnType<typeof setTimeout>|undefined
 private finished=false
 constructor(private delayMs:number,private expired:()=>void){}
 arm(){if(this.finished||this.timer)return;this.timer=setTimeout(()=>{this.timer=undefined;this.finished=true;this.expired()},this.delayMs)}
 cancel(){this.finished=true;if(this.timer)clearTimeout(this.timer);this.timer=undefined}
}
