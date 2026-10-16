const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs')
const {VideoHealth}=require('../../build/engine/videoHealth.js')
function fixture(){
 let now=0,keys=0;const configs=[],players=[],failures=[],reports=[],receiver=[0,0,1,1,0,0]
 const addon={
  openVideoReceiver(id,key,cb){configs.push(cb);return 1234},closeVideoReceiver(){},
  macplayPrepareVideoWindow(){return Buffer.alloc(8)},macplayWindowHandle(){},macplayCloseVideoWindow(){},
  createPlayer(codec,handle,atom,id,software){const p={decodedFrames:0,errors:0,width:0,height:0,decoder:software?'avdec_h264':'vtdec',software};players.push(p);return p},
  start(){},stop(p){p.stopped=true},setContentRegion(){},restartVideoFeed(){},probeCodecs:()=>({h264:{hw:true,sw:true}}),
  decodedVideoStatistics:p=>p,decodedVideoSize:p=>[p.width,p.height],videoReceiverStatistics:()=>receiver
 }
 const m={exports:{}}
 vm.runInNewContext(fs.readFileSync('build/engine/media.js','utf8'),{module:m,exports:m.exports,
  Date:class extends Date{static now(){return now}},
  require(id){if(id==='livi-gst-video')return addon;if(id==='node:fs')return {...fs,existsSync:()=>true};if(id==='./videoHealth')return {VideoHealth:class extends VideoHealth{constructor(){super(()=>now)}}};if(id.startsWith('node:'))return require(id);return {}},
  process:{env:{MACPLAY_RESOURCES:'/fixture'},arch:'arm64'},__dirname:'/fixture',console:{log(value){reports.push(JSON.parse(value))},warn(){}}})
 const media=m.exports;media.setVideoRecoveryCallbacks(()=>keys++,reason=>failures.push(reason));media.openScreenReceiver(1,Buffer.alloc(32));configs[0](0,Buffer.from([1]))
 return {media,configs,players,failures,reports,receiver,get keys(){return keys},tick(ms){now+=ms;media.pollVideoReady()}}
}
test('native decoder stall rebuilds software, requests a fresh keyframe and never reopens after close',()=>{
 const f=fixture();Object.assign(f.players[0],{decodedFrames:1,width:1280,height:720});f.receiver[0]=1;f.tick(250)
 f.receiver[0]=30;f.tick(2600)
 assert.equal(f.players.length,2);assert.equal(f.players[0].stopped,true);assert.equal(f.players[1].software,true);assert.ok(f.keys>0)
 f.media.closeScreenReceiver(1);const keys=f.keys;f.tick(10000);f.configs[0](0,Buffer.from([2]))
 assert.equal(f.players.length,2);assert.equal(f.keys,keys);assert.deepEqual(f.failures,[])
})
test('native TCP EOF receives one bounded recovery window and reports failure once',()=>{
 const f=fixture();Object.assign(f.players[0],{decodedFrames:1,width:1280,height:720});f.receiver[0]=1;f.tick(250)
 f.receiver[2]=0;f.receiver[4]=1;f.receiver[5]=1;f.tick(250)
 assert.equal(f.players.length,2);assert.equal(f.players[1].software,false)
 f.tick(8000);f.tick(1000);assert.deepEqual(f.failures,['视频恢复超时'])
})
test('actual receive and decode rates are independently measured at the native boundaries',()=>{
 const f=fixture();f.receiver[0]=120;f.receiver[1]=4096;Object.assign(f.players[0],{decodedFrames:100,width:1920,height:1080});f.tick(2000)
 const stats=f.reports.find(row=>row.type==='videoStatistics')
 assert.equal(stats.receivedFps,60);assert.equal(stats.decodedFps,50);assert.equal(stats.width,1920);assert.equal(stats.height,1080)
})
