const {test} = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const engine = path.resolve(__dirname, '../../build/engine')

// Keep the real media wrapper and CpStack together; only the native transport is
// replaced. A second stack must not steal the first one's clock/microphone callback.
function fixture(ids = [1, 2], permission = () => 1) {
  const callbacks = [], microphones = [], closed = [], inputRoutes = [], outputRoutes = []
  const routes = {input: undefined, output: undefined}
  const addon = {
    openAudioReceiver(...args) {
      const id = ids.shift()
      callbacks.push(sample => args.at(-1)(id, sample))
      return {streamId: id, dataPort: 6000 + id, controlPort: 7000 + id}
    },
    closeAudioReceiver(id) { closed.push(id) },
    setAudioReceiverVolume() {},
    setAudioReceiverActive() {},
    microphonePermission: permission,
    setAudioReceiverDevice(id, device) { outputRoutes.push([id, device]); return true },
    setMicUplinkDevice(id, device) { inputRoutes.push([id, device]); return true },
    openMicUplink(...args) { microphones.push(args); return 100 + microphones.length },
    closeMicUplink() {}
  }
  function load(file, dependencies) {
    const module = {exports: {}}
    vm.runInNewContext(fs.readFileSync(path.join(engine, file), 'utf8'), {
      module, exports: module.exports, Buffer, __dirname: engine,
      process: {env: {MACPLAY_RESOURCES: '/fixture'}, arch: 'arm64', hrtime: process.hrtime},
      clearInterval, setImmediate,
      console: {log() {}, warn() {}},
      require(id) {
        if (id in dependencies) return dependencies[id]
        if (id.startsWith('node:')) return require(id)
        return {}
      }
    })
    return module.exports
  }
  const media = load('media.js', {
    'livi-gst-video': addon,
    'node:fs': {...fs, existsSync: () => true},
    './microphonePermission': require(path.join(engine, 'microphonePermission.js'))
  })
  const {CpStack} = load('protocol/cpStack.js', {
    '../media': media,
    '../ProjectionEnums': require(path.join(engine, 'ProjectionEnums.js')),
    './crypto': require(path.join(engine, 'protocol/crypto.js'))
  })
  async function connect(peerHost, microphone = false) {
    const stack = new CpStack({mfi: {}, audioInputDevice: () => routes.input, audioDevice: () => routes.output})
    const session = {pairVerify: {sharedSecret: Buffer.alloc(32)}, peerHost, audioMeta: []}
    stack._liveSession = session
    let active = 0
    stack.on('audio-active', (_profile, value) => { if (value) active++ })
    await stack._setupAudio({
      streamConnectionID: 42, audioType: microphone ? 'speechRecognition' : 'media',
      audioFormat: microphone ? 0x10000000 : 0x800000,
      dataPort: microphone ? 9000 : 0
    }, session, 100)
    return {stack, session, meta: session.audioMeta[0], get active() { return active }}
  }
  return {connect, callbacks, microphones, closed, inputRoutes, outputRoutes, routes}
}

const turn = () => new Promise(resolve => setImmediate(resolve))

test('a new control stack cannot steal the existing media clock or microphone', async () => {
  const f = fixture()
  const speech = await f.connect('192.0.2.1', true)
  const music = await f.connect('192.0.2.2')
  f.callbacks[0](1200)
  f.callbacks[1](2400)
  await turn()
  assert.equal(speech.meta.origin.firstSample, 1200)
  assert.equal(music.meta.origin.firstSample, 2400)
  assert.equal(speech.active, 1)
  assert.equal(music.active, 1)
  assert.equal(f.microphones.length, 1)
  assert.equal(f.microphones[0][8], '192.0.2.1')
  assert.equal(speech.meta.micStreamId, 101)
  assert.equal(music.meta.micStreamId, null)
})

test('a queued callback from a closed receiver cannot reach a reused native ID', async () => {
  const f = fixture([1, 1])
  const previous = await f.connect('192.0.2.1', true)
  previous.stack._closeAudio(previous.meta)
  const next = await f.connect('192.0.2.2', true)
  f.callbacks[0](1200)
  await turn()
  assert.equal(previous.meta.origin, null)
  assert.equal(next.meta.origin, null)
  assert.equal(f.microphones.length, 0)
  f.callbacks[1](2400)
  await turn()
  assert.equal(next.meta.origin.firstSample, 2400)
  assert.equal(next.active, 1)
  assert.equal(f.microphones.length, 1)
  assert.equal(f.microphones[0][8], '192.0.2.2')
  assert.deepEqual(f.closed, [1])
})

test('stop or a retired session ignores a first packet before socket cleanup finishes', async () => {
  const f = fixture()
  const stopped = await f.connect('192.0.2.1', true)
  const retired = await f.connect('192.0.2.2', true)
  stopped.stack.stop()
  retired.session.ended = true
  f.callbacks[0](1200)
  f.callbacks[1](2400)
  await turn()
  assert.equal(stopped.meta.origin, null)
  assert.equal(retired.meta.origin, null)
  assert.equal(stopped.active, 0)
  assert.equal(retired.active, 0)
  assert.equal(f.microphones.length, 0)
})


test('live microphone routing keeps the encrypted sender and its media clock', async () => {
  const f = fixture()
  const speech = await f.connect('192.0.2.1', true)
  f.callbacks[0](1200)
  await turn()
  const origin = speech.meta.origin
  f.routes.input = 'USB mic'
  f.routes.output = 'USB speaker'
  speech.stack.setAudioDevices(true, true)
  await turn()
  assert.equal(f.microphones.length, 1, 'must not recreate a sender with the same encryption key')
  assert.deepEqual(f.inputRoutes, [[101, 'USB mic']])
  assert.deepEqual(f.outputRoutes, [[1, 'USB speaker']])
  assert.equal(speech.meta.origin, origin)
  f.routes.input = undefined
  speech.stack.setAudioDevices(true, false)
  assert.deepEqual(f.inputRoutes.at(-1), [101, undefined])
  assert.equal(f.outputRoutes.length, 1)
  speech.stack.stop()
  speech.stack.setAudioDevices(true, true)
  assert.equal(f.inputRoutes.length, 2)
})

test('device changes retire a pending microphone permission request', async () => {
  let allowed = false
  const f = fixture([1], () => allowed ? 1 : 2)
  const speech = await f.connect('192.0.2.1', true)
  f.routes.input = 'removed mic'
  f.callbacks[0](1200)
  await turn()
  f.routes.input = undefined
  speech.stack.setAudioDevices(true, false)
  allowed = true
  await new Promise(resolve => setTimeout(resolve, 240))
  assert.equal(f.microphones.length, 1)
  assert.equal(f.microphones[0][9], undefined, 'only the current device may start after permission is granted')
})
