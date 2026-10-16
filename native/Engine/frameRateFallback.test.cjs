const {test}=require('node:test');const assert=require('node:assert/strict');
const {FrameRateFallback}=require('../../build/engine/frameRateFallback.js');
const wait=()=>new Promise(r=>setTimeout(r,15));
test('120 timeout retries 90 exactly once',async()=>{const calls=[];const g=new FrameRateFallback(120,f=>calls.push(f),5);g.negotiationStarted();g.negotiationStarted();await wait();g.failed();assert.deepEqual(calls,[90])});
test('90 failure retries 60 exactly once',()=>{const calls=[];const g=new FrameRateFallback(90,f=>calls.push(f));g.negotiationStarted();g.failed();g.failed();assert.deepEqual(calls,[60])});
test('complete timeout chain terminates at 60',async()=>{const calls=[];for(const fps of [120,90,60]){const g=new FrameRateFallback(fps,f=>calls.push(f),5);g.negotiationStarted();await wait();}assert.deepEqual(calls,[90,60])});
test('pairing and authentication failures cannot downgrade',()=>{const g=new FrameRateFallback(120,()=>assert.fail());g.failed();g.cancel()});
test('video startup cancels pending retry',async()=>{const g=new FrameRateFallback(120,()=>assert.fail(),5);g.negotiationStarted();g.videoStarted();g.failed();await wait()});
test('manual stop cancels pending retry',async()=>{const g=new FrameRateFallback(90,()=>assert.fail(),5);g.negotiationStarted();g.cancel();g.failed();await wait()});
test('30 and 60 failures never retry',async()=>{for(const fps of [30,60]){const g=new FrameRateFallback(fps,()=>assert.fail(),5);g.negotiationStarted();g.failed();await wait()}});

const {VideoWaitDeadline}=require('../../build/engine/frameRateFallback.js');
test('final video wait expires once despite repeated negotiation',async()=>{let calls=0;const d=new VideoWaitDeadline(5,()=>calls++);d.arm();d.arm();await wait();d.arm();await wait();assert.equal(calls,1)});
test('video or manual stop cancels final wait',async()=>{const d=new VideoWaitDeadline(5,()=>assert.fail());d.arm();d.cancel();d.arm();await wait()});

test('decoder recovery failure reports whether frame-rate retry was scheduled',()=>{const calls=[];const high=new FrameRateFallback(120,f=>calls.push(f));assert.equal(high.failed(),false);high.negotiationStarted();assert.equal(high.failed(),true);assert.equal(high.failed(),false);assert.deepEqual(calls,[90]);const final=new FrameRateFallback(60,()=>assert.fail());final.negotiationStarted();assert.equal(final.failed(),false)});
