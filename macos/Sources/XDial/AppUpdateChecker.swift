import Combine
import Foundation

@MainActor
final class AppUpdateChecker: ObservableObject {
    @Published private(set) var isUpdateAvailable = false

    private var hasChecked = false
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/kafeifei/XDial/releases/latest"
    )!

    func checkIfNeeded() async {
        guard !hasChecked else { return }
        hasChecked = true

        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        do {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadRevalidatingCacheData
            request.setValue(
                "application/vnd.github+json",
                forHTTPHeaderField: "Accept"
            )
            request.setValue(
                "XDial/\(currentVersion)",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(
                for: request
            )
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                return
            }
            let release = try JSONDecoder().decode(
                LatestRelease.self,
                from: data
            )
            isUpdateAvailable = VersionUpdatePolicy.isNewer(
                latestTag: release.tagName,
                than: currentVersion
            )
        } catch {
            // 更新检查失败不能冒充产品错误；保持无圆点，下次启动再检查。
            appLog("update check unavailable: \(error.localizedDescription)")
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }
}
