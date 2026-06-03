import AppKit
import SwiftUI

struct CardDragSurface: NSViewRepresentable {
    let item: ClipboardItem
    let onClick: () -> Void
    let onDragStart: () -> Void
    let onSessionBegan: () -> Void
    let onDragEnd: (NSDragOperation) -> Void
    /// Renders the drag preview lazily at drag start (a 1:1 snapshot of the SwiftUI card).
    let makeDragImage: @MainActor () -> NSImage?

    func makeNSView(context: Context) -> CardDragView {
        let view = CardDragView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: CardDragView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: CardDragView) {
        view.item = item
        view.onClick = onClick
        view.onDragStart = onDragStart
        view.onSessionBegan = onSessionBegan
        view.onDragEnd = onDragEnd
        view.makeDragImage = makeDragImage
    }
}

final class CardDragView: NSView, NSDraggingSource {
    var item: ClipboardItem?
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onSessionBegan: (() -> Void)?
    var onDragEnd: ((NSDragOperation) -> Void)?
    var makeDragImage: (@MainActor () -> NSImage?)?

    private var mouseDownEvent: NSEvent?
    private var mouseDownPoint = NSPoint.zero
    private var draggingDidBegin = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        draggingDidBegin = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !draggingDidBegin, let mouseDownEvent, let item else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        guard hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) > 4 else {
            return
        }

        draggingDidBegin = true
        onDragStart?()
        // Prefer a 1:1 snapshot of the real SwiftUI card (matches what's on screen);
        // fall back to the lightweight drawn preview if rendering is unavailable.
        let preview = makeDragImage?() ?? previewImage(for: item, size: bounds.size)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardWriter(for: item))
        // Frame matches the image's own size so the system never stretches it.
        draggingItem.setDraggingFrame(NSRect(origin: .zero, size: preview.size), contents: preview)
        beginDraggingSession(with: [draggingItem], event: mouseDownEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            draggingDidBegin = false
        }
        guard !draggingDidBegin else { return }
        onClick?()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // beginDraggingSession returns immediately and the drag actually starts on the
        // next run-loop turn, when THIS fires — the documented, reliable hook to hide
        // the source panel (works on the first drag).
        onSessionBegan?()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Drop accepted by another app → bring that app to the front so the user can
        // type immediately (a cross-app drop inserts text but doesn't activate the app).
        if !operation.isEmpty {
            DropTargetActivator.activateApp(at: screenPoint)
        }
        onDragEnd?(operation)
        mouseDownEvent = nil
        draggingDidBegin = false
    }

    private func pasteboardWriter(for item: ClipboardItem) -> NSPasteboardWriting {
        if item.kind == .image,
           let url = item.imageFileURL,
           let image = ImageCache.image(at: url) {
            return image
        }
        if item.kind == .link, let url = URL(string: item.text) {
            return url as NSURL
        }
        return item.text as NSString
    }

    private func previewImage(for item: ClipboardItem, size: CGSize) -> NSImage {
        if item.kind == .image,
           let url = item.imageFileURL,
           let image = ImageCache.image(at: url) {
            return image
        }

        let previewSize = NSSize(width: max(160, min(size.width, 260)), height: 84)
        let image = NSImage(size: previewSize)
        image.lockFocus()
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: previewSize), xRadius: 14, yRadius: 14).fill()

        let title = item.displayTitle.isEmpty ? item.kind.title : item.displayTitle
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        title.draw(
            in: NSRect(x: 14, y: 18, width: previewSize.width - 28, height: previewSize.height - 30),
            withAttributes: attributes
        )
        image.unlockFocus()
        return image
    }
}
