import Foundation
import SidetoneKit
import Testing

@Suite("Settings")
struct SettingsTests {
    @Test @MainActor func audioFeaturesSaveSeparateEnabledStates() throws {
        let name = "SidetoneTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let microphone = SettingsStore(defaults: defaults)
        let keyboard = KeyboardSettingsStore(defaults: defaults)
        #expect(!microphone.isEnabled)
        #expect(!keyboard.isEnabled)
        microphone.isEnabled = true
        #expect(SettingsStore(defaults: defaults).isEnabled)
        #expect(!KeyboardSettingsStore(defaults: defaults).isEnabled)
        keyboard.isEnabled = true
        microphone.isEnabled = false
        #expect(!SettingsStore(defaults: defaults).isEnabled)
        #expect(KeyboardSettingsStore(defaults: defaults).isEnabled)
    }

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
        saved.eqQ = 5
        saved.compression = true
        saved.noiseSuppression = true
        saved.noiseSuppressionStrength = 72
        saved.globalShortcut = true
        store.save(saved)
        #expect(SettingsStore(defaults: defaults).load() == saved)
    }

    @Test @MainActor func missingSuppressionSettingsPreserveOtherPreferences() throws {
        let name = "SidetoneTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let data = Data(
            """
            {"inputUID":"mic","outputUID":"headphones","gainDB":-27,
             "profile":"Voice","bufferFrames":128,"inputChannel":2,
             "highPassHz":95,"eqFrequencyHz":3400,"eqGainDB":2,"eqQ":0.8,
             "compression":true,"globalShortcut":true}
            """.utf8)
        defaults.set(data, forKey: "monitorSettings")
        let value = SettingsStore(defaults: defaults).load()
        #expect(value.inputUID == "mic")
        #expect(value.outputUID == "headphones")
        #expect(value.gainDB == -27)
        #expect(value.profile == .voice)
        #expect(value.bufferFrames == 128)
        #expect(value.inputChannel == 2)
        #expect(value.highPassHz == 95)
        #expect(value.eqFrequencyHz == 3400)
        #expect(value.eqGainDB == 2)
        #expect(value.eqQ == 0.8)
        #expect(value.compression)
        #expect(value.globalShortcut)
        #expect(!value.noiseSuppression)
        #expect(value.noiseSuppressionStrength == 85)
    }

    @Test func suppressionStrengthHasFiniteBounds() {
        var value = MonitorSettings()
        value.noiseSuppressionStrength = .nan
        value.normalize()
        #expect(value.noiseSuppressionStrength == 85)
        value.noiseSuppressionStrength = 200
        value.normalize()
        #expect(value.noiseSuppressionStrength == 100)
        value.noiseSuppressionStrength = -20
        value.normalize()
        #expect(value.noiseSuppressionStrength == 0)
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
