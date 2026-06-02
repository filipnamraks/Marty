import Foundation
import CoreText

/// Registers the bundled .ttf files with CoreText at launch so SwiftUI's
/// Font.custom(_:) can resolve them by PostScript name.
///
/// We register programmatically rather than relying on ATSApplicationFontsPath
/// because the project's synchronized file group copies the Fonts/ contents flat
/// into Resources/ (no Fonts/ subdirectory survives), which the Info.plist key
/// can't point at. Scanning the bundle for .ttf resources is layout-independent.
enum FontRegistrar {
    static func registerBundledFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
        guard !urls.isEmpty else { return }

        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already-registered is benign (e.g. re-entrant launches in previews).
                // Anything else we surface to the console but don't treat as fatal.
                if let err = error?.takeRetainedValue() {
                    let code = CFErrorGetCode(err)
                    let alreadyRegistered = 105 // kCTFontManagerErrorAlreadyRegistered
                    if code != alreadyRegistered {
                        NSLog("FontRegistrar: failed to register \(url.lastPathComponent): \(err)")
                    }
                }
            }
        }
    }
}
