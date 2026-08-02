import AVFoundation
import Foundation

extension AVAudioConverter {
    /// Converts exactly one input buffer, resampling and downmixing in a single pass.
    ///
    /// `convert(to:error:withInputFrom:)` calls its block synchronously and is finished with
    /// it before returning, so nothing here actually escapes onto another thread. The
    /// compiler cannot prove that — the block is typed `@Sendable` — so the opt-out is
    /// explicit and kept in one place rather than repeated in every capture backend.
    ///
    /// Returns false when the converter produced nothing, which happens routinely while the
    /// input is silent.
    func convertOnce(from input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) -> Bool {
        nonisolated(unsafe) let source = input
        nonisolated(unsafe) var consumed = false

        output.frameLength = output.frameCapacity
        var error: NSError?
        let status = convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }

        return status != .error && output.frameLength > 0
    }
}
