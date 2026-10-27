import AppKit
import SwiftUI

/// The Unomage logo (Support/unomage-logo.png, rendered from Support/unomage-logo.svg at
/// 512 px; build.sh copies it into Mowa.app/Contents/Resources).
struct UnomageLogo: View {
    static let image: NSImage? = Bundle.main.image(forResource: "unomage-logo")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        }
    }
}
