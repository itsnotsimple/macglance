import AppKit
import SwiftUI

/// The "Quit" button at the end of a process row, in a fixed-width slot. Rows that can't be
/// quit get an empty slot of the same width, so the numbers line up in one column.
struct QuitSlot: View {
    let app: NSRunningApplication?
    let canQuit: Bool
    let quit: (NSRunningApplication) -> Void

    var body: some View {
        Group {
            if canQuit, let app {
                Button(tr("Затвори", "Quit")) { quit(app) }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(width: 84, alignment: .trailing)
    }
}
