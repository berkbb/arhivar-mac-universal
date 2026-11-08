// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Arhivar

/// Yeniden kayıt yalnızca derleme değişince ve yalnızca gerçek Arhivar paketinde yapılır.
@Test func reRegistersOnlyWhenTheBuildChanges() {
    #expect(FinderIconRefresh.needsRegistration(lastBuild: nil, currentBuild: "23"))
    #expect(FinderIconRefresh.needsRegistration(lastBuild: "22", currentBuild: "23"))
    #expect(FinderIconRefresh.needsRegistration(lastBuild: "24", currentBuild: "23"), "geri dönüşte de kayıt yenilenir")
    #expect(!FinderIconRefresh.needsRegistration(lastBuild: "23", currentBuild: "23"))
}

@Test @MainActor func testBundleIsNeverRegistered() throws {
    let suite = "FinderIconRefreshTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // Bundle.main testlerde xctest'tir: kimlik Arhivar değil, hiçbir şey kaydedilmez ve derleme yazılmaz.
    FinderIconRefresh.registerIfBuildChanged(bundle: .main, defaults: defaults)
    #expect(defaults.string(forKey: FinderIconRefresh.registeredBuildKey) == nil)
}

@Test func cacheClearCommandTargetsOnlyTheIconStore() {
    #expect(FinderIconRefresh.cacheClearCommand.contains("/Library/Caches/com.apple.iconservices.store"))
    #expect(FinderIconRefresh.cacheClearCommand.hasPrefix("sudo rm -rf /Library/Caches/com.apple.iconservices.store"))
    #expect(FinderIconRefresh.cacheClearCommand.contains("killall Finder Dock"))
}
