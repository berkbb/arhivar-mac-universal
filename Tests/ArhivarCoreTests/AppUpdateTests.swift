import Foundation
import Testing
@testable import ArhivarCore

private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]) -> Data {
    let assetObjects = assets.map {
        ["name": $0, "browser_download_url": "https://github.com/berkbb/arhivar-mac-universal/releases/download/\(tag)/\($0)"]
    }
    let object: [String: Any] = [
        "tag_name": tag, "html_url": "https://github.com/berkbb/arhivar-mac-universal/releases/tag/\(tag)",
        "draft": draft, "prerelease": prerelease, "assets": assetObjects,
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

@Test func parsesLatestRelease() throws {
    let release = try AppUpdateChecker.parse(releaseJSON(tag: "v1.2.0", assets: ["Arhivar-1.2.0.zip", "Arhivar-1.2.0.dmg", "Arhivar-1.2.0.sha256"]))
    #expect(release.version == "1.2.0")
    #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v1.2.0"))
    // .dmg tercih edilir.
    #expect(release.downloadURL?.lastPathComponent == "Arhivar-1.2.0.dmg")

    let zipOnly = try AppUpdateChecker.parse(releaseJSON(tag: "1.3.0", assets: ["Arhivar-1.3.0.zip"]))
    #expect(zipOnly.downloadURL?.lastPathComponent == "Arhivar-1.3.0.zip")
    #expect(try AppUpdateChecker.parse(releaseJSON(tag: "v2.0.0", assets: [])).downloadURL == nil)
}

@Test func ignoresDraftsPrereleasesAndGarbage() {
    #expect(throws: AppUpdateChecker.CheckError.invalidData) {
        try AppUpdateChecker.parse(releaseJSON(tag: "v9.0.0", draft: true, assets: []))
    }
    #expect(throws: AppUpdateChecker.CheckError.invalidData) {
        try AppUpdateChecker.parse(releaseJSON(tag: "v9.0.0-beta", prerelease: true, assets: []))
    }
    #expect(throws: AppUpdateChecker.CheckError.invalidData) {
        try AppUpdateChecker.parse(Data("{\"message\":\"Not Found\"}".utf8))
    }
}

@Test func comparesAppVersions() {
    #expect(AppUpdateChecker.isNewer("1.0.1", than: "1.0.0"))
    #expect(AppUpdateChecker.isNewer("v1.0.10", than: "1.0.9"))
    #expect(AppUpdateChecker.isNewer("2.0", than: "1.9.9"))
    #expect(!AppUpdateChecker.isNewer("1.1", than: "1.1.0"))
    #expect(!AppUpdateChecker.isNewer("1.0.0", than: "1.0.1"))
    #expect(AppUpdateChecker.normalizedVersion("v1.2.3") == "1.2.3")
    #expect(AppUpdateChecker.latestReleaseURL(repository: "berkbb/arhivar-mac-universal")?.absoluteString
        == "https://api.github.com/repos/berkbb/arhivar-mac-universal/releases/latest")
}
