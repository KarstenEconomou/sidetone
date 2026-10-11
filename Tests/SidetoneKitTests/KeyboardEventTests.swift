import Carbon
import CoreGraphics
import IOKit.hidsystem
import Testing

@testable import SidetoneKit

@Suite("Keyboard event snapshots")
struct KeyboardEventTests {
    private func event(code: Int, flags: CGEventFlags, type: CGEventType = .flagsChanged) throws
        -> CGEvent
    {
        let event = try #require(
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
        event.type = type
        event.flags = flags
        return event
    }

    @Test(arguments: [
        (kVK_Shift, kVK_RightShift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK, NX_SHIFTMASK),
        (kVK_Control, kVK_RightControl, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK, NX_CONTROLMASK),
        (kVK_Option, kVK_RightOption, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK, NX_ALTERNATEMASK),
        (kVK_Command, kVK_RightCommand, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK, NX_COMMANDMASK),
    ])
    func queuedModifiersKeepBothSides(pair: (Int, Int, Int32, Int32, Int32)) throws {
        let (left, right, leftMask, rightMask, combinedMask) = pair
        for releaseLeftFirst in [true, false] {
            let firstRelease = releaseLeftFirst ? left : right
            let lastRelease = releaseLeftFirst ? right : left
            let heldMask = releaseLeftFirst ? rightMask : leftMask
            let snapshots = try [
                event(code: left, flags: CGEventFlags(rawValue: UInt64(combinedMask | leftMask))),
                event(
                    code: right,
                    flags: CGEventFlags(rawValue: UInt64(combinedMask | leftMask | rightMask))),
                event(
                    code: firstRelease,
                    flags: CGEventFlags(rawValue: UInt64(combinedMask | heldMask))),
                event(code: lastRelease, flags: []),
            ]
            let expected = [
                KeyboardStroke(keyCode: UInt16(left), isDown: true, isModifier: true),
                KeyboardStroke(keyCode: UInt16(right), isDown: true, isModifier: true),
                KeyboardStroke(keyCode: UInt16(firstRelease), isDown: false, isModifier: true),
                KeyboardStroke(keyCode: UInt16(lastRelease), isDown: false, isModifier: true),
            ]
            var input = KeyboardInputState()
            for (snapshot, expectedStroke) in zip(snapshots, expected) {
                let stroke = try #require(KeyboardStroke(eventType: snapshot.type, event: snapshot))
                #expect(stroke == expectedStroke)
                let accepted = input.accepts(stroke, settings: KeyboardSettings())
                #expect(accepted)
            }
        }
    }

    @Test func queuedFunctionKeyKeepsPressAndRelease() throws {
        let snapshots = try [
            event(code: kVK_Function, flags: [.maskSecondaryFn, .maskShift]),
            event(code: kVK_Function, flags: .maskShift),
        ]
        let strokes = snapshots.compactMap { KeyboardStroke(eventType: $0.type, event: $0) }
        #expect(
            strokes == [
                KeyboardStroke(keyCode: UInt16(kVK_Function), isDown: true, isModifier: true),
                KeyboardStroke(keyCode: UInt16(kVK_Function), isDown: false, isModifier: true),
            ])
    }

    @Test(arguments: [false, true])
    func capsLockUsesThePhysicalKey(locked: Bool) throws {
        let latch: CGEventFlags = locked ? .maskAlphaShift : []
        let snapshots = try [
            event(
                code: kVK_CapsLock,
                flags: latch.union(CGEventFlags(rawValue: UInt64(NX_ALPHASHIFT_STATELESS_MASK)))),
            event(code: kVK_CapsLock, flags: latch),
        ]
        let strokes = snapshots.compactMap { KeyboardStroke(eventType: $0.type, event: $0) }
        #expect(
            strokes == [
                KeyboardStroke(keyCode: UInt16(kVK_CapsLock), isDown: true, isModifier: true),
                KeyboardStroke(keyCode: UInt16(kVK_CapsLock), isDown: false, isModifier: true),
            ])
    }

    @Test func ordinaryKeysKeepTheirEventTypeAndRepeatFlag() throws {
        let down = try event(code: kVK_ANSI_A, flags: .maskShift, type: .keyDown)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let up = try event(code: kVK_ANSI_A, flags: .maskShift, type: .keyUp)
        #expect(
            KeyboardStroke(eventType: down.type, event: down)
                == KeyboardStroke(keyCode: UInt16(kVK_ANSI_A), isDown: true, isRepeat: true))
        #expect(
            KeyboardStroke(eventType: up.type, event: up)
                == KeyboardStroke(keyCode: UInt16(kVK_ANSI_A), isDown: false))
        #expect(KeyboardStroke(eventType: .flagsChanged, event: up) == nil)
        #expect(KeyboardStroke(eventType: .mouseMoved, event: up) == nil)
        up.setIntegerValueField(.keyboardEventKeycode, value: 128)
        #expect(KeyboardStroke(eventType: up.type, event: up) == nil)
    }
}
