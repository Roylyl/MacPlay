import type { CpDisplayConfig } from './protocol/types'
interface DisplaySettings {
 width:number; height:number; fps:number
 resolution?:string; strictPixels?:boolean; screenPixelsVerified?:boolean
 screenPixelWidth?:number; screenPixelHeight?:number
 screenWidthMm?:number; screenHeightMm?:number
 screenLogicalWidth?:number; screenLogicalHeight?:number
 presentationWidth?:number; presentationHeight?:number
}
const positive=(value:unknown):value is number=>typeof value==='number'&&Number.isFinite(value)&&value>0
export function displayConfig(settings: DisplaySettings): CpDisplayConfig {
 if(!positive(settings.width)||!positive(settings.height))throw new Error('视频分辨率无效。')
 const width=Math.max(320,Math.min(7680,Math.round(settings.width/2)*2))
 const height=Math.max(200,Math.min(4320,Math.round(settings.height/2)*2))
 const exact=settings.strictPixels===true||settings.resolution==='native'
 const panelKnown=positive(settings.screenWidthMm)&&positive(settings.screenHeightMm)
 const pixelsKnown=settings.screenPixelsVerified===true&&positive(settings.screenPixelWidth)&&positive(settings.screenPixelHeight)
 if(exact&&(!pixelsKnown||!panelKnown))throw new Error('无法确认显示器物理参数，请刷新显示器或使用普通窗口模式。')
 const fps=[30,60,90,120].includes(settings.fps)?settings.fps:60
 let widthPhysicalMm:number, heightPhysicalMm:number
 if(exact){
  widthPhysicalMm=Math.max(1,Math.round(settings.screenWidthMm!*width/settings.screenPixelWidth!))
  heightPhysicalMm=Math.max(1,Math.round(settings.screenHeightMm!*height/settings.screenPixelHeight!))
 }else if(panelKnown&&positive(settings.screenLogicalWidth)&&positive(settings.screenLogicalHeight)&&positive(settings.presentationWidth)&&positive(settings.presentationHeight)){
  // Match the initial fitted window in AppKit points, independent of stream resolution.
  widthPhysicalMm=Math.max(1,Math.round(settings.screenWidthMm!*settings.presentationWidth/settings.screenLogicalWidth))
  heightPhysicalMm=Math.max(1,Math.round(settings.screenHeightMm!*settings.presentationHeight/settings.screenLogicalHeight))
 }else{
  // Existing protocol-compatible size. This is a fallback, never a measured panel size.
  widthPhysicalMm=200
  heightPhysicalMm=Math.max(1,Math.round(200*height/width))
 }
 return {widthPixels:width,heightPixels:height,widthPhysicalMm,heightPhysicalMm,fps,primaryInputDevice:1,viewArea:{top:0,bottom:0,left:0,right:0},safeArea:{top:0,bottom:0,left:0,right:0},safeAreaDrawOutside:true}
}
