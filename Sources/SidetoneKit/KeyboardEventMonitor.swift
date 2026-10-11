import Carbon
import CoreGraphics
import Foundation
import IOKit.hidsystem

extension KeyboardStroke {
    init?(eventType: CGEventType, event: CGEvent) {
        guard eventType == .keyDown || eventType == .keyUp || eventType == .flagsChanged else {
            return nil
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard (0...127).contains(code) else { return nil }
        let down: Bool
        if eventType == .flagsChanged {
            let mask: Int32
            switch Int(code) {
            case kVK_Command: mask = NX_DEVICELCMDKEYMASK
            case kVK_RightCommand: mask = NX_DEVICERCMDKEYMASK
            case kVK_Shift: mask = NX_DEVICELSHIFTKEYMASK
            case kVK_RightShift: mask = NX_DEVICERSHIFTKEYMASK
            case kVK_Option: mask = NX_DEVICELALTKEYMASK
            case kVK_RightOption: mask = NX_DEVICERALTKEYMASK
            case kVK_Control: mask = NX_DEVICELCTLKEYMASK
            case kVK_RightControl: mask = NX_DEVICERCTLKEYMASK
            // The stateless flag reports whether Caps Lock is held.
            case kVK_CapsLock: mask = NX_ALPHASHIFT_STATELESS_MASK
            case kVK_Function: mask = NX_SECONDARYFNMASK
            default: return nil
            }
            down = event.flags.rawValue & UInt64(mask) != 0
        } else {
            down = eventType == .keyDown
        }
        self.init(
            keyCode: UInt16(code), isDown: down,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isModifier: eventType == .flagsChanged)
    }
}

@MainActor
protocol KeyboardEventMonitoring: AnyObject {
    var hasAccess: Bool { get }
    var secureInput: Bool { get }
    func requestAccess() -> Bool
    func start(
        receive: @escaping @Sendable (KeyboardStroke) -> Void,
        reset: @escaping @Sendable () -> Void
    ) -> Bool
    func stop()
}

private final class EventTapHandle: @unchecked Sendable {
    // The event thread owns callbacks and teardown. The lock protects run loop startup and stop.
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var stopped = false
    private var finished = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let receive: @Sendable (KeyboardStroke) -> Void
    private let reset: @Sendable () -> Void
    var isFinished: Bool { lock.withLock { finished } }

    init(
        receive: @escaping @Sendable (KeyboardStroke) -> Void,
        reset: @escaping @Sendable () -> Void
    ) {
        self.receive = receive
        self.reset = reset
    }

    func start() -> Bool {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, context in
                    if let context {
                        Unmanaged<EventTapHandle>.fromOpaque(context).takeUnretainedValue()
                            .handle(type: type, event: event)
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        let thread = Thread { [self] in run() }
        thread.name = "Sidetone keyboard events"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        lock.withLock {
            stopped = true
            if let loop {
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
                CFRunLoopWakeUp(loop)
            }
        }
    }

    private func run() {
        guard let tap, let source else { return }
        let current = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(current, source, .commonModes)
        let shouldRun = lock.withLock {
            loop = current
            return !stopped
        }
        if shouldRun {
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        CFRunLoopRemoveSource(current, source, .commonModes)
        CFMachPortInvalidate(tap)
        lock.withLock {
            loop = nil
            finished = true
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        lock.withLock {
            guard !stopped else { return }
            handleEvent(type: type, event: event)
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if CGPreflightListenEventAccess(), let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if IsSecureEventInputEnabled() {
            reset()
            return
        }
        guard let stroke = KeyboardStroke(eventType: type, event: event) else { return }
        receive(stroke)
    }
}

@MainActor
final class KeyboardEventMonitor: KeyboardEventMonitoring {
    private var handle: EventTapHandle?

    var hasAccess: Bool { CGPreflightListenEventAccess() }
    var secureInput: Bool { IsSecureEventInputEnabled() }
    func requestAccess() -> Bool { CGRequestListenEventAccess() }

    deinit { handle?.stop() }

    func start(
        receive: @escaping @Sendable (KeyboardStroke) -> Void,
        reset: @escaping @Sendable () -> Void
    ) -> Bool {
        if let handle, !handle.isFinished { return true }
        guard hasAccess else { return false }
        let handle = EventTapHandle(receive: receive, reset: reset)
        guard handle.start() else { return false }
        self.handle = handle
        return true
    }

    func stop() {
        handle?.stop()
        handle = nil
    }
}
