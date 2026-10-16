import os from 'node:os'
import {isIP} from 'node:net'

type InterfaceAddress = NonNullable<ReturnType<typeof os.networkInterfaces>[string]>[number]
export type ReceiverNetwork = {host:string; family:'IPv4'|'IPv6'; alternateHost?:string}

function usableIPv4(address:InterfaceAddress):boolean {
 if(address.internal || address.family!=='IPv4' || isIP(address.address)!==4)return false
 const octets=address.address.split('.').map(Number)
 if(octets[0]===0 || octets[0]===127 || octets[0]>=224 || (octets[0]===169 && octets[1]===254))return false
 if(isIP(address.netmask)===4){
  const bits=(value:string)=>value.split('.').reduce((result,part)=>(result*256+Number(part))>>>0,0)
  const hostMask=(~bits(address.netmask))>>>0
  if(hostMask>1 && ((hostMask+1)&hostMask)===0 && ((bits(address.address)&hostMask)>>>0)===hostMask)return false
 }
 return true
}

/** Only candidates from the explicitly selected interface may be advertised. */
export function receiverNetwork(name:string, interfaces:ReturnType<typeof os.networkInterfaces>):ReceiverNetwork|undefined {
 const addresses=interfaces[name] || []
 const ipv4=addresses.find(usableIPv4)
 const ipv6=addresses.find(address=>!address.internal && address.family==='IPv6' && isIP(address.address.split('%')[0])===6 && /^fe[89ab][0-9a-f]:/i.test(address.address))
 if(ipv4)return {host:ipv4.address,family:'IPv4',...(ipv6?{alternateHost:ipv6.address.split('%')[0]}:{})}
 if(ipv6)return {host:ipv6.address.split('%')[0],family:'IPv6'}
 return undefined
}

type NetworkSettings = {wireless?:boolean; wifiInterface?:string; ssid?:string; password?:string; channel?:number}
export type NetworkCheck = {ok:true; interface:string; families:string[]; receiver?:ReceiverNetwork} | {ok:false; code:string; message:string}

/** Validate the exact interface selected by the UI; never silently fall back to en0. */
export function validateWirelessNetwork(settings:NetworkSettings, interfaces:ReturnType<typeof os.networkInterfaces>):NetworkCheck {
 if (!settings.wireless) return {ok:true, interface:settings.wifiInterface || '', families:[]}
 const name=settings.wifiInterface
 if (typeof name!=='string' || !/^[A-Za-z][A-Za-z0-9._-]{0,31}$/.test(name)) return {ok:false,code:'INVALID_INTERFACE',message:'请选择可用的网络接口'}
 const addresses=(interfaces[name] || []).filter(address=>!address.internal)
 if (!addresses.length) return {ok:false,code:'INTERFACE_UNAVAILABLE',message:'所选网络接口已断开或不可用，请重新读取网络'}
 const receiver=receiverNetwork(name,interfaces)
 if(!receiver)return {ok:false,code:'NO_USABLE_ADDRESS',message:'所选网络接口没有可用的IPv4或链路本地IPv6地址，请检查网络连接'}
 // Preserve exact SSID/password bytes, including legitimate whitespace and colons.
 if (typeof settings.ssid!=='string' || !settings.ssid.length || Buffer.byteLength(settings.ssid,'utf8')>32 || settings.ssid.includes('\0')) return {ok:false,code:'INVALID_SSID',message:'请填写有效的Wi-Fi名称（SSID不能超过32字节）'}
 if (typeof settings.password!=='string' || settings.password.includes('\0')) return {ok:false,code:'INVALID_PASSWORD',message:'请填写有效的Wi-Fi密码'}
 if (!Number.isInteger(settings.channel) || settings.channel!<1 || settings.channel!>196) return {ok:false,code:'INVALID_CHANNEL',message:'请填写iPhone所连Wi-Fi的实际信道'}
 return {ok:true,interface:name,families:[...new Set(addresses.map(address=>address.family))],receiver}
}
