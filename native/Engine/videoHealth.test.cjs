const {test}=require('node:test'),assert=require('node:assert/strict')
const {VideoHealth}=require('../../build/engine/videoHealth.js')
function fixture(){let now=0;const health=new VideoHealth(()=>now),state={receivedFrames:0,decodedFrames:0,errors:0,connected:true,disconnects:0,lastDisconnectFrames:0};return {health,state,tick(ms,change={}){now+=ms;Object.assign(state,change);return health.sample(state)}}}
test('static maps and isolated undecoded frames never trigger a stall recovery',()=>{
 const f=fixture();f.health.decoderStarted(0);f.tick(100,{receivedFrames:1,decodedFrames:1})
 assert.equal(f.tick(60000).rebuild,undefined)
 f.tick(1,{receivedFrames:2});assert.equal(f.tick(3000).rebuild,undefined)
})
test('continuing input without decoded output rebuilds, then limits recovery attempts',()=>{
 const f=fixture();f.health.decoderStarted(0);f.tick(100,{receivedFrames:1,decodedFrames:1})
 for(let i=0;i<3;i++){
  const action=f.tick(2600,{receivedFrames:f.state.receivedFrames+20,decodedFrames:0})
  assert.equal(action.rebuild,'decoder-output-stalled');assert.equal(action.software,true)
  f.health.decoderStarted(f.state.receivedFrames)
 }
 assert.equal(f.tick(2600,{receivedFrames:100}).failure,'视频解码恢复失败')
})
test('decoder error is actionable without waiting for traffic and output cancels its deadline',()=>{
 const f=fixture();f.health.decoderStarted(0)
 assert.equal(f.tick(0,{errors:1}).rebuild,'decoder-error');f.health.decoderStarted(0)
 assert.equal(f.tick(100,{decodedFrames:1,receivedFrames:1,errors:0}).failure,undefined)
 assert.equal(f.tick(10000).failure,undefined)
})
test('video TCP EOF is bounded even if reconnecting sockets provide no frames',()=>{
 const f=fixture();f.tick(0,{decodedFrames:1,receivedFrames:1})
 assert.equal(f.tick(1,{disconnects:1,connected:false,lastDisconnectFrames:1}).rebuild,'video-channel-ended')
 f.health.decoderStarted(1);f.tick(4000,{disconnects:2,connected:true,decodedFrames:0})
 assert.equal(f.tick(4000).failure,'视频恢复超时');assert.deepEqual(f.tick(1000),{})
})
test('buffered old output cannot cancel EOF deadline; fresh reconnected video can',()=>{
 const old=fixture();old.tick(0,{receivedFrames:10,decodedFrames:9});old.tick(0,{disconnects:1,connected:false,lastDisconnectFrames:10})
 old.tick(100,{decodedFrames:10});assert.equal(old.tick(8000).failure,'视频恢复超时')
 const fresh=fixture();fresh.tick(0,{receivedFrames:10,decodedFrames:10});fresh.tick(1,{disconnects:1,connected:false,lastDisconnectFrames:10})
 fresh.health.decoderStarted(10);fresh.tick(100,{connected:true,receivedFrames:11,decodedFrames:1})
 assert.equal(fresh.tick(10000).failure,undefined)
})
test('keyframe requests are throttled and stop after decoded output',()=>{
 const f=fixture();assert.equal(f.tick(0).requestKey,true);assert.equal(f.tick(899).requestKey,undefined)
 assert.equal(f.tick(1).requestKey,true);assert.equal(f.tick(1,{receivedFrames:1,decodedFrames:1}).requestKey,undefined)
 assert.equal(f.tick(5000).requestKey,undefined)
})
