import AppKit

/// One block in the compact menu bar look.
/// `widest` is the widest value the block can ever show: it fixes the block's width,
/// so blocks never shift when a number gains a digit.
enum BarItem: Equatable {
    case labeled(String, String, widest: String)   // tiny label on top, value below
    case pair(String, String, widest: String)      // two values stacked, e.g. ↓ and ↑
}

/// Draws the compact look: small two-line blocks side by side, in one image.
enum StatusRenderer {
    private static let spacing: CGFloat = 6
    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    private static let pairFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    static func image(for items: [BarItem]) -> NSImage {
        let height = NSStatusBar.system.thickness
        let widths = items.map(width)
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, items.count - 1))

        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (item, width) in zip(items, widths) {
                draw(item, in: NSRect(x: x, y: 0, width: width, height: height))
                x += width + spacing
            }
            return true
        }
        image.isTemplate = true   // macOS tints it: white on a dark menu bar, black on a light one
        return image
    }

    private static func width(_ item: BarItem) -> CGFloat {
        switch item {
        case let .labeled(label, _, widest):
            ceil(max(text(label, labelFont).size().width, text(widest, valueFont).size().width))
        case let .pair(_, _, widest):
            ceil(text(widest, pairFont).size().width)
        }
    }

    private static func draw(_ item: BarItem, in box: NSRect) {
        switch item {
        case let .labeled(label, value, _):
            stack(top: text(label, labelFont), bottom: text(value, valueFont), in: box, align: .center)
        case let .pair(top, bottom, _):
            stack(top: text(top, pairFont), bottom: text(bottom, pairFont), in: box, align: .right)
        }
    }

    /// Two lines, centered vertically as a pair. The lines overlap by a point or two
    /// because a font's line box has more air above and below than the letters need.
    private static func stack(top: NSAttributedString, bottom: NSAttributedString, in box: NSRect, align: NSTextAlignment) {
        let topSize = top.size()
        let bottomSize = bottom.size()
        let overlap: CGFloat = 2.5
        let y = box.minY + (box.height - (topSize.height + bottomSize.height - overlap)) / 2
        bottom.draw(at: NSPoint(x: x(for: bottomSize.width, in: box, align: align), y: y))
        top.draw(at: NSPoint(x: x(for: topSize.width, in: box, align: align), y: y + bottomSize.height - overlap))
    }

    private static func x(for width: CGFloat, in box: NSRect, align: NSTextAlignment) -> CGFloat {
        align == .right ? box.maxX - width : box.minX + (box.width - width) / 2
    }

    private static func text(_ string: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black])
    }
}
