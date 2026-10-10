import Foundation
import SidetoneKit
import Testing

@Suite("Settings")
struct SettingsTests {
    @Test @MainActor func preferencesRoundTrip() throws {
        let name = "SidetoneTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        var saved = MonitorSettings()
        saved.inputUID = "microphone-uid"
        saved.outputUID = "headphones-uid"
        saved.gainDB = -24
        saved.selectProfile(.voice)
        saved.bufferFrames = 128
        saved.inputChannel = 2
        saved.highPassHz = 95
        saved.eqFrequencyHz = 3400
        saved.eqGainDB = 2
        saved.eqQ = 1.2
        saved.compression = true
        saved.globalShortcut = true
        store.save(saved)
        #expect(SettingsStore(defaults: defaults).load() == saved)
    }

    @Test @MainActor func corruptSettingsUseSafeDefaults() throws {
        let name = "SidetoneTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: "monitorSettings")
        let value = SettingsStore(defaults: defaults).load()
        #expect(value.gainDB == -18)
        #expect(value.inputUID == nil)
        #expect(value.outputUID == nil)
    }

    @Test func invalidParametersCannotIncreaseGainOrReachDSP() {
        var value = MonitorSettings()
        value.gainDB = 200
        value.highPassHz = .nan
        value.eqFrequencyHz = -.infinity
        value.eqQ = 0
        value.bufferFrames = -1
        value.inputChannel = -1
        value.normalize()
        #expect(value.gainDB == 0)
        #expect(value.highPassHz == 75)
        #expect(value.eqFrequencyHz == 2200)
        #expect(value.eqQ > 0)
        #expect(value.bufferFrames > 0)
        #expect(value.inputChannel == 0)
        value.gainDB = .nan
        value.normalize()
        #expect(value.gainDB == -18)
    }

    @Test func profileChangePreservesRoutingAndGain() {
        var value = MonitorSettings()
        value.inputUID = "mic"
        value.outputUID = "iem"
        value.gainDB = -30
        value.selectProfile(.voice)
        #expect(value.highPassHz == 110)
        #expect(value.eqGainDB == 3)
        #expect(value.gainDB == -30)
        #expect(value.outputUID == "iem")
        value.selectProfile(.direct)
        #expect(value.profile == .direct)
        #expect(value.gainDB == -30)
    }
}
