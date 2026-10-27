import AppKit

/// Asks mowa.unomage.com whether a newer version exists. Besides model
/// downloads this is the only network request Mowa makes; it sends nothing
/// about the user (just the app version in the User-Agent).
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// "owner/repo" of the public source repository — MowaGitHubRepo in Info.plist.
    static var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "MowaGitHubRepo") as? String ?? "unomage/mowa"
    }

    /// Product website — MowaWebsite in Info.plist.
    static var website: URL {
        let s = Bundle.main.object(forInfoDictionaryKey: "MowaWebsite") as? String ?? "https://mowa.unomage.com"
        return URL(string: s) ?? URL(string: "https://mowa.unomage.com")!
    }

    private struct Latest: Decodable {
        let version: String?
        let url: String?
    }

    func check(silently: Bool) {
        let feed = Self.website.appendingPathComponent("api/latest.json")
        var request = URLRequest(url: feed, timeoutInterval: 15)
        request.setValue("Mowa/\(SystemInfo.appVersion)", forHTTPHeaderField: "User-Agent")

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw URLError(.badServerResponse) }
                let latest = try JSONDecoder().decode(Latest.self, from: data)
                // version == null: no public release yet — nothing to report.
                if let version = latest.version, Self.isNewer(version, than: SystemInfo.appVersion) {
                    let page = latest.url.flatMap(URL.init(string:)) ?? Self.website
                    self.offerUpdate(version: version, url: page)
                } else if !silently {
                    self.alert(L("Mowa is up to date."), LF("You have the latest version (%@).", SystemInfo.appVersion))
                }
            } catch {
                Log.error("Update check failed: \(error.localizedDescription)")
                if !silently { self.alert(L("Could not check for updates."), error.localizedDescription) }
            }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func offerUpdate(version: String, url: URL?) {
        NonModalAlert.show(
            title: LF("Mowa %@ is available", version),
            text: LF("You have %@. Download the new version from the Mowa website?", SystemInfo.appVersion),
            buttons: [(L("Download"), { if let url { NSWorkspace.shared.open(url) } }), (L("Later"), nil)])
    }

    private func alert(_ title: String, _ text: String) {
        NonModalAlert.show(title: title, text: text)
    }
}
