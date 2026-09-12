import Foundation
import TranslixObjC

/// Runs a call that can raise an Objective-C exception, as a Swift error instead.
///
/// AVFAudio signals programmer error by raising, and `installTap(onBus:bufferSize:format:)`
/// is one of the calls that does. Swift has no `@try`, so such an exception unwinds past
/// every Swift frame into `std::terminate` and aborts the process — which on 2026-09-10 took
/// a fifty-seven-minute recording's healthy system track down with the microphone that had
/// actually failed.
///
/// The invariants around it come from Objective-C exceptions not unwinding Swift frames
/// correctly, which is undefined behaviour rather than a style preference:
///
/// - `body` wraps exactly one call, and does no cleanup of its own.
/// - Whatever object raised is discarded afterwards, never used again.
///
/// This is the floor, not the fix. The caller's own invariants are what should keep the call
/// from raising; this is what keeps a case nobody anticipated from costing a recording, and
/// it carries the exception's reason out to the manifest, where the next post-mortem can
/// read the one sentence a crash report never contains.
enum ObjCException {
    /// - Throws: `CaptureError.engineFailed`, carrying the exception's name and reason.
    static func catching(_ body: () -> Void) throws {
        do {
            try TLXObjCExceptionCatcher.catching(body)
        } catch {
            throw CaptureError.engineFailed(error.localizedDescription)
        }
    }
}
