import Foundation

/// Kind of app the text is going into. Lets the cleanup model match tone and
/// formatting (e.g. no trailing period in chat, exact casing in terminals).
public enum AppContextStyle: String, Codable, Sendable, CaseIterable {
    case email
    case chat
    case code
    case document
    case general

    public static func classify(bundleID: String?, windowTitle: String? = nil) -> AppContextStyle {
        let id = (bundleID ?? "").lowercased()
        let title = (windowTitle ?? "").lowercased()

        if emailApps.contains(where: { id.hasPrefix($0) }) { return .email }
        if chatApps.contains(where: { id.hasPrefix($0) }) { return .chat }
        if codeApps.contains(where: { id.hasPrefix($0) }) { return .code }
        if documentApps.contains(where: { id.hasPrefix($0) }) { return .document }

        if browsers.contains(where: { id.hasPrefix($0) }) && !title.isEmpty {
            if ["gmail", "outlook", "proton mail", "fastmail", "yahoo mail", "poczta", "почта"].contains(where: { title.contains($0) }) {
                return .email
            }
            if ["slack", "discord", "whatsapp", "telegram", "messenger", "teams", "chatgpt", "claude"].contains(where: { title.contains($0) }) {
                return .chat
            }
            if ["github", "gitlab", "codesandbox", "stackblitz", "replit"].contains(where: { title.contains($0) }) {
                return .code
            }
            if ["google docs", "notion", "confluence", "dokumenty google"].contains(where: { title.contains($0) }) {
                return .document
            }
        }
        return .general
    }

    static let emailApps = [
        "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.readdle.spark",
        "it.bloop.airmail", "com.superhuman", "com.mimestream", "ch.protonmail", "com.canarymail",
    ]
    static let chatApps = [
        "com.apple.mobilesms", "com.apple.ichat", "com.tinyspeck.slackmacgap", "com.hnc.discord",
        "net.whatsapp", "desktop.whatsapp", "ru.keepcoder.telegram", "org.telegram", "com.microsoft.teams",
        "com.facebook.archon", "com.facebook.messenger", "us.zoom.xos", "org.whispersystems.signal",
        "com.viber", "com.anthropic.claudefordesktop", "com.openai.chat",
    ]
    static let codeApps = [
        "com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", "dev.zed.zed", "com.sublimetext", "com.panic.nova",
        "com.jetbrains", "com.google.android.studio", "com.apple.terminal", "com.googlecode.iterm2",
        "dev.warp.warp", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty",
    ]
    static let documentApps = [
        "com.apple.iwork.pages", "com.microsoft.word", "com.apple.notes", "md.obsidian",
        "notion.id", "com.notion", "com.apple.textedit", "net.shinyfrog.bear", "com.ulyssesapp",
        "com.literatureandlatte.scrivener", "com.craft", "com.apple.reminders",
    ]
    static let browsers = [
        "com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.browser", "com.brave.browser", "com.operasoftware", "com.vivaldi",
        "app.zen-browser", "com.kagi.kagimacos",
    ]

    /// Extra instruction for the cleanup prompt.
    public var promptInstruction: String? {
        switch self {
        case .email:
            return "The text goes into an email. Use complete sentences. Put a spoken greeting on its own line followed by a comma (\"Hi Anna,\"), start the body on the next line, and put a spoken sign-off on its own line before the name (\"Best regards,\" ⏎ \"Drew\")."
        case .chat:
            return "The text is a chat message. Keep it as short as it was spoken."
        case .code:
            return "The text goes into a code editor or terminal. Keep technical terms, file names, identifiers, commands and their casing exactly as spoken. Do not add a final period to a single-line command."
        case .document:
            return "The text goes into a document. Use clear paragraphs."
        case .general:
            return nil
        }
    }
}
