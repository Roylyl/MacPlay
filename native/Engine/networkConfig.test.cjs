const test=require('node:test'),assert=require('node:assert/strict')
const {validateWirelessNetwork,receiverNetwork}=require('../../build/engine/networkConfig')
const settings={wireless:true,wifiInterface:'en5',ssid:' Wi-Fi: Test ',password:' secret: value ',channel:149}
const addresses={en0:[{family:'IPv4',address:'192.0.2.1',internal:false}],en5:[{family:'IPv6',address:'fe80::1%en5',scopeid:5,internal:false},{family:'IPv4',address:'192.0.2.2',internal:false}]}
test('Ethernet selected by the UI is retained, with exact SSID/password characters',()=>{
 const original={...settings}
 assert.deepEqual(validateWirelessNetwork(settings,addresses),{ok:true,interface:'en5',families:['IPv6','IPv4'],receiver:{host:'192.0.2.2',family:'IPv4',alternateHost:'fe80::1'}})
 assert.deepEqual(settings,original)
})
test('an absent selected interface cannot silently switch to another interface',()=>{
 assert.equal(validateWirelessNetwork({...settings,wifiInterface:'en9'},addresses).code,'INTERFACE_UNAVAILABLE')
 assert.equal(validateWirelessNetwork({...settings,wifiInterface:''},addresses).code,'INVALID_INTERFACE')
})
test('IPv4-only interfaces work and global-only IPv6 cannot become the handoff address',()=>{
 assert.equal(validateWirelessNetwork({...settings,wifiInterface:'en0'},addresses).ok,true)
 assert.equal(validateWirelessNetwork(settings,{en5:[{family:'IPv6',address:'2001:db8::1',internal:false}]}).ok,false)
})
test('wired sessions do not require wireless credentials, while invalid wireless fields are rejected',()=>{
 assert.equal(validateWirelessNetwork({wireless:false},{}).ok,true)
 assert.equal(validateWirelessNetwork({...settings,ssid:'x'.repeat(33)},addresses).code,'INVALID_SSID')
 assert.equal(validateWirelessNetwork({...settings,channel:0},addresses).code,'INVALID_CHANNEL')
 assert.equal(validateWirelessNetwork({...settings,password:'x\0y'},addresses).code,'INVALID_PASSWORD')
})

test('only the selected interface contributes primary and alternate addresses',()=>{
 assert.deepEqual(receiverNetwork('en0',addresses),{host:'192.0.2.1',family:'IPv4'})
 assert.deepEqual(receiverNetwork('en5',{en5:addresses.en5.slice(0,1)}),{host:'fe80::1',family:'IPv6'})
 assert.equal(receiverNetwork('missing',addresses),undefined)
})
test('unusable IPv4 hosts never become primary, and the IPv6 zone is not sent to iPhone',()=>{
 for(const host of ['0.0.0.0','127.0.0.1','169.254.1.2','224.0.0.1','255.255.255.255','192.0.2.255']) {
  assert.deepEqual(receiverNetwork('en5',{en5:[{family:'IPv4',address:host,netmask:'255.255.255.0',internal:false},addresses.en5[0]]}),{host:'fe80::1',family:'IPv6'})
 }
 assert.equal(receiverNetwork('en5',{en5:[{family:'IPv4',address:'192.0.2.2',internal:true}]}),undefined)
})
