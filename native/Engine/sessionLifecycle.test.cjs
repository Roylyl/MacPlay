const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {EventEmitter}=require('node:events');
const engine=path.resolve(__dirname,'../../build/engine');
const plist=require(path.join(engine,'protocol/bplist.js'));

// Exercise the control protocol without creating a real decoder or connecting
// an iPhone. All media operations stay in this isolated module context.
function fixture(clock=process.hrtime.bigint,network){
 const closedVideo=[];
 const closedAudio=[],closedMicrophones=[];
 let counts=[0,0];
 const media={addon:{mediaActivity:()=>counts},onAudioReceiverStarted(){},gstHost:{onAudioStarted(){}},
  closeScreenReceiver(id){closedVideo.push(id)},
  closeAudioReceiver(id){closedAudio.push(id)},closeMicUplink(id){closedMicrophones.push(id)}};
 const module={exports:{}};
 const localRequire=id=>{
  if(id==='node:net' && network)return network;
  if(id.startsWith('node:'))return require(id);
  if(id==='../media')return media;
  if(id==='./bplist')return plist;
  if(id==='./pairSetup')return {PairSetup:class {}};
  if(id==='./pairVerify')return {PairVerify:class {}};
  return {};
 };
 vm.runInNewContext(fs.readFileSync(path.join(engine,'protocol/cpStack.js'),'utf8'),
  {module,exports:module.exports,require:localRequire,Buffer,setImmediate,clearInterval,
   setInterval:()=>({unref(){}}),
   process:{...process,hrtime:{bigint:clock}},
   console:{log(){},warn(){}}});
 const stack=new module.exports.CpStack({mfi:{}});
 const session={audioMeta:[],screenNativeId:7,screenInProcess:true,
  clusterScreenNativeId:null,screen:{stop(){}}};
 stack._liveSession=session;
 return {stack,session,closedVideo,closedAudio,closedMicrophones,setCounts:(value)=>{counts=value}};
}
const turn=()=>new Promise(resolve=>setImmediate(resolve));

class Socket extends EventEmitter {
 remoteAddress='192.0.2.2';remotePort=1234;destroyed=false;
 setKeepAlive(){}
 destroy(){if(!this.destroyed){this.destroyed=true;setImmediate(()=>this.emit('close'))}}
}

test('closing before RECORD releases the connection without a session disconnect',async()=>{
 const {stack}=fixture();stack._liveSession=null;
 const socket=new Socket(),events=[];
 stack.on('connection-closed',()=>events.push('connection-closed'));
 stack.on('session-ended',()=>events.push('session-ended'));
 stack.attachSocket(socket);
 assert.equal(stack._sessionSock.size,1);
 socket.destroy();await turn();
 assert.deepEqual(events,['connection-closed']);
 assert.equal(stack._sessionSock.size,0);assert.equal(stack._conns.size,0);
});

test('closing after RECORD ends the session once before releasing the connection',async()=>{
 const {stack}=fixture();stack._liveSession=null;
 const socket=new Socket(),events=[];
 stack.on('connection-closed',()=>events.push('connection-closed'));
 stack.on('session-ended',()=>events.push('session-ended'));
 stack.attachSocket(socket);
 stack._liveSession=[...stack._sessionSock.keys()][0];
 socket.destroy();await turn();
 assert.deepEqual(events,['session-ended','connection-closed']);
 assert.equal(stack._liveSession,null);assert.equal(stack._sessionSock.size,0);
});

test('a replaced event socket cannot clear the new touch and media channel',async()=>{
 let accept;
 const network={createServer(callback){accept=callback;return {
  on(){},listen(options,ready){ready()},address(){return {port:1234}},close(){}
 }}};
 const {stack,session}=fixture(undefined,network);session.pairVerify={};
 await stack._openEventChannel(session);
 const oldSocket=new Socket(),newSocket=new Socket();
 accept(oldSocket);accept(newSocket);await turn();
 assert.equal(oldSocket.destroyed,true);
 assert.equal(session.eventSock,newSocket);assert.equal(stack._active,session);
 newSocket.destroy();await turn();
 assert.equal(session.eventSock,null);assert.equal(stack._active,null);
});

test('a TCP connection does not confirm a wireless handoff before RECORD',()=>{
 const {stack}=fixture();
 stack._liveSession=null;
 assert.equal(stack.hasVerifiedSession,false);
});

test('RECORD confirms a handoff only after authentication and device selection',async()=>{
 for(const [verified,accepted,expected] of [[false,false,false],[false,true,false],[true,false,false],[true,true,true]]) {
  const {stack,session}=fixture();
  session.pairVerify={verified};session.peerHost='192.0.2.2';
  stack.deviceAccepted=accepted;stack._liveSession=null;
  stack._openIapMessageRelay=()=>{};
  const observed=[];
  stack.on('session-active',()=>observed.push(stack.hasVerifiedSession));
  const response=await stack._handle({method:'RECORD',path:'/',body:Buffer.alloc(0)},session);
  assert.equal(response.status,200,'the handoff guard does not change RTSP compatibility');
  assert.deepEqual(observed,[expected]);
  session.ended=true;
  assert.equal(stack.hasVerifiedSession,false,'an ended session cannot lock the handoff');
  session.ended=false;stack.stop();
  assert.equal(stack.hasVerifiedSession,false,'stopping clears the confirmed session');
 }
});

test('CarPlay host application button requests the main window',()=>{
 const {stack,session}=fixture();let requested=0;
 stack.on('host-ui-requested',()=>requested++);
 const result=stack._handleCommand({body:plist.encodeBplist({type:'requestUI'})},session);
 assert.equal(result.status,200);assert.equal(requested,1);
});

