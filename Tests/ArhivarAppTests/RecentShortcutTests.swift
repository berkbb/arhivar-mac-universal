import AppKit
import Foundation
import Testing
@testable import Arhivar

/// Son arşivler için kısayollar: satırın üzerindeyken ⌫ ile kaldırma ve ⇧⌘⌫ ile tümünü temizleme; Ayarlar'dan değişir.
@MainActor @Suite struct RecentShortcutTests {
    @Test func defaultsAreDeleteAndShiftCommandDelete() {
        #expect(ShortcutAction.removeRecent.defaultShortcut.displayString == "⌫")
        #expect(ShortcutAction.clearRecents.defaultShortcut.displayString == "⇧⌘⌫")
        #expect(ShortcutAction.removeRecent.titleKey == .shortcutActionRemoveRecent)
        #expect(ShortcutAction.clearRecents.titleKey == .menuClearRecents)
    }

    /// Yalnızca satır üzerindeyken çalışan eylem niteleyicisiz tuş alabilir; menü kısayolları yazarken tetiklenmesin.
    @Test func onlyRemoveRecentAllowsABareKey() {
        #expect(ShortcutAction.allCases.filter(\.allowsBareKey) == [.removeRecent])
    }

    /// Varsayılan kısayollar birbiriyle çakışmaz.
    @Test func defaultShortcutsAreUnique() {
        let defaults = ShortcutAction.allCases.map(\.defaultShortcut)
        #expect(Set(defaults.map(\.displayString)).count == defaults.count)
    }

    @Test func matchingRequiresTheExactKeyAndModifiers() {
        let remove = ShortcutAction.removeRecent.defaultShortcut
        #expect(remove.matches(keyCode: 51, characters: "\u{7f}", modifiers: []))
        #expect(!remove.matches(keyCode: 51, characters: "\u{7f}", modifiers: .command))
        #expect(!remove.matches(keyCode: 117, characters: nil, modifiers: []))

        let clear = ShortcutAction.clearRecents.defaultShortcut
        #expect(clear.matches(keyCode: 51, characters: "\u{7f}", modifiers: [.command, .shift]))
        #expect(!clear.matches(keyCode: 51, characters: "\u{7f}", modifiers: .command))

        let letter = KeyboardShortcutData(key: "K", command: false)
        #expect(letter.matches(keyCode: 40, characters: "k", modifiers: []))
        #expect(letter.matches(keyCode: 40, characters: "K", modifiers: .capsLock))
        #expect(!letter.matches(keyCode: 40, characters: "k", modifiers: .option))
    }

    @Test func customShortcutIsSavedAndReset() throws {
        let suiteName = "RecentShortcutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, bundle: .main)
        #expect(settings.isDefaultShortcut(for: .removeRecent))

        let custom = KeyboardShortcutData(key: "X", command: false)
        settings.setShortcut(custom, for: .removeRecent)
        #expect(AppSettings(defaults: defaults, bundle: .main).shortcut(for: .removeRecent) == custom)
        settings.resetShortcut(for: .removeRecent)
        #expect(settings.shortcut(for: .removeRecent) == ShortcutAction.removeRecent.defaultShortcut)
    }

    /// Pencereye ait olmayan (ya da metin düzenlenen pencereye gelen) tuş olayı kaldırma yapmaz.
    @Test func keyWithoutAWindowIsIgnored() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51
        ))
        #expect(!RecentRemovalKey.accepts(event))
    }
}
