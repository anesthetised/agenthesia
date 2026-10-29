public import Foundation

/// How long ago a session started, as shown on the trailing edge of a sidebar row (ADR-0039).
public enum RelativeTime {
    /// `now`, `5m`, `3h`, `2d`, `3w`; from four weeks a short date such as `12 Oct`.
    public static func short(
        from date: Date,
        to now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        case ..<2_419_200: return "\(seconds / 604_800)w"
        default:
            return date.formatted(
                Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated)
            )
        }
    }
}
