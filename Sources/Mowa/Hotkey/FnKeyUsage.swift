import Foundation

/// System Settings → Keyboard → "Press 🌐 key to". With Fn as the dictation key every press would
/// also open the emoji picker or switch the input source, so Mowa sets it to "Do Nothing" (Drew
/// 2026-10-21: no hint telling the user to do it) and puts the user's own choice back once
/// another dictation key is picked.
enum FnKeyUsage {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    /// 0 = Do Nothing (1 input source, 2 emoji, 3 dictation).
    private static let doNothing = 0
    /// What the user had before Mowa changed it; -1 = the key wasn't set (macOS default).
    private static let savedKey = "fnUsageBeforeMowa"

    static func apply(fnIsDictationKey: Bool) {
        let current = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
        let defaults = UserDefaults.standard
        if fnIsDictationKey {
            guard current != doNothing else { return }
            if defaults.object(forKey: savedKey) == nil { defaults.set(current ?? -1, forKey: savedKey) }
            write(doNothing)
            Log.info("Fn key: \"Press 🌐 key to\" set to Do Nothing (was \(current.map(String.init) ?? "default"))")
        } else if let saved = defaults.object(forKey: savedKey) as? Int {
            defaults.removeObject(forKey: savedKey)
            guard current == doNothing else { return }   // the user changed it since: leave theirs
            write(saved >= 0 ? saved : nil)
            Log.info("Fn key: \"Press 🌐 key to\" restored")
        }
    }

    private static func write(_ value: Int?) {
        CFPreferencesSetValue(key, value.map { $0 as CFNumber }, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
