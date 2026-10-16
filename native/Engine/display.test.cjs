const {test}=require('node:test');const assert=require('node:assert/strict');
const {displayConfig}=require('../../build/engine/display.js');
const {buildInfoPlist}=require('../../build/engine/protocol/getInfo.js');
const panel={screenPixelWidth:3456,screenPixelHeight:2234,screenWidthMm:345,screenHeightMm:223,screenPixelsVerified:true,strictPixels:true};
const config=x=>displayConfig({...panel,width:1920,height:1080,fps:60,...x});
test('complete view area preserves requested pixels',()=>{
 const main=config({});
 const info=buildInfoPlist({main,deviceName:'MacPlay',deviceId:'02:00:00:00:00:01',btMac:'02:00:00:00:00:02',sourceVersion:'950.7.1',hevc:true,h264:true,entertainmentSampleRate:48000,icons:[],rightHandDrive:false});
 const d=info.displays[0];assert.equal(d.widthPixels,1920);assert.equal(d.heightPixels,1080);
 assert.equal(d.viewAreas[0].widthPixels,1920);assert.equal(d.viewAreas[0].heightPixels,1080);
});
for(const [width,height] of [[1280,720],[1920,1080],[2560,1440],[3456,2170]])test(`fixed physical size for ${width}x${height}`,()=>{
 for(const fps of [30,60,90,120]){
  const d=config({width,height,fps});assert.equal(d.widthPixels,width);assert.equal(d.heightPixels,height);assert.equal(d.fps,fps);
  assert.equal(d.widthPhysicalMm,Math.round(panel.screenWidthMm*width/panel.screenPixelWidth));
  assert.equal(d.heightPhysicalMm,Math.round(panel.screenHeightMm*height/panel.screenPixelHeight));
 }
});
test('legacy scale values cannot change display parameters',()=>{
 const base=config({});for(const scale of [50,100,200,350])assert.deepEqual(config({scale}),base);
});
test('missing real panel measurements are rejected instead of invented',()=>{
 for(const key of ['screenPixelWidth','screenPixelHeight','screenWidthMm','screenHeightMm'])for(const value of [undefined,0,NaN])assert.throws(()=>config({[key]:value}));
});
test('pixel rounding and unsupported frame rate fallback',()=>{
 const d=config({width:1921,height:1081,fps:999});assert.equal(d.widthPixels,1922);assert.equal(d.heightPixels,1082);assert.equal(d.fps,60);
});

test('high frame rate requests are reported unchanged',()=>{for(const fps of [90,120])assert.equal(config({fps}).fps,fps)});

test('ordinary window can connect without physical measurements',()=>{
 const d=displayConfig({width:1920,height:1080,fps:60,strictPixels:false});
 assert.equal(d.widthPixels,1920);assert.equal(d.widthPhysicalMm,200);assert.equal(d.heightPhysicalMm,113);
});
test('strict and native modes reject unverified pixel estimates',()=>{
 assert.throws(()=>config({screenPixelsVerified:false}));
 assert.throws(()=>config({strictPixels:false,resolution:'native',screenPixelsVerified:false}));
});
test('ordinary fitted window uses logical size when physical pixels are unavailable',()=>{
 const d=config({strictPixels:false,screenPixelsVerified:false,screenPixelWidth:undefined,screenPixelHeight:undefined,
  screenLogicalWidth:1728,screenLogicalHeight:1117,presentationWidth:960,presentationHeight:540});
 assert.equal(d.widthPhysicalMm,Math.round(345*960/1728));
 assert.equal(d.heightPhysicalMm,Math.round(223*540/1117));
});
