import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

let quickStashHotKeySignature: OSType = 0x51535453 // QSTS

func quickStashOwnsHotKeyID(_ hotKeyID: EventHotKeyID) -> Bool {
    hotKeyID.signature == quickStashHotKeySignature
}

struct HotKeyDescriptor: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    static let defaultScreenshot = HotKeyDescriptor(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "A"
    )

    var displayName: String {
        var value = ""
        if carbonModifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}

@MainActor
final class ScreenshotPreferences: ObservableObject {
    static let shared = ScreenshotPreferences()

    private enum Key {
        static let hotKeyCode = "screenshotHotKeyCode"
        static let hotKeyModifiers = "screenshotHotKeyModifiers"
        static let hotKeyLabel = "screenshotHotKeyLabel"
    }

    private let defaults: UserDefaults
    @Published private(set) var hotKey: HotKeyDescriptor

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let code = defaults.object(forKey: Key.hotKeyCode) as? NSNumber,
           let modifiers = defaults.object(forKey: Key.hotKeyModifiers) as? NSNumber,
           let label = defaults.string(forKey: Key.hotKeyLabel),
           !label.isEmpty {
            hotKey = HotKeyDescriptor(
                keyCode: code.uint32Value,
                carbonModifiers: modifiers.uint32Value,
                keyLabel: label
            )
        } else {
            hotKey = .defaultScreenshot
        }
    }

    func persist(_ descriptor: HotKeyDescriptor) {
        hotKey = descriptor
        defaults.set(descriptor.keyCode, forKey: Key.hotKeyCode)
        defaults.set(descriptor.carbonModifiers, forKey: Key.hotKeyModifiers)
        defaults.set(descriptor.keyLabel, forKey: Key.hotKeyLabel)
    }
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    func install(handler: @escaping @MainActor @Sendable (UInt32) -> Void) -> OSStatus
    func register(_ descriptor: HotKeyDescriptor, id: UInt32) -> OSStatus
    func unregister(id: UInt32)
    func uninstall()
}

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering, @unchecked Sendable {
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: (@MainActor @Sendable (UInt32) -> Void)?

    func install(handler: @escaping @MainActor @Sendable (UInt32) -> Void) -> OSStatus {
        self.handler = handler
        guard eventHandler == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        return InstallEventHandler(
            GetApplicationEventTarget(),
            quickStashCarbonHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func register(_ descriptor: HotKeyDescriptor, id: UInt32) -> OSStatus {
        guard hotKeys[id] == nil else { return OSStatus(eventHotKeyExistsErr) }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.carbonModifiers,
            EventHotKeyID(signature: quickStashHotKeySignature, id: id),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &reference
        )
        if status == noErr, let reference {
            hotKeys[id] = reference
        }
        return status
    }

    func unregister(id: UInt32) {
        guard let reference = hotKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(reference)
    }

    func uninstall() {
        for reference in hotKeys.values {
            UnregisterEventHotKey(reference)
        }
        hotKeys.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        handler = nil
    }

    nonisolated func receive(id: UInt32) {
        Task { @MainActor [weak self] in
            self?.handler?(id)
        }
    }
}

private func quickStashCarbonHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    var actualSize = MemoryLayout<EventHotKeyID>.size
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        &actualSize,
        &hotKeyID
    )
    guard status == noErr else { return status }
    guard quickStashOwnsHotKeyID(hotKeyID) else {
        return OSStatus(eventNotHandledErr)
    }
    let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    registrar.receive(id: hotKeyID.id)
    return noErr
}

@MainActor
final class GlobalHotKeyManager: ObservableObject {
    static let shared = GlobalHotKeyManager()

    private let preferences: ScreenshotPreferences
    private let registrar: HotKeyRegistering
    private var currentID: UInt32?
    private var nextID: UInt32 = 1
    private var action: (@MainActor @Sendable () -> Void)?
    @Published private(set) var registrationError: String?
    @Published private(set) var isRegistered = false

    init(
        preferences: ScreenshotPreferences? = nil,
        registrar: HotKeyRegistering? = nil
    ) {
        self.preferences = preferences ?? .shared
        self.registrar = registrar ?? CarbonHotKeyRegistrar()
    }

    @discardableResult
    func start(action: @escaping @MainActor @Sendable () -> Void) -> Bool {
        self.action = action
        let installStatus = registrar.install { [weak self] id in
            guard self?.currentID == id else { return }
            self?.action?()
        }
        guard installStatus == noErr else {
            setError(status: installStatus)
            return false
        }
        return register(preferences.hotKey, persist: false)
    }

    @discardableResult
    func update(_ descriptor: HotKeyDescriptor) -> Bool {
        guard descriptor.carbonModifiers != 0 else {
            registrationError = "快捷键至少需要一个修饰键"
            return false
        }
        if descriptor == preferences.hotKey, isRegistered {
            registrationError = nil
            return true
        }
        return register(descriptor, persist: true)
    }

    func stop() {
        if let currentID {
            registrar.unregister(id: currentID)
        }
        currentID = nil
        registrar.uninstall()
        action = nil
        registrationError = nil
        isRegistered = false
    }

    private func register(_ descriptor: HotKeyDescriptor, persist: Bool) -> Bool {
        let candidateID = nextID
        nextID &+= 1
        let status = registrar.register(descriptor, id: candidateID)
        guard status == noErr else {
            setError(status: status)
            return false
        }

        if let currentID {
            registrar.unregister(id: currentID)
        }
        currentID = candidateID
        if persist {
            preferences.persist(descriptor)
        }
        registrationError = nil
        isRegistered = true
        return true
    }

    private func setError(status: OSStatus) {
        isRegistered = currentID != nil
        if status == OSStatus(eventHotKeyExistsErr) {
            registrationError = "快捷键已被当前应用中的其他功能占用"
        } else {
            registrationError = "快捷键注册失败（\(status)），原快捷键保持不变"
        }
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    let descriptor: HotKeyDescriptor
    let onChange: (HotKeyDescriptor) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let view = ShortcutRecorderControl()
        view.onChange = onChange
        view.descriptor = descriptor
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderControl, context: Context) {
        nsView.onChange = onChange
        nsView.descriptor = descriptor
    }
}

final class ShortcutRecorderControl: NSView {
    var onChange: ((HotKeyDescriptor) -> Void)?
    var descriptor: HotKeyDescriptor = .defaultScreenshot {
        didSet { needsDisplay = true }
    }
    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 116, height: 28) }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let modifiers = HotKeyDescriptor.carbonModifiers(from: flags)
        guard modifiers != 0, !Self.modifierOnlyKeyCodes.contains(event.keyCode) else {
            NSSound.beep()
            return
        }
        let label = Self.label(for: event)
        let value = HotKeyDescriptor(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers,
            keyLabel: label
        )
        descriptor = value
        isRecording = false
        onChange?(value)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.selectedControlColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = (isRecording ? "请按新快捷键" : descriptor.displayName) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    override func accessibilityLabel() -> String? { "截图快捷键" }
    override func accessibilityValue() -> Any? { descriptor.displayName }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_RightCommand), UInt16(kVK_Shift), UInt16(kVK_RightShift),
        UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Control), UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock), UInt16(kVK_Function)
    ]

    private static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            let value = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return value.isEmpty ? "Key \(event.keyCode)" : value
        }
    }
}
