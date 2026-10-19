import AppKit
import Foundation

@MainActor
final class GitHubUpdater {
    static let shared = GitHubUpdater()

    private let owner = "SKR6582"
    private let repo = "live_caption"

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
            case draft
            case prerelease
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
    }

    func checkForUpdates(isUserInitiated: Bool) {
        Task {
            do {
                guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
                    return
                }

                var request = URLRequest(url: url)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                request.setValue("ReadIt-App", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    if isUserInitiated {
                        showNoUpdateAlert(message: "최신 릴리즈 정보를 가져올 수 없습니다.")
                    }
                    return
                }

                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                if release.draft || release.prerelease {
                    if isUserInitiated { showNoUpdateAlert(message: "현재 최신 버전을 사용 중입니다.") }
                    return
                }

                let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if isVersion(latestVersion, greaterThan: currentVersion) {
                    showUpdateAvailableAlert(release: release, newVersion: latestVersion)
                } else {
                    if isUserInitiated {
                        showNoUpdateAlert(message: "현재 최신 버전(v\(currentVersion))을 사용하고 있습니다.")
                    }
                }
            } catch {
                if isUserInitiated {
                    showNoUpdateAlert(message: "업데이트 확인 중 오류가 발생했습니다: \(error.localizedDescription)")
                }
            }
        }
    }

    private func isVersion(_ v1: String, greaterThan v2: String) -> Bool {
        v1.compare(v2, options: .numeric) == .orderedDescending
    }

    private func showUpdateAvailableAlert(release: GitHubRelease, newVersion: String) {
        let alert = NSAlert()
        alert.messageText = "새로운 버전이 출시되었습니다 (v\(newVersion))"
        let releaseNotes = (release.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? "\n\n[변경 사항]\n\(release.body!)"
            : ""
        alert.informativeText = "현재 버전: v\(currentVersion)\n최신 버전: v\(newVersion)\(releaseNotes)"
        alert.alertStyle = .informational

        let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") })

        alert.addButton(withTitle: dmgAsset != nil ? "DMG 다운로드" : "릴리즈 페이지 열기")
        alert.addButton(withTitle: "나중에")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let targetUrlString = dmgAsset?.browserDownloadUrl ?? release.htmlUrl
            if let targetUrl = URL(string: targetUrlString) {
                NSWorkspace.shared.open(targetUrl)
            }
        }
    }

    private func showNoUpdateAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "업데이트 확인"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
