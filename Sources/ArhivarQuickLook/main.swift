// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

@_silgen_name("NSExtensionMain")
func NSExtensionMain()

@main
enum QuickLookMain {
    static func main() {
        NSExtensionMain()
    }
}