test('session teardown ends reception even if the control socket remains open',async()=>{
 const {stack,session,closedVideo}=fixture();let ended=0;
 stack.on('session-ended',()=>ended++);
 const result=stack._handleTeardown({body:Buffer.alloc(0)},session);
 assert.equal(result.status,200);assert.deepEqual(closedVideo,[7]);
 assert.equal(ended,0,'allow the RTSP response to be written first');
 await turn();assert.equal(ended,1);assert.equal(stack._liveSession,null);
 stack._handleTeardown({body:Buffer.alloc(0)},session);
 await turn();assert.equal(ended,1,'a repeated teardown does not repeat disconnect');
});

test('audio-only teardown preserves the CarPlay window and session',async()=>{
 const {stack,session,closedVideo}=fixture();let ended=0;
 stack.on('session-ended',()=>ended++);
 stack._handleTeardown({body:plist.encodeBplist({streams:[{type:100}]})},session);
 await turn();assert.deepEqual(closedVideo,[]);assert.equal(ended,0);
 assert.equal(stack._liveSession,session);
});

test('stopping the host suppresses an already queued passive disconnect',async()=>{
 const {stack,session}=fixture();let ended=0;
 stack.on('session-ended',()=>ended++);
 stack._handleTeardown({body:Buffer.alloc(0)},session);stack.stop();
 await turn();assert.equal(ended,0);
});

test('stop releases media before returning and before destroying the control socket',async()=>{
 const {stack,session,closedVideo,closedAudio,closedMicrophones}=fixture();
 session.audioMeta=[{hostStreamId:11,inProcess:true,micStreamId:12}];
 let destroys=0,ended=0;
 const sock={destroy(){
  destroys++;
  assert.deepEqual(closedVideo,[7]);
  assert.deepEqual(closedAudio,[11]);
  assert.deepEqual(closedMicrophones,[12]);
  setImmediate(()=>stack._teardown(session));
 }};
 stack._conns.add(sock);stack._sessionSock.set(session,sock);stack._active=session;
 stack.on('session-ended',()=>ended++);
 stack.stop();
 assert.equal(session.ended,true);
 assert.equal(stack._active,null);assert.equal(stack._liveSession,null);
 assert.equal(stack._sessionSock.size,0);assert.equal(stack._conns.size,0);
 stack.stop();await turn();
 assert.equal(destroys,1);assert.equal(ended,0);
 assert.deepEqual(closedVideo,[7]);assert.deepEqual(closedAudio,[11]);assert.deepEqual(closedMicrophones,[12]);
});

test('stopping an unaccepted control connection does not close another stacks video',()=>{
 const active=fixture(),probe=fixture();
 probe.session.screenNativeId=null;
 const sock={destroy(){}};
 probe.stack._conns.add(sock);probe.stack._sessionSock.set(probe.session,sock);
 probe.stack.stop();
 assert.deepEqual(probe.closedVideo,[]);assert.deepEqual(active.closedVideo,[]);
 assert.equal(active.session.ended,undefined);
});

test('no negotiated heartbeat keeps static video connected',()=>{
 const {stack,session}=fixture();session.lastCtrlReadNs=1n;let ends=0;stack.on('session-ended',()=>ends++);
 stack._checkHeartbeat(session);assert.equal(ends,0);
});
test('established heartbeat timeout ends only the live session once',()=>{
 const {stack,session}=fixture();session.lastCtrlReadNs=1n;session.timing={lastActivityNs:1n,stop(){}};session.mediaCounts=[0,0];let ends=0;
 stack.on('session-ended',()=>ends++);stack._checkHeartbeat(session);stack._checkHeartbeat(session);assert.equal(ends,1);
});
test('active decrypted media prevents a heartbeat false positive',()=>{
 const {stack,session,setCounts}=fixture();session.lastCtrlReadNs=1n;session.timing={lastActivityNs:1n,stop(){}};session.mediaCounts=[0,0];setCounts([1,0]);
 stack.on('session-ended',()=>assert.fail());stack._checkHeartbeat(session);
});

function heartbeatFixture(){
 let now=1n,ends=0;
 const f=fixture(()=>now);
 f.session.lastCtrlReadNs=now;f.session.timing={lastActivityNs:now,stop(){}};f.session.mediaCounts=[0,0];
 f.stack.on('session-ended',()=>ends++);
 f.stack._checkHeartbeat(f.session);
 return {...f,get ends(){return ends},tick(seconds){now+=BigInt(seconds)*1_000_000_000n;f.stack._checkHeartbeat(f.session)},heartbeat(){f.session.timing.lastActivityNs=now}};
}

test('a late timer after live resize lets queued heartbeat packets run',()=>{
 const f=heartbeatFixture();
 f.tick(20);assert.equal(f.ends,0,'JS inactivity is not proof of network inactivity');
 f.heartbeat();
 for(let i=0;i<20;i++){f.tick(1);f.heartbeat()}
 assert.equal(f.ends,0);
});

test('heartbeat silence gets one full grace period after the event loop resumes',()=>{
 const f=heartbeatFixture();
 f.tick(20);
 for(let i=0;i<14;i++)f.tick(1);
 assert.equal(f.ends,0);
 f.tick(1);assert.equal(f.ends,1);
 f.tick(1);assert.equal(f.ends,1,'late checks must not repeat teardown');
});

test('normal heartbeat checks do not extend the fifteen second silence limit',()=>{
 const f=heartbeatFixture();
 for(let i=0;i<14;i++)f.tick(1);
 assert.equal(f.ends,0);
 f.tick(1);assert.equal(f.ends,1);
});
