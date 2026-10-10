import AppKit
import Combine
import SidetoneKit
import SwiftUI

@main
@MainActor
enum SidetoneApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MonitorModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var hotKey: GlobalShortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "waveform", accessibilityDescription: "Sidetone")
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "Sidetone — Off"
        }
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: MonitorView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        model.$phase.sink { [weak self] phase in
            MainActor.assumeIsolated {
                let active = phase == .monitoring
                self?.statusItem?.button?.image = NSImage(
                    systemSymbolName: active ? "waveform.circle.fill" : "waveform",
                    accessibilityDescription: active ? "Sidetone is on" : "Sidetone is off")
                self?.statusItem?.button?.toolTip =
                    active ? "Sidetone — Monitoring" : "Sidetone — Off"
            }
        }.store(in: &subscriptions)
        model.$settings.map(\.globalShortcut).removeDuplicates().sink { [weak self] enabled in
            MainActor.assumeIsolated { self?.configureShortcut(enabled) }
        }.store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        if !UserDefaults.standard.bool(forKey: "hasShownMenu") {
            togglePopover()
            UserDefaults.standard.set(true, forKey: "hasShownMenu")
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem?.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        if !popover.isShown { togglePopover() }
        return true
    }

    func popoverDidShow(_ notification: Notification) { model.setPopoverVisible(true) }
    func popoverDidClose(_ notification: Notification) { model.setPopoverVisible(false) }
    @objc private func willSleep() { model.systemWillSleep() }
    @objc private func didWake() { model.systemDidWake() }

    private func configureShortcut(_ enabled: Bool) {
        hotKey = nil
        guard enabled else { return }
        do {
            hotKey = try GlobalShortcut { [weak self] in
                guard let self else { return }
                self.model.setEnabled(!self.model.enabled)
            }
        } catch {
            model.reportError("The shortcut is in use. Choose another shortcut in the other app.")
            Task { @MainActor [weak self] in
                self?.model.updateSettings { $0.globalShortcut = false }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
