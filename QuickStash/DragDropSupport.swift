import AppKit
import Foundation

enum GlobalPointerEventKind: Int, Sendable {
    case moved = 0
    case dragged = 1
    case released = 2
}

enum StatusItemHoverPolicy {
    static func shouldPresentHover(pressedMouseButtons: Int) -> Bool {
        pressedMouseButtons == 0
    }
}

struct StatusItemHoverGate {
    private(set) var isSuppressedUntilPointerExit = false

    mutating func suppressUntilPointerExit() {
        isSuppressedUntilPointerExit = true
    }

    mutating func shouldPresentOnEnter(pressedMouseButtons: Int) -> Bool {
        if !StatusItemHoverPolicy.shouldPresentHover(pressedMouseButtons: pressedMouseButtons) {
            isSuppressedUntilPointerExit = true
            return false
        }
        return !isSuppressedUntilPointerExit
    }

    mutating func pointerExited() {
        isSuppressedUntilPointerExit = false
    }
}

enum ArmedDropTargetWatchdogPolicy {
    static func shouldHide(
        isDropTargetActive: Bool,
        isPresentationVisible: Bool,
        hasActiveFileDrag: Bool,
        pressedMouseButtons: Int
    ) -> Bool {
        isDropTargetActive
            && !isPresentationVisible
            && !hasActiveFileDrag
            && pressedMouseButtons & 1 == 0
    }
}

/// Coalesces high-frequency global pointer callbacks into at most one pending main-actor delivery.
final class GlobalPointerEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @MainActor @Sendable (GlobalPointerEventKind) -> Void
    private var pendingEvent: GlobalPointerEventKind?
    private var deliveryScheduled = false

    init(handler: @escaping @MainActor @Sendable (GlobalPointerEventKind) -> Void) {
        self.handler = handler
    }

    func submit(_ event: GlobalPointerEventKind) {
        let shouldSchedule = lock.withLock { () -> Bool in
            pendingEvent = event
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            self?.deliverPendingEvent()
        }
    }

    @MainActor
    private func deliverPendingEvent() {
        let event = lock.withLock { () -> GlobalPointerEventKind? in
            defer {
                pendingEvent = nil
                deliveryScheduled = false
            }
            return pendingEvent
        }
        if let event {
            handler(event)
        }
    }
}

enum DragPasteboardReader {
    /// Reads only URL strings from the drag pasteboard; it never coordinates or opens source files.
    static let defaultMaximumCount = ImportPolicy.default.maximumSourceItems + 1

    static func fileURLs(
        from pasteboard: NSPasteboard,
        maximumCount: Int = defaultMaximumCount
    ) -> [URL] {
        guard maximumCount > 0 else { return [] }
        return (pasteboard.pasteboardItems ?? []).prefix(maximumCount).compactMap { item in
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
    }
}

struct DragPresentationGate: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var isSuspended = false
    private(set) var isDropTargetArmed = false
    private(set) var isOverlayVisible = false

    var isActive: Bool {
        isDropTargetArmed || isOverlayVisible
    }

    mutating func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        generation &+= 1
        isSuspended = suspended
        if suspended {
            isDropTargetArmed = false
            isOverlayVisible = false
        }
    }

    @discardableResult
    mutating func armDropTarget() -> Bool {
        guard !isSuspended, !isDropTargetArmed, !isOverlayVisible else { return false }
        generation &+= 1
        isDropTargetArmed = true
        return true
    }

    @discardableResult
    mutating func showOverlay() -> Bool {
        guard !isSuspended, !isOverlayVisible else { return false }
        generation &+= 1
        isDropTargetArmed = true
        isOverlayVisible = true
        return true
    }

    @discardableResult
    mutating func hideOverlay() -> Bool {
        guard isActive else { return false }
        generation &+= 1
        isDropTargetArmed = false
        isOverlayVisible = false
        return true
    }

    mutating func makeHideToken() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidatePendingHide() {
        generation &+= 1
    }

    func acceptsHideToken(_ token: UInt64) -> Bool {
        !isSuspended && isActive && token == generation
    }
}
