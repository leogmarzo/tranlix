import CoreAudio
import Foundation

/// Thin wrappers over `AudioObjectGetPropertyData`.
///
/// The Core Audio property API is the same four-line dance every time — build an address,
/// declare a size, pass a pointer, check a status — and getting one of those lines wrong
/// fails at runtime rather than at compile time. Doing it once here keeps the tap code
/// readable.
enum CoreAudioProperties {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func value<T>(
        _ selector: AudioObjectPropertySelector,
        on object: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default initial: T,
        describedAs description: String
    ) throws -> T {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw CaptureError.tapFailed(description, status: status)
        }
        return value
    }

    static func defaultOutputDeviceID() throws -> AudioObjectID {
        try value(
            kAudioHardwarePropertyDefaultOutputDevice,
            on: AudioObjectID(kAudioObjectSystemObject),
            default: AudioObjectID(kAudioObjectUnknown),
            describedAs: "no se pudo leer el dispositivo de salida por omisión"
        )
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let uid else {
            throw CaptureError.tapFailed("no se pudo leer el UID del dispositivo", status: status)
        }
        return uid as String
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return "dispositivo desconocido" }
        return name as String
    }

    /// The rate a device is currently running at, or zero when it cannot be read.
    static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        let rate = try? value(
            kAudioDevicePropertyNominalSampleRate,
            on: device,
            default: Float64(0),
            describedAs: "no se pudo leer la frecuencia del dispositivo"
        )
        return rate ?? 0
    }

    /// The tap's format as the aggregate device actually delivers it.
    ///
    /// A tap reports the format it was created for, but an aggregate runs on the clock of its
    /// main sub-device and hands the tap's stream over at *that* rate. The two disagree
    /// whenever the output device changes rate underneath: AirPods drop to 24 kHz the moment
    /// their microphone is engaged — which recording a meeting always does — while the tap goes
    /// on advertising 48 kHz. Resampling from the advertised rate then uses the wrong ratio,
    /// and nothing looks wrong until someone plays the recording back at double speed.
    ///
    /// A device rate of zero means the property could not be read, and the tap's own rate is
    /// then the best answer available.
    static func clocked(
        _ tap: AudioStreamBasicDescription,
        at deviceSampleRate: Double
    ) -> AudioStreamBasicDescription {
        guard deviceSampleRate > 0, deviceSampleRate != tap.mSampleRate else { return tap }
        var clocked = tap
        clocked.mSampleRate = deviceSampleRate
        return clocked
    }

    /// How many buffers a device presents on its input scope.
    ///
    /// An aggregate device hands its IOProc the input streams of its sub-devices first and the
    /// tap's stream after them, so this count over the sub-device is exactly the index the
    /// tap's buffer starts at. Built-in speakers have no inputs and report zero, which is why
    /// reading buffer zero appears to work right up until the user puts on a headset or joins
    /// a call through a virtual audio device.
    ///
    /// Returns zero when the device reports nothing, which is the same answer as having no
    /// input streams at all.
    static func inputBufferCount(_ device: AudioObjectID) -> Int {
        var address = address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        ).count
    }

    /// The format the tap actually delivers.
    ///
    /// Always read rather than assumed: it follows the output device, so it is 48 kHz stereo
    /// on a laptop speaker and something else entirely on an interface.
    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try value(
            kAudioTapPropertyFormat,
            on: tap,
            default: AudioStreamBasicDescription(),
            describedAs: "no se pudo leer el formato del tap"
        )
    }
}
