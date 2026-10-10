import Carbon
import Foundation

final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    @MainActor init(action: @escaping @MainActor () -> Void) throws {
        self.action = action
        var event = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, pointer in
                guard let pointer else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue().action()
                }
                return noErr
            }, 1, &event, context, &handler)
        guard installed == noErr else { throw ShortcutError.unavailable }
        let identifier = EventHotKeyID(signature: 0x5364_546E, id: 1)
        let registered = RegisterEventHotKey(
            UInt32(kVK_ANSI_M), UInt32(cmdKey | shiftKey), identifier,
            GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw ShortcutError.unavailable
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
    private enum ShortcutError: Error { case unavailable }
}
