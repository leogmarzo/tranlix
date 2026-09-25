import Foundation

/// How long a session has been running, as text.
///
/// Lives here rather than in a view because two places show it at once — the record screen
/// and the menu bar item — and a session that appears to have two different durations
/// depending on where you look is worse than one that shows none.
public enum ElapsedTime {
    /// `HH:MM:SS`, every field padded.
    ///
    /// Hours are not capped and do not wrap: a nine-hour recording reads `09:00:00`, and a
    /// day-long one reads `26:00:00` rather than starting over. Padding is what keeps the
    /// menu bar item from resizing as the numbers grow.
    public static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        return String(
            format: "%02d:%02d:%02d",
            total / 3600,
            (total / 60) % 60,
            total % 60
        )
    }

    /// `MM:SS` under an hour, `H:MM` from then on.
    ///
    /// For the floating recorder, which is too narrow for eight characters. Seconds stop being
    /// shown once an hour has passed: at that point they are the digit that moves, not the one
    /// anyone reads, and keeping them would force a wider pill for the rest of the session.
    public static func compact(_ seconds: Int) -> String {
        let total = max(0, seconds)
        guard total >= 3600 else {
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 3600, (total / 60) % 60)
    }
}
