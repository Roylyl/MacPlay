import CoreAudio
import Foundation

/// Observe both device topology and the system defaults. A default-route change
/// must be delivered even when the list of available device UIDs is unchanged.
final class AudioHardwareMonitor {
    private struct Observation {
        var address: AudioObjectPropertyAddress
        let listener: AudioObjectPropertyListenerBlock
    }
    private var observations: [Observation] = []
    private var pending: DispatchWorkItem?
    private var changedInput = false
    private var changedOutput = false
    private let onChange: (Bool, Bool) -> Void

    init(onChange: @escaping (Bool, Bool) -> Void) {
        self.onChange = onChange
        observe(kAudioHardwarePropertyDevices, input: true, output: true)
        observe(kAudioHardwarePropertyDefaultInputDevice, input: true, output: false)
        observe(kAudioHardwarePropertyDefaultOutputDevice, input: false, output: true)
    }

    private func observe(_ selector: AudioObjectPropertySelector, input: Bool, output: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.schedule(input: input, output: output)
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            observations.append(Observation(address: address, listener: listener))
        }
    }

    private func schedule(input: Bool, output: Bool) {
        changedInput = changedInput || input
        changedOutput = changedOutput || output
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let input = self.changedInput, output = self.changedOutput
            self.changedInput = false
            self.changedOutput = false
            self.pending = nil
            self.onChange(input, output)
        }
        pending = work
        // USB/Bluetooth removal often arrives as several CoreAudio callbacks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    deinit {
        pending?.cancel()
        for var observation in observations {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &observation.address, .main, observation.listener)
        }
    }
}
