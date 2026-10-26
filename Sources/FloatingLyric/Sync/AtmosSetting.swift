import Foundation

/// Music's Dolby Atmos playback lags the position it reports (FIX_GUIDE F24).
enum AtmosSetting {
    /// Seconds the lyrics are held back for an Atmos song while Atmos is on.
    static let delay: TimeInterval = 1.0
    /// Off: the delay is not the same for every Atmos song (Out of Time needs none), so no song is shifted for now.
    static let autoCompensate = false
    private static let offValue = 30

    /// Raw `preferredDolbyAtmosPlaySetting` of Music; nil = not set.
    static func rawValue() -> Int? {
        let key = "preferredDolbyAtmosPlaySetting" as CFString
        let app = "com.apple.Music" as CFString
        CFPreferencesAppSynchronize(app)
        return (CFPreferencesCopyAppValue(key, app) as? NSNumber)?.intValue
    }

    /// 30 = off; anything else, including no value (Music's default is automatic), counts as on.
    static func isEnabled(rawValue: Int?) -> Bool { rawValue != offValue }
}
