import AppKit
import SwiftUI

/// App icons for the lists, drawn once at list size and kept. An app's icon holds images up to
/// 1024 px, and scaling it down on every refresh was most of a page's drawing time.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]   // used from the main thread only (views)

    static func small(app: NSRunningApplication?) -> NSImage? {
        guard let app else { return nil }
        let key = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid \(app.processIdentifier)"
        if let cached = cache[key] { return cached }
        guard let icon = app.icon else { return nil }
        return store(icon, key)
    }

    static func small(bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return store(NSWorkspace.shared.icon(forFile: url.path), bundleID)
    }

    /// A 22 pt bitmap at 2× for Retina screens.
    private static func store(_ icon: NSImage, _ key: String) -> NSImage {
        let side = 22
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side * 2, pixelsHigh: side * 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: rep.size)
        small.addRepresentation(rep)
        cache[key] = small
        return small
    }
}

/// An app's icon in a list row; a gear for background processes that have none.
struct AppIconView: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
        } else {
            Image(systemName: "gearshape.2").foregroundStyle(.secondary).frame(width: 22, height: 22)
        }
    }
}
