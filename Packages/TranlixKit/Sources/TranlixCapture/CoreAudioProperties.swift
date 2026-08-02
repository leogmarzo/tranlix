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
