const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs')
function fixture(){
 const configs=[],players=[],shown=[],stopped=[];let ready=0
 const addon={openVideoReceiver(id,key,cb){configs.push(cb);return 1234},closeVideoReceiver(){},macplayPrepareVideoWindow(){return Buffer.alloc(8)},createPlayer(){const p={size:[0,0]};players.push(p);return p},start(){},stop(p){stopped.push(p)},setContentRegion(){},decodedVideoSize:p=>p.size,decodedVideoStatistics:p=>({decodedFrames:p.size[0]?1:0,errors:0,width:p.size[0],height:p.size[1],decoder:'fixture'}),videoReceiverStatistics:()=>[1,100,1,1,0,0],macplayWindowHandle:aspect=>shown.push(aspect),macplayCloseVideoWindow(){}}
 const m={exports:{}}
 vm.runInNewContext(fs.readFileSync('build/engine/media.js','utf8'),{module:m,exports:m.exports,require(id){if(id==='livi-gst-video')return addon;if(id==='node:fs')return {...fs,existsSync:()=>true};if(id==='./videoHealth')return require('../../build/engine/videoHealth.js');if(id.startsWith('node:'))return require(id);return {}},process:{env:{MACPLAY_RESOURCES:'/fixture'},arch:'arm64'},__dirname:'/fixture',console:{log(){},warn(){}}})
 const media=m.exports;media.setVideoCallback(()=>ready++,16/9)
 return {media,configs,players,shown,stopped,get ready(){return ready}}
}
test('configuration creates a hidden decoder; decoded frame reveals once at actual aspect',()=>{
 const f=fixture();f.media.openScreenReceiver(1,Buffer.alloc(32));f.configs[0](0,Buffer.alloc(1));f.media.pollVideoReady();assert.equal(f.shown.length,0);assert.equal(f.ready,0)
 f.players[0].size=[1280,720];f.media.pollVideoReady();f.media.pollVideoReady();assert.deepEqual(f.shown,[16/9]);assert.equal(f.ready,1)
})
test('late configuration from a closed receiver cannot reopen the window after ID reuse',()=>{
 const f=fixture();f.media.openScreenReceiver(1,Buffer.alloc(32));f.media.closeScreenReceiver(1);f.media.openScreenReceiver(1,Buffer.alloc(32));f.configs[0](0,Buffer.alloc(1));assert.equal(f.players.length,0)
 f.configs[1](0,Buffer.alloc(1));f.players[0].size=[1920,1080];f.media.closeScreenReceiver(1);f.media.pollVideoReady();assert.equal(f.shown.length,0)
})
test('replacement decoder must decode its own frame before presenting',()=>{
 const f=fixture();f.media.openScreenReceiver(1,Buffer.alloc(32));f.configs[0](0,Buffer.alloc(1));f.players[0].size=[1280,720];f.configs[0](0,Buffer.alloc(2));f.media.pollVideoReady();assert.equal(f.shown.length,0);assert.equal(f.stopped.length,1)
 f.players[1].size=[1920,1080];f.media.pollVideoReady();assert.equal(f.ready,1)
})
