import Carbon
import Foundation
import MowaCore

/// The language of the keyboard layout currently selected in the menu bar (Polish Pro → pl,
/// Russian – PC → ru, ABC / U.S. → en). nil when the layout's language isn't one of Mowa's 8.
/// Text Input Sources must be read on the main thread (see TextInserter.postShortcut).
@MainActor
enum KeyboardLanguage {
    static func current() -> DictationLanguage? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
        guard let first = languages.first else { return nil }
        // "pt-BR" → "pt", "en-US" → "en".
        return DictationLanguage(whisperCode: String(first.prefix { $0.isLetter }))
    }

    /// Languages of every keyboard layout / input method the user added in System Settings →
    /// Keyboard → Input Sources (only Mowa's 8). Used to preselect languages in onboarding.
    static func enabled() -> Set<DictationLanguage> {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        var found = Set<DictationLanguage>()
        for source in list {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { continue }
            let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
            if let first = languages.first, let lang = DictationLanguage(whisperCode: String(first.prefix { $0.isLetter })) {
                found.insert(lang)
            }
        }
        return found
    }
}
