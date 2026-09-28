import Foundation

/// Maps a raw track level onto the part of the range speech actually occupies.
///
/// Scaled in decibels, over the window the signal actually occupies. Measured across a recording
/// that transcribed fine, the mic sits at an RMS of 0.006 median and peaks at 0.05 — that is
/// −44 dB to −26 dB, a 20 dB window. Against the full −60…0 dB range it used to be drawn on, all
/// of speech landed in the middle third and no indicator visibly moved, whichever way it was
/// drawn. Clamping to the range that carries the signal is what makes any of them readable.
///
/// Shared by the record screen's meters and the floating recorder, so both move together.
enum AudioLevelScale {
    /// Below this the signal is indistinguishable from silence.
    static let floorDecibels: Double = -50

    /// Above this the indicator is simply "loud". Deliberately far below 0 dB: nothing in a
    /// recorded voice ever gets near full scale, and a ceiling it cannot reach is range spent on
    /// nothing. Genuine clipping is caught from the raw level instead, where it belongs.
    static let ceilingDecibels: Double = -20

    /// 0 at or below the floor, 1 at or above the ceiling.
    static func fraction(of level: Float) -> Double {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        let span = ceilingDecibels - floorDecibels
        return min(1, max(0, (decibels - floorDecibels) / span))
    }
}
