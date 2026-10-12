import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject,
    @preconcurrency SPUStandardUserDriverDelegate
{
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var error: String?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }

    func start() {
        do {
            try controller.updater.start()
        } catch {
            self.error = "Could not start update checks. \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        controller.updater.automaticallyChecksForUpdates = value
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
