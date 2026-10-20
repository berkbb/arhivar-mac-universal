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
