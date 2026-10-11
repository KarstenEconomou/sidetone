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
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        menu.addItem(applicationItem)
        let applicationMenu = NSMenu(title: "Sidetone")
        applicationMenu.addItem(
            withTitle: "About Sidetone", action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: ""
        ).target = delegate
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        ).target = delegate
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Quit Sidetone", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ).target = app
        applicationItem.submenu = applicationMenu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        app.mainMenu = menu
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let model = MonitorModel()
    private let keyboard = KeyboardModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var hotKey: GlobalShortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = SidetoneGlyph.menuBarImage(active: false)
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Sidetone")
        }
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(
            rootView: MonitorView(model: model, keyboard: keyboard) { [weak self] in
                self?.showSettings(nil)
            })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        model.$settings.map(\.outputUID).removeDuplicates().sink { [weak self] uid in
            MainActor.assumeIsolated { self?.keyboard.setOutputUID(uid) }
        }.store(in: &subscriptions)
        model.$phase.combineLatest(keyboard.$phase).sink { [weak self] phase, keyboardPhase in
            MainActor.assumeIsolated {
                let microphoneOn = phase == .monitoring
                let keyboardOn = keyboardPhase == .listening
                let active = microphoneOn || keyboardOn
                self?.statusItem?.button?.image = SidetoneGlyph.menuBarImage(active: active)
                self?.statusItem?.button?.setAccessibilityValue(
                    "Microphone \(microphoneOn ? "on" : "off"), keyboard \(keyboardOn ? "on" : "off")"
                )
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

    @objc func showSettings(_ sender: Any?) {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SettingsView(model: model, keyboard: keyboard) { [weak self] in
                        self?.showAbout(nil)
                    }))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "Sidetone Settings"
            window.contentMinSize = SettingsLayout.minimumSize
            window.setContentSize(SettingsLayout.defaultSize)
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("Settings")
            settingsWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popover.performClose(nil)
        updateInterfaceVisibility()
    }

    @objc func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: """
                Microphone monitoring and recorded keyboard sounds for macOS.

                Developer: @KarstenEconomou
                Repository: KarstenEconomou/sidetone
                """,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
        for label in ["Developer:", "Repository:"] {
            credits.addAttribute(
                .foregroundColor, value: NSColor.secondaryLabelColor,
                range: (credits.string as NSString).range(of: label))
        }
        credits.addAttribute(
            .link, value: "https://github.com/KarstenEconomou",
            range: (credits.string as NSString).range(of: "@KarstenEconomou"))
        credits.addAttribute(
            .link, value: "https://github.com/KarstenEconomou/sidetone",
            range: (credits.string as NSString).range(of: "KarstenEconomou/sidetone"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
        popover.performClose(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
        } else if !popover.isShown {
            togglePopover()
        }
        return true
    }

    func popoverDidShow(_ notification: Notification) { updateInterfaceVisibility() }
    func popoverDidClose(_ notification: Notification) { updateInterfaceVisibility() }

    func windowWillClose(_ notification: Notification) {
        model.setInterfaceVisible(popover.isShown)
    }

    private func updateInterfaceVisibility() {
        model.setInterfaceVisible(popover.isShown || settingsWindow?.isVisible == true)
    }
    @objc private func willSleep() {
        model.systemWillSleep()
        keyboard.systemWillSleep()
    }
    @objc private func didWake() {
        model.systemDidWake()
        keyboard.systemDidWake()
    }

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
            await keyboard.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
