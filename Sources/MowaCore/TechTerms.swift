import Foundation

/// English software terms people drop into Polish, Russian, French… dictations, which Parakeet writes
/// the way they sound (eval 2026-10-24: «mergerę kwesta» for "merge requesta", «OS-модулю» for
/// "auth модулю", "Solac" for Slack). They are added to the vocabulary-boosting terms (ParakeetEngine:
/// the CTC word spotter checks them against the audio, and SoundAlike.plausibleReplacement against
/// the heard word) — only when the dictation is already about software, so ordinary speech never
/// gets an English word put into it. `defaults write com.unomage.mowa techTerms -bool NO` turns it off.
public enum TechTerms {
    public static let terms: [String] = [
        "pull request", "merge request", "code review", "deploy", "staging", "production", "commit",
        "branch", "feature", "release", "rollback", "backend", "frontend", "auth", "token", "endpoint",
        "repository", "pipeline", "hotfix", "bugfix", "refactor", "framework", "database", "server",
        "Slack", "GitHub", "GitLab", "Bitbucket", "Jira", "Confluence", "Figma", "Notion", "Docker",
        "Kubernetes", "Xcode", "Swift", "Python", "JavaScript", "TypeScript", "React", "Next.js",
        "Magento", "WordPress", "Stripe", "Firebase", "localhost", "README", "JSON", "API", "PDF",
    ]

    /// Words that show a dictation is about software, in the 8 languages (stems, lowercase).
    static let cues: [String] = [
        "git", "deploy", "commit", "merge", "branch", "staging", "release", "api", "backend", "frontend",
        "pull request", "code", "kod", "код", "коммит", "деплой", "задеплой", "мерж", "ветк", "бранч",
        "релиз", "сервер", "server", "serwer", "модул", "repo ", "repozytor", "bug", "баг", "тестир", "app ", "apps",
        "aplikac", "приложени", "programm", "programa", "logiciel", "branche", "dépôt",
    ]

    public static func inTechContext(_ text: String) -> Bool {
        let lower = text.lowercased()
        return cues.contains { cue in
            // Stems match at a word start ("задеплоить", "commitów"), not inside other words.
            var searchRange = lower.startIndex..<lower.endIndex
            while let r = lower.range(of: cue, range: searchRange) {
                if r.lowerBound == lower.startIndex || !lower[lower.index(before: r.lowerBound)].isLetter { return true }
                searchRange = r.upperBound..<lower.endIndex
            }
            return false
        }
    }
}
